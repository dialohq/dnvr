# dnvr

Declarative dev environments for Nix flakes. Each **shell** is a Nix module
declaring **processes** (long-running commands orchestrated by a runner —
each one a module that can import a reusable **preset** like
postgres/clickhouse), **scripts** (commands on the devshell PATH), and
**env** vars. dnvr turns every `dnvr.shells.<name>` into:

- `devShells.<name>` — enter with `nix develop .#<name>`
- `apps.<name>-up` — launch the process group with `nix run .#<name>-up`

Shells are isolated to `.dnvr/*` under the repo root, discover each
other's runtime values (ports, socket dirs) through the bundled `dnvr-state`
CLI — or declaratively via `dnvr://` env refs, which double as the process
dependency graph — and run under a pluggable runner (`mprocs` by default,
`process-compose` built in).

## Usage (flake-parts)

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    dnvr.url = "github:dialohq/dnvr";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "aarch64-darwin"];
      imports = [inputs.dnvr.flakeModule];

      perSystem = {pkgs, presets, ...}: {
        dnvr.shells.backend = {
          description = "postgres + api server";

          processes.pg = {
            imports = [presets.postgres];
            package = pkgs.postgresql_17;
            database = "app";
          };

          processes.api = {
            env = {
              PGHOST = "dnvr://pg/socketDir"; # blocks until pg publishes it
              PGDATABASE = "dnvr://pg/database"; # published once the DB is usable
            };
            command = "my-api-server";
          };

          scripts.migrate = {
            description = "Apply migrations";
            runtimeInputs = [pkgs.postgresql_17];
            text = ''psql -f "$DNVR_ROOT/migrations.sql"'';
          };

          env.NODE_ENV = "development";
        };
      };
    };
}
```

Then:

```console
$ nix develop .#backend   # shell with scripts, packages, env, banner
$ nix run .#backend-up    # mprocs with pg + api panes
```

## The `dnvr` CLI

Every devshell carries a `dnvr` command scoped to its shell:

```console
$ dnvr --help     # everything in this shell: commands, descriptions
$ dnvr up         # launch the process group
$ dnvr migrate    # run a script (scripts are also on PATH directly)
$ dnvr state dump # dnvr-state passthrough
```

### Completion

Completion ships with the devshell — no per-user setup for most paths.
Completion files sit in standard `share/` locations and the shellHook exports
`XDG_DATA_DIRS`/`FPATH` pointing at them:

- `nix develop .#<name>` (bash) — registered directly by the shellHook.
- bash + bash-completion + direnv — bash-completion resolves `XDG_DATA_DIRS`
  lazily at first `<tab>`, so it picks dnvr up as soon as direnv loads the env.
- any zsh/fish/nushell (≥0.96) **started inside** the devshell — they read
  `FPATH`/`XDG_DATA_DIRS` at startup (nushell vendor-autoloads
  `share/nushell/vendor/autoload/dnvr-completions.nu`).

The one case that isn't automatic out of the box: a zsh/fish/nushell that was
**already running** when direnv loaded the env — those shells computed their
completion paths at startup. The shellHook materializes the nushell module at a
stable path (`.dnvr/dnvr-completions.nu`), so nushell + direnv users make
it automatic with a one-time hook next to their direnv integration (string
hooks run in REPL scope, so they can load overlays):

```nu
$env.config.hooks.pre_prompt = ($env.config.hooks.pre_prompt? | default [] | append {
  condition: {|| (".dnvr/dnvr-completions.nu" | path exists) and ("dnvr-completions" not-in (overlay list | get name)) }
  code: "overlay use .dnvr/dnvr-completions.nu"
})
```

Ad-hoc alternative, venv-style: `overlay use .dnvr/dnvr-completions.nu`.

For zsh/fish, add one line to your shell config, once:

```console
$ dnvr completions zsh   # eval in ~/.zshrc (after compinit)
$ dnvr completions fish  # save to ~/.config/fish/completions/dnvr.fish
```

