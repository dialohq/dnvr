{
  name,
  config,
  lib,
  pkgs,
  mkScript,
  runners,
  presets,
  dnvrState,
  ...
}: let
  inherit (lib) mkOption types;

  processValues = lib.attrValues config.processes;

  processPackages = lib.concatMap (p: p.packages) processValues;

  # env refs — an env value that is exactly `<scheme>://<rest>`, where
  # <scheme> has an entry in `refHandlers`, is a reference: the handler's
  # command resolves it at process start, and its stdout becomes the var.
  # Whole-value refs only. Values whose scheme has no handler (https://…,
  # postgres://…) pass through as plain env. The built-in dnvr:// handler
  # reads another process's dnvr-state key (blocking until published), and
  # dnvr refs double as the dependency graph (`config.dependencies`).
  matchUrl = v:
    if !(builtins.isString v)
    then null
    else let
      m = builtins.match "([a-z][a-z0-9+.-]*)://(.+)" v;
    in
      if m == null
      then null
      else {
        scheme = lib.elemAt m 0;
        rest = lib.elemAt m 1;
      };

  parseRef = v: let
    u = matchUrl v;
  in
    if u == null || !(config.refHandlers ? ${u.scheme})
    then null
    else u // {handler = config.refHandlers.${u.scheme};};

  # dnvr://<proc>/<key> — process names can't contain dots (dnvr-state
  # splits `<proc>.<key>` on the first dot); keys can. To hand a consumer a
  # composed value (a URL, a conn string), publish it composed from the
  # producer.
  parseDnvrRef = v: let
    m = builtins.match "dnvr://([A-Za-z0-9_-]+)/([A-Za-z0-9._-]+)" v;
  in
    if m == null
    then null
    else {
      proc = lib.elemAt m 0;
      key = lib.elemAt m 1;
    };

  refsOf = lib.filterAttrs (_: v: parseRef v != null);
  plainOf = lib.filterAttrs (_: v: parseRef v == null);
  dnvrRefsOf = lib.filterAttrs (_: v: parseRef v != null && (parseRef v).scheme == "dnvr");

  processRefs = lib.mapAttrs (_: p: refsOf p.env) config.processes;
  envRefs = refsOf config.env;

  # Ref-valued vars bind to the process that declares them (resolved in its
  # wrapper); only plain values flow into the shared runner/shell env.
  allEnv = lib.foldl' (a: p: a // plainOf p.env) {} processValues // plainOf config.env;

  knownProcs = lib.attrNames config.processes;

  # consumer -> [producers], for every process (empty list when no dnvr
  # refs). Only the dnvr scheme creates edges — other handlers resolve
  # values without implying process dependencies.
  depGraph =
    lib.mapAttrs (
      procName: refs:
        lib.unique (lib.filter (d: d != procName)
          (map (v: (parseDnvrRef v).proc)
            (lib.filter (v: parseDnvrRef v != null) (lib.attrValues (dnvrRefsOf refs)))))
    )
    processRefs;

  dnvrRefErrors = owner: var: v: let
    r = parseDnvrRef v;
  in
    if r == null
    then ["${owner}: env.${var} = \"${v}\" is a malformed dnvr:// ref (expected dnvr://<process>/<key>)"]
    else
      lib.optional (!(lib.elem r.proc knownProcs))
      "${owner}: env.${var} = \"${v}\" references unknown process '${r.proc}' (processes: ${lib.concatStringsSep ", " knownProcs})";

  sorted = lib.toposort (a: b: lib.elem a (depGraph.${b} or [])) knownProcs;

  refProblems =
    lib.concatLists (lib.mapAttrsToList (
        procName: refs:
          lib.concatLists (lib.mapAttrsToList (
              var: v:
                dnvrRefErrors "process '${procName}'" var v
                ++ lib.optional (parseDnvrRef v != null && (parseDnvrRef v).proc == procName)
                "process '${procName}': env.${var} = \"${v}\" references itself — it would wait for its own key and time out"
            )
            (dnvrRefsOf refs))
      )
      processRefs)
    ++ lib.concatLists (lib.mapAttrsToList (dnvrRefErrors "env") (dnvrRefsOf envRefs))
    ++ lib.optional (sorted ? cycle)
    "dependency cycle among processes: ${lib.concatStringsSep " -> " sorted.cycle} — each would wait for the other's key";

  checkRefs = x:
    if refProblems == []
    then x
    else throw "dnvr shell '${name}': invalid dnvr:// refs:\n  - ${lib.concatStringsSep "\n  - " refProblems}";
  allScripts = lib.foldl' (a: p: a // p.scripts) {} processValues // config.scripts;

  scriptPkgs =
    lib.mapAttrsToList
    (n: s:
      mkScript {
        name = n;
        inherit (s) shell text runtimeInputs;
      })
    allScripts;

  # Wrap each process's command so DNVR_RUNTIME_DIR points at the per-process
  # runtime/<procname> directory and dnvr-state is on PATH. Lets the inner
  # command just say `dnvr-state set port 5432` without knowing its own name.
  # dnvr:// env refs resolve here, before the exec: the wrapper blocks on
  # `dnvr-state wait` until the producer publishes, then exports the value —
  # so startup ordering falls out of data readiness, no depends_on needed.
  # String commands normally pass through untouched, but a string command
  # with refs gets the same wrapper (and thereby set -euo pipefail).
  # The runner receives only {command, runner_settings} — the devshell-facing
  # buckets (packages, env, scripts) must not leak into runner configs.
  wrapProcess = procName: p: let
    refs = processRefs.${procName};
    resolveRefs = lib.concatStrings (lib.mapAttrsToList (var: v: let
      r = parseRef v;
    in ''
      ${var}="$(${r.handler.command v})"
      export ${var}
    '')
    refs);
    handlerInputs =
      lib.unique (lib.concatMap (v: (parseRef v).handler.runtimeInputs) (lib.attrValues refs));
    wrapped =
      if lib.isDerivation p.command || refs != {}
      then
        pkgs.writeShellApplication {
          name = "${procName}-scoped";
          runtimeInputs = [dnvrState] ++ handlerInputs;
          text = ''
            : "''${DNVR_STATE:?DNVR_STATE must be set}"
            export DNVR_RUNTIME_DIR="$DNVR_STATE/runtime/${procName}"
            mkdir -p "$DNVR_RUNTIME_DIR"
            ${resolveRefs}${
            if lib.isDerivation p.command
            then ''exec ${lib.getExe p.command} "$@"''
            else p.command
          }
          '';
        }
      else p.command;
  in {
    command = wrapped;
    inherit (p) runner_settings;
  };

  wrappedProcesses = lib.mapAttrs wrapProcess config.processes;

  upScript = config.runner {
    name = "${name}-up";
    processes = wrappedProcesses;
    env = allEnv;
    prerun = config.prerun;
  };

  envForShell = lib.mapAttrs (_: v: toString v) allEnv;

  # Refs in the devshell resolve best-effort at entry (skipped entirely for
  # handlers with `resolveInShell = false`): failures are silent, so e.g.
  # dnvr refs export only what's already published — a shell entered after
  # `dnvr up` sees live values, one entered before doesn't. Inside the
  # running processes the wrapper's resolution is authoritative.
  shellRefs = lib.foldl' (a: r: a // r) {} (lib.attrValues processRefs) // envRefs;

  refShellExports = lib.concatStrings (lib.mapAttrsToList (var: v: let
    r = parseRef v;
    cmd =
      if r.handler.shellCommand != null
      then r.handler.shellCommand v
      else r.handler.command v;
    pathPrefix =
      lib.optionalString (r.handler.runtimeInputs != [])
      "PATH=${lib.makeBinPath r.handler.runtimeInputs}:$PATH ";
  in
    lib.optionalString r.handler.resolveInShell ''
      if ${var}="$(${pathPrefix}${cmd} 2>/dev/null)"; then export ${var}; fi
    '')
  shellRefs);

  # Banner: rendered by `gum style` at runtime. The nix string holds only plain
  # text — no raw ANSI bytes that would otherwise trip nix's strict JSON parser
  # when nix-direnv captures the dev-env via `nix print-dev-env --json`.
  # Padding uses plain text length so alignment is correct regardless of how
  # gum colors the output.
  padTo = width: s: let
    pad = width - (lib.stringLength s);
  in
    lib.optionalString (pad > 0) (lib.fixedWidthString pad " " "");

  titleSuffix = lib.optionalString (config.description != "") " — ${config.description}";

  scriptRows =
    lib.mapAttrsToList (n: s: {
      name = n;
      desc = s.description;
    })
    allScripts;

  # What `dnvr --list` offers — this is what <tab> completes and what
  # --help shows: `up` first, then the scripts. The completers call
  # `dnvr --list` at completion time, so one snippet in a shell config
  # covers every env. `state` and `completions` still work as
  # subcommands but stay out of both.
  listRows =
    [
      {
        name = "up";
        desc = "launch process group (${lib.concatStringsSep ", " (map procLabel (lib.attrNames wrappedProcesses))})";
      }
    ]
    ++ scriptRows;

  # "api→pg" in listings when api consumes one of pg's keys.
  procLabel = n:
    if depGraph.${n} == []
    then n
    else "${n}→${lib.concatStringsSep "," (depGraph.${n})}";

  renderRows = prefix: rows: let
    nameWidth = lib.foldl' lib.max 0 (map (c: lib.stringLength c.name) rows);
  in
    map (c: "  ${prefix}${c.name}${padTo (nameWidth + 2) c.name}${c.desc}") rows;

  helpText = lib.concatStringsSep "\n" (
    ["dnvr: ${name}${titleSuffix}"]
    ++ ["" "commands:"]
    ++ renderRows "dnvr " listRows
    ++ [
      ""
      "Scripts are also on the shell PATH directly; `dnvr <script>` and `<script>` are equivalent."
      "Completion is automatic in shells started inside this env. For an already-running"
      "nushell: `overlay use .dnvr/dnvr-completions.nu`. Other shells: `dnvr completions <shell>`."
    ]
  );

  listText = lib.concatMapStrings (c: "${c.name}\t${c.desc}\n") listRows;

  bashCompletion = ''
    _dnvr() {
      local cur
      cur="''${COMP_WORDS[COMP_CWORD]}"
      [ "$COMP_CWORD" -eq 1 ] || return 0
      mapfile -t COMPREPLY < <(compgen -W "$(dnvr --list 2>/dev/null | cut -f1)" -- "$cur")
    }
    complete -F _dnvr dnvr
  '';

  zshFunction = ''
    _dnvr() {
      local -a lines cmds
      lines=("''${(@f)$(dnvr --list 2>/dev/null)}")
      cmds=("''${lines[@]//$'\t'/:}")
      _describe -V -t commands 'dnvr command' cmds
    }
  '';

  # For eval'ing into a live shell (`dnvr completions zsh`).
  zshCompletion = zshFunction + "compdef _dnvr dnvr\n";

  # Autoloadable fpath file (share/zsh/site-functions/_dnvr).
  zshCompletionFile = "#compdef dnvr\n" + zshFunction + "_dnvr \"$@\"\n";

  fishCompletion = ''
    complete -c dnvr -f
    complete -c dnvr -n __fish_use_subcommand -a '(dnvr --list 2>/dev/null)'
  '';

  # Exported so the file works as a module: nushell vendor-autoloads it in
  # shells started inside the env, and `overlay use .dnvr/dnvr-completions.nu`
  # loads it into an already-running REPL (venv activate.nu style).
  nuCompletion = ''
    export def "nu-complete dnvr" [] {
      if (which dnvr | is-empty) {
        return []
      }
      {
        options: {sort: false}
        completions: (^dnvr --list | lines | each {|line|
          let parts = ($line | split row "\t")
          {
            value: ($parts | first)
            description: (if ($parts | length) > 1 { $parts | get 1 } else { "" })
          }
        })
      }
    }

    export extern "dnvr" [
      command?: string@"nu-complete dnvr"
      ...args: string
    ]
  '';

  # Completion files in the standard discovery locations, wired up via
  # XDG_DATA_DIRS/FPATH in the shellHook. bash-completion resolves
  # XDG_DATA_DIRS lazily at first <tab>, so it works even when the env arrives
  # via direnv; fish, zsh, and nushell (≥0.96 vendor autoload) read these
  # paths at shell startup, covering any shell launched inside the devshell.
  dnvrShare = pkgs.linkFarm "dnvr-completions" [
    {
      name = "share/bash-completion/completions/dnvr";
      path = pkgs.writeText "dnvr.bash" bashCompletion;
    }
    {
      name = "share/zsh/site-functions/_dnvr";
      path = pkgs.writeText "_dnvr" zshCompletionFile;
    }
    {
      name = "share/fish/vendor_completions.d/dnvr.fish";
      path = pkgs.writeText "dnvr.fish" fishCompletion;
    }
    {
      name = "share/nushell/vendor/autoload/dnvr-completions.nu";
      path = nuCompletionFile;
    }
  ];

  # Named so the module name differs from the `dnvr` extern — nushell
  # forbids `export extern "dnvr"` from a module itself named `dnvr`.
  nuCompletionFile = pkgs.writeText "dnvr-completions.nu" nuCompletion;

  scriptDispatch = lib.concatMapStrings (n: ''
    "${n}")
      shift
      exec "${n}" "$@"
      ;;
  '') (lib.attrNames allScripts);

  dnvrCli = pkgs.writeShellApplication {
    name = "dnvr";
    runtimeInputs = [upScript dnvrState] ++ scriptPkgs;
    # The help/list/completions bodies are single-quoted on purpose (printf
    # '%s' with escapeShellArg); SC2016 flags the $ inside them.
    excludeShellChecks = ["SC2016"];
    text = ''
      cmd="''${1:-}"
      case "$cmd" in
        "" | --help | -h | help)
          printf '%s\n' ${lib.escapeShellArg helpText}
          ;;
        --list)
          printf '%s' ${lib.escapeShellArg listText}
          ;;
        up)
          shift
          exec "${name}-up" "$@"
          ;;
        state)
          shift
          exec dnvr-state "$@"
          ;;
        completions)
          case "''${2:-}" in
            bash)
              printf '%s' ${lib.escapeShellArg bashCompletion}
              ;;
            zsh)
              printf '%s' ${lib.escapeShellArg zshCompletion}
              ;;
            fish)
              printf '%s' ${lib.escapeShellArg fishCompletion}
              ;;
            nu | nushell)
              printf '%s' ${lib.escapeShellArg nuCompletion}
              ;;
            *)
              echo "usage: dnvr completions <bash|zsh|fish|nushell>" >&2
              exit 64
              ;;
          esac
          ;;
      ${scriptDispatch}
        *)
          echo "dnvr: unknown command '$cmd' (try 'dnvr --help')" >&2
          exit 64
          ;;
      esac
    '';
  };

  bannerLines = let
    rows =
      [
        {
          name = "dnvr up";
          desc = "launch process group";
        }
      ]
      ++ scriptRows
      ++ [
        {
          name = "dnvr --help";
          desc = "list everything in this shell";
        }
      ];
  in
    ["dnvr: ${name}${titleSuffix}"]
    ++ ["commands:"]
    ++ renderRows "" rows;

  # Stamp in $DNVR_STATE; only re-print if the stamp is missing or older than
  # 3 days. Otherwise direnv would blast the banner on every cd in / reload.
  bannerScript = ''
    __dnvr_banner_stamp="$DNVR_STATE/.banner-shown-${name}"
    if [ ! -f "$__dnvr_banner_stamp" ] || [ -z "$(${pkgs.findutils}/bin/find "$__dnvr_banner_stamp" -newermt '3 days ago' 2>/dev/null)" ]; then
      ${pkgs.gum}/bin/gum style \
        --border rounded \
        --border-foreground 6 \
        --foreground 7 \
        --padding "0 1" \
        --margin "1 0 0 0" \
        ${lib.escapeShellArgs bannerLines}
      ${pkgs.coreutils}/bin/touch "$__dnvr_banner_stamp"
    fi
    unset __dnvr_banner_stamp
  '';

