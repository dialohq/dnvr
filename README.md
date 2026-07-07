# denver

Declarative dev environments for Nix flakes. Each environment is a Nix module
declaring **services** (reusable presets like postgres/clickhouse),
**processes** (long-running commands orchestrated by a runner), **scripts**
(commands on the devshell PATH), and **env** vars. denver turns every
`devenv.<name>` into:

- `devShells.<name>` — enter with `nix develop .#<name>`
- `apps.<name>-up` — launch the process group with `nix run .#<name>-up`

Environments are isolated to `.devenv/*` under the repo root, discover each
other's runtime values (ports, socket dirs) through the bundled `denver-state`
CLI, and run under a pluggable runner (`mprocs` by default, `process-compose`
built in).

## Usage (flake-parts)

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    denver.url = "github:dialohq/denver";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "aarch64-darwin"];
      imports = [inputs.denver.flakeModule];

      perSystem = {pkgs, presets, denverState, ...}: {
        devenv.backend = {
          description = "postgres + api server";

          services.pg = {
            imports = [presets.postgres];
            package = pkgs.postgresql_17;
          };

          processes.api.command = pkgs.writeShellApplication {
            name = "api";
            runtimeInputs = [denverState];
            text = ''
              PGHOST=$(denver-state wait pg.socketDir)
              export PGHOST
              exec my-api-server
            '';
          };

          scripts.migrate = {
            description = "Apply migrations";
            runtimeInputs = [pkgs.postgresql_17];
            text = ''psql -f "$DEVENV_ROOT/migrations.sql"'';
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

## Module args

The flake module injects these into `perSystem` (and into every `devenv.<name>`
submodule):

| arg | what it is |
|---|---|
| `presets` | Built-in service presets (`postgres`, `clickhouse`) plus `denver.extraPresets`. |
| `runners` | Up-script builders (`mprocs`, `process-compose`) plus `denver.extraRunners`. |
| `mkScript` | `{name, text, runtimeInputs?, shell?} -> drv` script builder. |
| `denverState` | The `denver-state` CLI package, for `runtimeInputs`. |

## `devenv.<name>` options

- `description` — one-liner shown in the entry banner.
- `packages` — extra packages on the devshell PATH.
- `services.<svc>` — module instances; import a preset and set its options.
  Services contribute packages, processes, env, and scripts.
- `processes.<proc>.command` — derivation (or attrset with `command`) the
  runner orchestrates. Each process gets `DEVENV_RUNTIME_DIR` scoped to its
  name so `denver-state set` needs no self-identification.
- `scripts.<name>` — `{text, runtimeInputs?, shell?, description?}` commands
  on the devshell PATH.
- `env` — exported in the devshell and to every runner process.
- `prerun` — shell code run inside the up-script before the runner execs
  (dynamic port picking etc.; anything `export`ed flows to all processes).
- `runner` — defaults to `runners.mprocs`.
- `shellHook`, `flags` — escape hatches.

## Runtime contract

Entering a devshell sets `DEVENV_ROOT` (git toplevel) and
`DEVENV_STATE` (`$DEVENV_ROOT/.devenv`). Services publish and consume
discovery values through `denver-state`:

```console
$ denver-state set port 5432          # publish to own scope
$ denver-state get pg.socketDir       # read another service's value
$ denver-state wait pg.socketDir      # block until published (--timeout N)
$ denver-state pick-port              # random free TCP port
$ denver-state dump                   # list everything published
```

The runner wipes `$DEVENV_STATE/runtime` on every launch so consumers never
read stale values.

## Top-level options

- `denver.extraPresets` / `denver.extraRunners` — extend the registries.
- `denver.exposeApps` — wire `apps.<name>-up` (default `true`).
- `denver.picker.enable` — a devshell (default name `"default"`, so plain
  `nix develop`) that pops a `gum choose` TUI, writes `.envrc` for the chosen
  devenv, and hands off to direnv.
- `denver.lib` — read-only handle to the framework
  (`{mkDevenvs, mkScript, runners, presets, denverState}`).

## Without flake-parts

```nix
denver.lib.mkDenver {inherit pkgs;}
```

returns the same handle; `mkDevenvs [module1 module2]` evaluates modules and
returns `{devShells, ups, config}`.