All completers call `dnvr --list` (tab-separated `command<TAB>description`)
at completion time, so they follow whichever env is active and complete
nothing outside one. `dnvr <TAB>` lists `up` first, then every script with
its description (`state` and `completions` work but aren't completed).

## Module args

The flake module injects these into `perSystem` (and into every `dnvr.shells.<name>`
submodule):

| arg | what it is |
|---|---|
| `presets` | Built-in process presets (`postgres`, `clickhouse`) plus `dnvr.presets`. |
| `runners` | Up-script builders (`mprocs`, `process-compose`) plus `dnvr.extraRunners`. |
| `mkScript` | `{name, text, runtimeInputs?, shell?} -> drv` script builder. |
| `dnvrState` | The `dnvr-state` CLI package, for `runtimeInputs`. |

## `dnvr.shells.<name>` options

- `description` — one-liner shown in the entry banner.
- `packages` — extra packages on the devshell PATH.
- `processes.<proc>` — a module per process the runner orchestrates. Either
  set `command` (derivation or string) directly, or import a preset and set
  its options (`imports = [presets.postgres]`). Instantiating the same preset
  under two names gives two independent instances — the process name
  namespaces data dirs, env vars, and `dnvr-state` scope. Besides `command`,
  a process can contribute `packages`, `env`, and `scripts` to the devshell,
  and carry runner-specific config under
  `runner_settings.<runner>.<key>` (e.g.
  `runner_settings."process-compose".depends_on`); each runner reads only its
  own key. Each process gets `DNVR_RUNTIME_DIR` scoped to its name so
  `dnvr-state set` needs no self-identification. A process `env` value of
  the form `dnvr://<proc>/<key>` declares a dependency — see
  [`dnvr://` refs](#dnvr-refs).
- `scripts.<name>` — `{text, runtimeInputs?, shell?, description?}` commands
  on the devshell PATH.
- `env` — exported in the devshell and to every runner process (`dnvr://`
  values here are devshell-only conveniences, resolved best-effort at entry).
- `dependencies` — read-only: `process -> [dependencies]`, derived from
  `dnvr://` refs.
- `prerun` — shell code run inside the up-script before the runner execs
  (dynamic port picking etc.; anything `export`ed flows to all processes).
- `runner` — defaults to `runners.mprocs`.
- `shellHook`, `flags` — escape hatches.

## Runtime contract

Entering a devshell sets `DNVR_ROOT` (git toplevel) and
`DNVR_STATE` (`$DNVR_ROOT/.dnvr`). Processes publish and consume
discovery values through `dnvr-state`:

```console
$ dnvr-state set port 5432          # publish to own scope
$ dnvr-state get pg.socketDir       # read another process's value
$ dnvr-state wait pg.socketDir      # block until published (--timeout N)
$ dnvr-state pick-port              # random free TCP port
$ dnvr-state dump                   # list everything published
```

The runner wipes `$DNVR_STATE/runtime` on every launch so consumers never
read stale values.

The built-in presets publish their full connection surface. postgres:
`port`, `host`, `socketDir`, `dataDir`, `user`, `bootstrapDatabase` at
startup, then `database`, `url`, `socketUrl` once the server accepts
connections and the databases exist. clickhouse: `httpPort`, `tcpPort`,
`host`, `httpUrl`, `user` (and `postgresqlPort` when set) at startup, then
`database` once the server answers queries. The late keys are the ones to
`dnvr://`-ref when you need readiness, not just discovery.

### `dnvr://` refs

A process `env` value that is exactly `dnvr://<proc>/<key>` is a reference
to another process's published state. Before the consumer's command runs,
its wrapper does `dnvr-state wait <proc>.<key>` (120 s timeout) and exports
the value under the var's name — so startup ordering falls out of data
readiness, with no `depends_on` wiring:

```nix
processes.api.env.PGHOST = "dnvr://pg/socketDir";
```

Semantics:

- **Scoped to the consumer.** Ref vars are exported only to the process
  that declares them; they never enter the shared runner env. In the
  devshell they resolve best-effort at entry (exported only if already
  published — re-enter after `dnvr up` to pick them up).
- **Refs are the dependency graph.** `dnvr --help` shows `api→pg`, and
  `dnvr.shells.<name>.dependencies` exposes `process -> [dependencies]` for
  tooling. Unknown targets, self-references, and cycles fail at eval time.
- **Whole-value refs only.** To hand a consumer a composed value (a URL,
  a DSN), publish it already composed from the producer.
- **Pure ordering deps** (migrations before api) need no special syntax:
  publish a sentinel — `dnvr-state set done 1` in the producer,
  `env.MIGRATIONS_DONE = "dnvr://migrations/done"` in the consumer. The
  consumer then waits for *completion*, not just startup.
- A string `command` that carries refs is wrapped in a script (with
  `set -euo pipefail`); string commands without refs pass to the runner
  untouched, as before.

### Pluggable ref schemes

`dnvr://` is just the built-in entry in `refHandlers`, a shell-level option
mapping URL schemes to resolvers. Register your own — e.g. 1Password:

```nix
dnvr.shells.backend = {
  refHandlers.op = {
    command = url: "op read ${lib.escapeShellArg url}";
    runtimeInputs = [pkgs._1password-cli];
    resolveInShell = false; # don't block shell entry on op auth
  };

  processes.api.env = {
    PGHOST = "dnvr://pg/socketDir";
    STRIPE_KEY = "op://dev-vault/stripe/key";
  };
};
```

A handler's `command` gets the whole ref value and returns a shell
command whose stdout becomes the var. It runs in the process wrapper
before the command starts (a failing resolver aborts the process). At
devshell entry refs resolve best-effort — failures skip the export —
unless `resolveInShell = false`; `shellCommand` optionally overrides the
entry-time command (the dnvr handler `wait`s in processes but only `get`s
in the shell). Only whole-string values whose scheme has a handler are
refs: `https://…` and friends pass through untouched. Dependency edges
come only from `dnvr://` refs.

## Top-level options

- `dnvr.presets.<name>` — custom process presets (deferred modules) merged
  over the built-ins; import them in any env via `processes.<proc>.imports`.
- `dnvr.extraRunners` — extend the runner registry. A custom runner reads its
  per-process config from `runner_settings.<its-name>` by convention.
- `dnvr.exposeApps` — wire `apps.<name>-up` (default `true`).
- `dnvr.picker.enable` — a devshell (default name `"default"`, so plain
  `nix develop`) that pops a `gum choose` TUI, writes `.envrc` for the chosen
  env, and hands off to direnv.
- `dnvr.lib` — read-only handle to the framework
  (`{mkShells, mkScript, runners, presets, dnvrState}`).

## Without flake-parts

```nix
dnvr.lib.mkDnvr {inherit pkgs;}
```

returns the same handle; `mkShells [module1 module2]` evaluates modules and
returns `{devShells, ups, config}`.