in {
  options = {
    description = mkOption {
      type = types.str;
      default = "";
      description = "One-line summary shown in the entry banner.";
    };

    packages = mkOption {
      type = types.listOf types.package;
      default = [];
    };

    scripts = mkOption {
      type = types.attrsOf (types.submodule ({name, ...}: {
        options = {
          shell = mkOption {
            type = types.package;
            default = pkgs.bash;
            description = "Interpreter package, e.g. pkgs.bash, pkgs.nushell, pkgs.zsh.";
          };
          text = mkOption {
            type = types.lines;
            description = "Script body. Shebang is added automatically.";
          };
          runtimeInputs = mkOption {
            type = types.listOf types.package;
            default = [];
          };
          description = mkOption {
            type = types.str;
            default = "";
            description = "Shown in the entry banner.";
          };
        };
      }));
      default = {};
      description = "Scripts exposed on the devshell's PATH.";
    };

    processes = mkOption {
      type = types.attrsOf (types.submoduleWith {
        modules = [./process-module.nix];
        specialArgs = {inherit pkgs presets dnvrState;};
      });
      default = {};
      description = ''
        Processes that the runner orchestrates. Each is a module — import a
        preset (`imports = [presets.postgres]`) or set `command` directly.
        Processes also contribute packages, env, and scripts to the devshell.
      '';
    };

    env = mkOption {
      type = types.attrsOf types.anything;
      default = {};
      description = ''
        Env vars set on the devshell and exported to the runner. A
        `dnvr://<proc>/<key>` value here is a shell convenience only:
        resolved best-effort at shell entry, never sent to the runner and
        never a dependency edge — put refs on the consuming process's `env`
        for that.
      '';
    };

    refHandlers = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          command = mkOption {
            type = types.functionTo types.str;
            description = ''
              Given the whole ref value (e.g. "op://vault/item/field"),
              return a shell command whose stdout becomes the var. Runs in
              the process wrapper before the command starts; a failing
              resolver aborts the process.
            '';
          };
          shellCommand = mkOption {
            type = types.nullOr (types.functionTo types.str);
            default = null;
            description = ''
              Override used at devshell entry instead of `command` (null =
              use `command`). The dnvr handler uses this to `get`
              non-blockingly in the shell while processes `wait`.
            '';
          };
          resolveInShell = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Resolve this scheme best-effort at devshell entry. Disable
              for slow or interactive resolvers (e.g. op:// auth prompts).
            '';
          };
          runtimeInputs = mkOption {
            type = types.listOf types.package;
            default = [];
            description = "Packages the resolver needs on PATH.";
          };
        };
      });
      default = {};
      description = ''
        URL-scheme handlers for env refs, keyed by scheme. An env value
        that is exactly `<scheme>://…` with a handler here is resolved by
        it; schemes without handlers pass through as plain values. The
        built-in `dnvr` entry resolves `dnvr://<proc>/<key>` via
        dnvr-state and is the only scheme that creates dependency edges.
      '';
    };

    dependencies = mkOption {
      type = types.attrsOf (types.listOf types.str);
      readOnly = true;
      description = ''
        Dependency graph derived from dnvr:// env refs:
        `<process> -> [processes whose keys it consumes]`. Every process is
        a key; processes without refs map to `[]`.
      '';
    };

    prerun = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Shell code executed inside the up-script before the runner exec.
        Has DNVR_ROOT and DNVR_STATE available. Anything `export`ed here
        flows into the runner, which propagates to every process. Use this
        for dynamic-port picking and similar runtime env setup.
      '';
    };

    shellHook = mkOption {
      type = types.lines;
      default = "";
    };

    runner = mkOption {
      type = types.functionTo types.package;
      default = runners.mprocs;
      description = "Function `{name, processes, env}: drv` that produces the up-script.";
    };

    flags = mkOption {
      type = types.attrsOf types.anything;
      default = {};
      description = "Free-form switches modules can read to alter behaviour (e.g. flags.ci).";
    };

    shell = mkOption {
      type = types.package;
      readOnly = true;
      description = "The final devshell derivation.";
    };

    up = mkOption {
      type = types.package;
      readOnly = true;
      description = "The runner up-script as a standalone derivation.";
    };
  };

  config.refHandlers.dnvr = {
    command = url: let
      r = parseDnvrRef url;
    in "dnvr-state wait ${r.proc}.${r.key} --timeout 120";
    shellCommand = url: let
      r = parseDnvrRef url;
    in "dnvr-state get ${r.proc}.${r.key}";
    runtimeInputs = [dnvrState];
  };

  config.dependencies = depGraph;

  config.up = checkRefs upScript;

  config.shell = checkRefs (pkgs.mkShell ({
      name = "dnvr-${name}";
      packages = config.packages ++ processPackages ++ scriptPkgs ++ [dnvrState dnvrCli];
      shellHook = ''
        export DNVR_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
        export DNVR_STATE="$DNVR_ROOT/.dnvr"
        mkdir -p "$DNVR_STATE"
        ${refShellExports}export XDG_DATA_DIRS="${dnvrShare}/share''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
        export FPATH="${dnvrShare}/share/zsh/site-functions''${FPATH:+:$FPATH}"
        ${pkgs.coreutils}/bin/install -m 0644 ${nuCompletionFile} "$DNVR_STATE/dnvr-completions.nu"
        if [ -n "''${BASH_VERSION:-}" ] && [[ $- == *i* ]]; then
          eval "$(dnvr completions bash)"
        fi
        ${bannerScript}
        ${config.shellHook}
      '';
    }
    // (lib.optionalAttrs (envForShell != {}) {env = envForShell;})));
}
