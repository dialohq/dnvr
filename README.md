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
env refs, which double as the process dependency graph — and run in a
persistent, sidebar-first tmux dashboard.

## Usage (flake-parts)

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    dnvr.url = "github:dialohq/dnvr";
    # dnvr pins its own nixpkgs (nixos-26.05) and builds everything from
    # it; follows swaps in yours instead.
    dnvr.inputs.nixpkgs.follows = "nixpkgs";
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
$ dnvr up                 # persistent dashboard with pg + api panes
```

## The `dnvr` CLI

Every devshell carries a `dnvr` command scoped to its shell:

```console
$ dnvr --help     # everything in this shell: commands, descriptions
$ dnvr up         # launch the process group
$ dnvr ps         # process status: pid + liveness per process
$ dnvr logs api   # plain-text snapshot of api's retained scrollback
$ dnvr migrate    # run a script (scripts are also on PATH directly)
$ dnvr state dump # dnvr-state passthrough
```

### Persistent process dashboard

Every process command runs directly in its own tmux pane. The dashboard keeps
a fixed process-list pane on the left
and swaps the selected process into the pane on the right; background
processes remain in detached tmux windows. A Rust/ratatui sidebar has no redraw
timer and uses buffered cell diffs only for input, resize, focus, or process
lifecycle events. Reattaching after a dnvr rebuild upgrades that sidebar in
place without restarting the process panes.

- `j`/`k` moves the selection. `Enter` first shows that process and a second
  `Enter` enters its pane; `●` means shown and `▶` means interactive.
- Clicking a process opens it; tmux mouse selection and log scrolling work.
- `Ctrl-A` returns focus to the sidebar; `Ctrl-G` detaches cleanly.
- `r` restarts and `x` interrupts the selected process; `Q` stops the group.
- Running `dnvr up` again reattaches to the existing session.
- `dnvr logs <process>` dumps the entire retained tmux scrollback as plain
  text for humans and agents. `--ansi` preserves colors, `-n <lines>` limits
  the snapshot, and `-f` follows the full-session archive.
- Raw process output is also appended under `.dnvr/logs/tmux-<shell>-up/`.

#### Sidebar REST API

The sidebar listens on a random loopback TCP port and publishes its URL in the
tmux session option `@dnvr_sidebar_api_url`. Discover it from another terminal
using the shell's tmux socket:

```console
$ socket="$DNVR_STATE/runtime/tmux-<shell>-up.sock"
$ api=$(tmux -S "$socket" show-option -gv @dnvr_sidebar_api_url)
$ curl "$api/v1/health"
{"status":"ok"}
```

The API lists every live or exited tmux pane tagged as a dnvr process, with its
name, stable index, pane ID, PID, running state, current command, and exit code:

```console
$ curl "$api/v1/processes"
{"processes":[{"name":"api","index":0,"pane":"%1","pid":1234,"running":true,"command":"api","exitCode":null}]}
```

Process names are URL-encoded path parameters. Restart or interrupt one process,
or stop the entire dnvr session, with POST requests:

```console
$ curl -X POST "$api/v1/processes/api/restart"
{"status":"ok"}
$ curl -X POST "$api/v1/processes/api/interrupt"
{"status":"ok"}
$ curl -X POST "$api/v1/stop"
{"status":"stopping"}
```

Restart uses tmux's `respawn-pane -k`, interrupt sends `C-c`, and stop has the
same group-wide behavior as pressing `Q` in the sidebar. Stop returns `202
Accepted` before terminating the tmux session and its API server.

The result is collected from tmux when the request arrives rather than cached
in the HTTP thread. The listener defaults to `127.0.0.1:0`; set
`DNVR_SIDEBAR_API_ADDRESS` before `dnvr up` to select a specific loopback
address. The API has no authentication and should not be bound to a
non-loopback interface.

From the dnvr repository, the development fixture exposes the same CLI through
`nix run`. Start its dashboard in one terminal, then query it from another:

```console
$ nix run --impure --expr 'import ./dev/tmux-ui.nix'
$ nix run --impure --expr 'import ./dev/tmux-ui.nix' '' -- logs stream
```

### Completion

Completion ships with the devshell — no per-user setup for most paths.
Completion files sit in standard `share/` locations and the shellHook exports
`XDG_DATA_DIRS` and `NIX_PROFILES` pointing at them:

- `nix develop .#<name>` (bash) — registered directly by the shellHook.
- bash + bash-completion + direnv — bash-completion resolves `XDG_DATA_DIRS`
  lazily at first `<tab>`, so it picks dnvr up as soon as direnv loads the env.
- any fish/nushell (≥0.96) **started inside** the devshell — they read
  `XDG_DATA_DIRS` at startup (nushell vendor-autoloads
  `share/nushell/vendor/autoload/dnvr-completions.nu`).
- any nix-managed zsh (nix-darwin, NixOS, home-manager) **started inside**
  the devshell — their init scans `$profile/share/zsh/site-functions` for
  every entry in `NIX_PROFILES` before `compinit`, and the shellHook appends
  the completions root there. Append-only, so nothing else about the shell
  changes. (Non-nix-managed zsh: add the same scan of `XDG_DATA_DIRS` to
  `.zshrc` before `compinit`:
  `for _d in ${(s.:.)XDG_DATA_DIRS}; fpath+=($_d/zsh/site-functions)`.)

