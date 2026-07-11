# dnvr

Declarative dev environments for Nix flakes. Each **shell** is a Nix module
declaring **processes** (long-running commands orchestrated by a runner —
each one a module that can import a reusable **preset** like
postgres/clickhouse), **scripts** (commands on the devshell PATH), and
**env** vars. dnvr turns every `dnvr.shells.<name>` into:

- `devShells.<name>` — enter with `nix develop .#<name>`

Shell state is confined to `.dnvr/*` under the repo root (nothing in
`$HOME`), namespaced per process — shells in the same repo share it.
Processes discover each other's runtime values (ports, socket dirs)
through the bundled `dnvr-state` CLI — or declaratively via `dnvr://`
env refs, which double as the process dependency graph — and run under
a pluggable runner (`mprocs` by default, `process-compose` built in).

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
        dnvr.shells.backend = {config, ...}: {
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

          # Static connection env (see Static values below): psql and the
          # migrate script reach pg in the devshell, no waiting involved.
          env = {
            NODE_ENV = "development";
            PGHOST = config.processes.pg.socketPath;
            PGDATABASE = config.processes.pg.database;
            PGUSER = config.processes.pg.superuser;
          };
        };
      };
    };
}
```

Then:

```console
$ nix develop .#backend   # shell with scripts, packages, env, banner
$ dnvr up                 # inside the shell: mprocs with pg + api panes
```

## The `dnvr` CLI

Every devshell carries a `dnvr` command scoped to its shell:

```console
$ dnvr --help     # everything in this shell: commands, descriptions
$ dnvr up         # launch the process group
$ dnvr ps         # process status: pid + liveness per process
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
at completion time, so they follow whichever shell is active and complete
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
- `env` — exported in the devshell and to every runner process. `$DNVR_ROOT`
  in values expands at export time (see Static values below). Refs of
  `inShell` schemes (op://) are allowed and resolve at shell entry only;
  `dnvr://` refs belong on the process that consumes them.
- `dependencies` — read-only: `process -> [dependencies]`, derived from
  `dnvr://` refs.
- `prerun` — shell code run inside the up-script before the runner execs
  (dynamic port picking etc.; anything `export`ed flows to all processes).
- `runner` — defaults to `runners.mprocs`.
- `shellHook` — escape hatch.

## Runtime contract

Entering a devshell sets `DNVR_ROOT` (git toplevel; cwd outside a git
repo) and `DNVR_STATE` (`$DNVR_ROOT/.dnvr`). Processes publish and consume
discovery values through `dnvr-state`:

```console
$ dnvr-state set port 5432          # publish to own scope
$ dnvr-state get pg.socketDir       # read a live value (fails if pg is down)
$ dnvr-state wait pg.socketDir      # block until pg is up and it's published
$ dnvr-state pick-port              # random free TCP port
$ dnvr-state dump                   # list everything published
```

**A key is stale if it is readable while its producer is not alive** —
that one rule is the whole model. Every process holds an exclusive
`flock` on its `pid` file for life (the kernel drops the lock on
death, SIGKILL included) and wipes its own keys as it claims it, so
lock held + key present always means the current incarnation's value.
`get` and `wait` both require exactly that; `wait` simply blocks until
it becomes true, riding out producer restarts, bounded by its timeout.
`dnvr ps` reads the same lock — a recycled pid can never read as
running: `running` (locked), `exited` (pid on record, lock released),
`stopped` (never launched). Nothing else owns or deletes state — the
up script just opens the viewer, and another shell's running group is
never touched.

The built-in presets publish their full connection surface. postgres:
`port`, `host`, `socketDir`, `dataDir`, `user`, `bootstrapDatabase` at
startup, then `database`, `url`, `socketUrl` once the server accepts
connections and the databases exist. clickhouse: `httpPort`, `tcpPort`,
`host`, `httpUrl`, `user` (and `postgresqlPort` when set) at startup, then
`database` once the server answers queries. The late keys are the ones to
`dnvr://`-ref when you need readiness, not just discovery.

### Static values and `$DNVR_ROOT`

Not everything needs runtime discovery. Preset values fall into three
tiers:

1. **Eval-static** — `port`, `database`, `superuser`: read them straight
   off the config (`config.processes.db.port`).
2. **Location-dependent** — paths under the repo root. Presets expose
   these as read-only computed options (`socketPath`, `dataPath`, `url`,
   `socketUrl` on postgres; `httpUrl`, `dataPath` on clickhouse) whose
   values are `$DNVR_ROOT`-relative shell strings.
3. **Runtime-published** — dynamically picked ports, readiness. This is
   `dnvr://` territory (next section) and the only tier that waits.

Tiers 1–2 are just strings: always set, never waited on. Wire them into
env for ad-hoc use — `psql` works in the devshell whether or not the
group is running (it simply fails to connect if postgres is down):

```nix
dnvr.shells.backend = {config, ...}: {
  processes.db = { imports = [presets.postgres]; database = "app"; };
  env = {
    PGHOST = config.processes.db.socketPath;
    PGDATABASE = config.processes.db.database;
    PGUSER = config.processes.db.superuser;
  };
};
```

The expansion rule, in one sentence: **the literal substring
`$DNVR_ROOT` in an env value is expanded by the shell at export time
(shellHook, runner, wrapper); everything else — including any other
`$` — is exported verbatim.** A longer identifier like `$DNVR_ROOT_DIR`
names a different variable and stays verbatim too. Values are expanded before any program or
subshell reads them, so they are correct in every shell, nushell
included. One rule of thumb follows: in script bodies, read the env var
(`$PGHOST` / `$env.PGHOST`), not the raw option — raw `$DNVR_ROOT`
strings only self-expand in POSIX-shell contexts.

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
  that declares them; they never enter the shared runner env or the
  devshell. Interactively, read live values with `dnvr-state get` (e.g.
  `psql "$(dnvr-state get pg.socketUrl)"`).
- **Refs are the dependency graph.** `dnvr --help` shows `api→pg`, and
  `dnvr.shells.<name>.dependencies` exposes `process -> [dependencies]` for
  tooling. Unknown targets, self-references, and cycles fail at eval time.
- **Whole-value refs only.** To hand a consumer a composed value (a URL,
  a DSN), publish it already composed from the producer.
- **Refs are for live values.** A value is readable only while its
  producer runs, so run-to-completion ordering (migrations before api)
  is not a ref concern: use the runner's native ordering
  (`runner_settings."process-compose".depends_on` with
  `process_completed_successfully`), and keep truly-once initialization
  with the data it initializes (the postgres preset's `initialScript`
  runs once per data dir).
- A string `command` that carries refs is wrapped in a script (with
  `set -euo pipefail`); string commands without refs keep their plain
  sh semantics — they only gain the `DNVR_RUNTIME_DIR`/`dnvr-state`
  preamble every process gets.

### Pluggable ref schemes

`dnvr://` is just the built-in entry in `refHandlers`, a shell-level option
mapping URL schemes to resolvers. Register your own — e.g. 1Password:

```nix
dnvr.shells.backend = {
  refHandlers.op = {
    command = url: "op read ${lib.escapeShellArg url}";
    runtimeInputs = [pkgs._1password-cli];
    cache.ttl = 3600; # don't shell out to op on every direnv load
  };

  processes.api.env = {
    PGHOST = "dnvr://pg/socketDir";
    STRIPE_KEY = "op://dev-vault/stripe/key";
  };

  env.OPENAI_API_KEY = "op://dev-vault/openai/key"; # shell-only ref
};
```

A handler's `command` gets the whole ref value and returns a shell
command whose stdout becomes the var. Resolution happens twice:

- **At process start** (authoritative): the wrapper resolves and exports
  before the command runs; a failing resolver aborts the process.
- **At devshell entry** (best-effort, `inShell = true` by default): the
  same command runs in the shellHook so ad-hoc scripts see the values;
  a failure warns on stderr and skips the export — it never blocks the
  shell. The built-in dnvr handler sets `inShell = false`: its values
  are runtime-published and would be absent or stale at entry. Refs in
  the shell-level `env` are allowed for `inShell` schemes (entry-only,
  never sent to the runner); `dnvr://` there is an eval error.

`cache.ttl = <seconds>` caches resolved values as plaintext files under
`$DNVR_STATE/ref-cache` (umask 077) — deliberately dev-grade; keep
`.dnvr` gitignored. The cache serves both entry and process start;
`dnvr state cache-clear` flushes it after rotating a secret.

Only whole-string values whose scheme has a handler are refs:
`https://…` and friends pass through untouched. Dependency edges come
only from `dnvr://` refs. Note that registering a handler claims its
whole scheme — there is no way to pass `<scheme>://…` through as a
plain value once a handler for it exists.

## Top-level options

- `dnvr.presets.<name>` — custom process presets (deferred modules) merged
  over the built-ins; import them in any shell via `processes.<proc>.imports`.
- `dnvr.extraRunners` — extend the runner registry. A custom runner reads its
  per-process config from `runner_settings.<its-name>` by convention.
- `dnvr.picker.enable` — a devshell that pops a `gum choose` TUI over the
  declared shells, writes `.envrc` for the chosen one, and hands off to
  direnv. Exposed as `dnvr.picker.shellName` (default `"default"`, so plain
  `nix develop` lands on it; set e.g. `"picker"` for `nix develop .#picker`).
- `dnvr.lib` — read-only handle to the framework
  (`{mkShells, mkScript, runners, presets, dnvrState}`).

## Without flake-parts

```nix
dnvr.lib.mkDnvr {inherit pkgs;}
```

returns the same handle; `mkShells [module1 module2]` evaluates modules and
returns `{devShells, ups, config}`.
