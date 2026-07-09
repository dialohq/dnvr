# dnvr

Declarative dev environments for Nix flakes. Each environment is a Nix module
declaring **processes** (long-running commands orchestrated by a runner —
each one a module that can import a reusable **preset** like
postgres/clickhouse), **scripts** (commands on the devshell PATH), and
**env** vars. dnvr turns every `dnvr.envs.<name>` into:

- `devShells.<name>` — enter with `nix develop .#<name>`
- `apps.<name>-up` — launch the process group with `nix run .#<name>-up`

Environments are isolated to `.dnvr/*` under the repo root, discover each
other's runtime values (ports, socket dirs) through the bundled `dnvr-state`
CLI, and run under a pluggable runner (`mprocs` by default, `process-compose`
built in).

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

      perSystem = {pkgs, presets, dnvrState, ...}: {
        dnvr.envs.backend = {
          description = "postgres + api server";

          processes.pg = {
            imports = [presets.postgres];
            package = pkgs.postgresql_17;
          };

          processes.api.command = pkgs.writeShellApplication {
            name = "api";
            runtimeInputs = [dnvrState];
            text = ''
              PGHOST=$(dnvr-state wait pg.socketDir)
              export PGHOST
              exec my-api-server
            '';
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

Every devshell carries a `dnvr` command scoped to its environment:

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

The flake module injects these into `perSystem` (and into every `dnvr.envs.<name>`
submodule):

| arg | what it is |
|---|---|
| `presets` | Built-in process presets (`postgres`, `clickhouse`) plus `dnvr.presets`. |
| `runners` | Up-script builders (`mprocs`, `process-compose`) plus `dnvr.extraRunners`. |
| `mkScript` | `{name, text, runtimeInputs?, shell?} -> drv` script builder. |
| `dnvrState` | The `dnvr-state` CLI package, for `runtimeInputs`. |

## `dnvr.envs.<name>` options

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
  `dnvr-state set` needs no self-identification.
- `scripts.<name>` — `{text, runtimeInputs?, shell?, description?}` commands
  on the devshell PATH.
- `env` — exported in the devshell and to every runner process.
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
  (`{mkEnvs, mkScript, runners, presets, dnvrState}`).

## Without flake-parts

```nix
dnvr.lib.mkDnvr {inherit pkgs;}
```

returns the same handle; `mkEnvs [module1 module2]` evaluates modules and
returns `{devShells, ups, config}`.