The devshell deliberately does **not** export `FPATH`: zsh imports an
inherited `FPATH` verbatim as its entire `fpath` — dropping its own
compiled-in function directory, which breaks `compinit` and every other
autoload in any zsh started inside the devshell.

The one case that isn't automatic out of the box: a shell that was **already
running** when direnv loaded the env — it computed its completion paths at
startup. This is a hard limit for zsh: `compinit` has already run, direnv can
only export variables, and zsh has no lazy loader (bash only manages it
because bash-completion ships one). Register on demand with

```zsh
eval "$(dnvr completions zsh)"
```

or automate it with a one-time `.zshrc` hook that fires when a dnvr shell
appears on PATH:

```zsh
_dnvr_completion_hook() {
  (( ${+_comps[dnvr]} )) && return
  (( ${+commands[dnvr]} && ${+functions[compdef]} )) && eval "$(dnvr completions zsh)"
}
precmd_functions+=(_dnvr_completion_hook)
```

For nushell + direnv the shellHook materializes the completion module at a
stable path (`.dnvr/dnvr-completions.nu`), so a one-time hook next to the
direnv integration makes it automatic (string hooks run in REPL scope, so
they can load overlays):

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

The flake module injects these into `perSystem` and — uniformly — into
every `dnvr.shells.<name>` submodule, its processes, and its scripts:

| arg | what it is |
|---|---|
| `presets` | Built-in process presets (`postgres`, `clickhouse`) plus `dnvr.presets`. |
| `runners` | The tmux up-script builder plus `dnvr.extraRunners`. |
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
  and carry custom-runner config under `runner_settings.<runner>.<key>`;
  each runner reads only its own key. Each process gets `DNVR_RUNTIME_DIR`
  scoped to its name so
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
- `runner` — defaults to the persistent, reattachable `runners.tmux` sidebar
  viewer. It may be replaced by a custom `dnvr.extraRunners` entry.
- `cli` — read-only shell-scoped `dnvr` CLI package.
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
  is not a ref concern. A custom runner may expose native ordering through
  `runner_settings`; keep truly-once initialization
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
- `dnvr.specialArgs` — extra module args (e.g. `{inherit inputs;}`)
  injected into every `dnvr.shells.<name>` submodule and their
  process/script submodules.
- `dnvr.picker.enable` — a devshell that pops a `gum choose` TUI over the
  declared shells, writes `.envrc` for the chosen one, and hands off to
  direnv. Exposed as `dnvr.picker.shellName` (default `"default"`, so plain
  `nix develop` lands on it; set e.g. `"picker"` for `nix develop .#picker`).
- `dnvr.lib` — read-only handle to the framework
  (`{mkShells, mkScript, runners, presets, dnvrState}`).

## Without flake-parts

`dnvr.lib.mkDevShells` takes a module: everything except `system`,
`specialArgs`, and the optional `presets`/`extraRunners` registries is
module config, so `imports` and `dnvr.shells.<name>` sit at the top
level exactly as they do under flake-parts' `perSystem`. Plain flake:

```nix
{
  inputs = {
    dnvr.url = "github:dialohq/dnvr";
  };

  outputs = {dnvr, ...}: {
    devShells.aarch64-darwin = dnvr.lib.mkDevShells {
      system = "aarch64-darwin";
      imports = [./shells.nix];
    };
  };
}
```

```nix
# shells.nix — moves between this and flake-parts unchanged
{presets, ...}: {
  dnvr.shells.backend = {
    processes.pg = {
      imports = [presets.postgres];
      database = "app";
    };
  };
}
```

flake-utils, same call inside the loop:

```nix
outputs = {flake-utils, dnvr, ...}:
  flake-utils.lib.eachDefaultSystem (system: {
    devShells = dnvr.lib.mkDevShells {
      inherit system;
      imports = [./shells.nix];
    };
  });
```

Inline declarations work the same way — `dnvr.shells.<name> = { ... }`
directly in the call. Shell modules get the same args as under
flake-parts (`presets`, `runners`, `mkScript`, `dnvrState`), and
`specialArgs = {inherit inputs;}` injects your own alongside them at
every module level — the imported file's head, shells, processes, and
scripts alike. Reserved names (`name`, `pkgs`, `presets`, and the
other framework/module-system args) are rejected with an error rather
than silently shadowed. One portability note: under flake-parts the
equivalent `dnvr.specialArgs` starts at the `dnvr.shells.<name>` level
(the perSystem module's own args belong to flake-parts), so a module
meant to move between both setups should destructure custom args in
the shell module, not the file head. The picker is flake-parts-only.
For full control, `dnvr.lib.mkDnvr {inherit system;}` returns
`{mkShells, mkScript, runners, presets, dnvrState}` (also takes
`specialArgs`), where `mkShells [module1 module2]` returns
`{devShells, ups, config}`.
