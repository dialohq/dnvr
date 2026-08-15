{
  name,
  config,
  lib,
  pkgs,
  mkScript,
  runners,
  presets,
  dnvrSpecialArgs,
  ...
}: let
  inherit (lib) mkOption types;

  processValues = lib.attrValues config.processes;

  processPackages = lib.concatMap (p: p.packages) processValues;

  # An env value that is exactly `<scheme>://<rest>` for a scheme present
  # in `refHandlers` is a ref; semantics live in the refHandlers option.
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
  # splits `<proc>.<key>` on the first dot); keys can.
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
    ++ lib.mapAttrsToList (
      var: v: "env.${var} = \"${v}\": this scheme resolves only at process start (inShell = false) — move it to the consuming process's env, or read it live with `dnvr-state get`"
    )
    (lib.filterAttrs (_: v: !(parseRef v).handler.inShell) envRefs)
    ++ lib.optional (sorted ? cycle)
    "dependency cycle among processes: ${lib.concatStringsSep " -> " sorted.cycle} — each would wait for the other's key";

  allScripts = lib.foldl' (a: p: a // p.scripts) {} processValues // config.scripts;

  # The dnvr CLI dispatches scripts after its built-in subcommands, so a
  # script by one of these names would exist but never be reachable.
  reservedCliNames = ["up" "ps" "logs" "state" "completions" "help"];

  scriptProblems =
    map (n: "scripts.${n} shadows the built-in `dnvr ${n}` subcommand — pick another name")
    (lib.filter (n: lib.elem n reservedCliNames) (lib.attrNames allScripts));

  problems = refProblems ++ scriptProblems;

  checkProblems = x:
    if problems == []
    then x
    else throw "dnvr shell '${name}': invalid configuration:\n  - ${lib.concatStringsSep "\n  - " problems}";

  scriptPkgsByName =
    lib.mapAttrs
    (n: s:
      mkScript {
        name = n;
        inherit (s) shell text runtimeInputs;
      })
    allScripts;
  scriptPkgs = lib.attrValues scriptPkgsByName;

  # Ref-cache plumbing shared by the process wrapper (hard-fail) and the
  # devshell hook (best-effort). Cached values are plaintext files keyed by
  # the ref URL — dev-grade by design; `dnvr state cache-clear` flushes.
  refCacheDir = "$DNVR_STATE/ref-cache";
  refCachePath = url: "${refCacheDir}/${builtins.hashString "sha256" url}";
  refCacheFresh = url: ttl: ''[ -f "${refCachePath url}" ] && [ -n "$(${pkgs.findutils}/bin/find "${refCachePath url}" -newermt "${toString ttl} seconds ago" 2>/dev/null)" ]'';
  refCacheWrite = var: url: ''
    ${pkgs.coreutils}/bin/mkdir -p "${refCacheDir}"
    (umask 077; printf '%s' "''$${var}" > "${refCachePath url}.tmp$$" && ${pkgs.coreutils}/bin/mv "${refCachePath url}.tmp$$" "${refCachePath url}")'';

  # At process start resolution is authoritative: cache-fresh value or a
  # live resolve; a resolver failure aborts the process (set -e).
  procResolveRef = var: v: let
    r = parseRef v;
    ttl = r.handler.cache.ttl;
  in
    if ttl == null
    then ''
      ${var}="$( ${r.handler.command v} )"
      export ${var}
    ''
    else ''
      if ${refCacheFresh v ttl}; then
        ${var}="$(${pkgs.coreutils}/bin/cat "${refCachePath v}")"
      else
        ${var}="$( ${r.handler.command v} )"
        ${refCacheWrite var v}
      fi
      export ${var}
    '';

  # At shell entry resolution is best-effort: warn and skip on failure.
  entryResolveRef = var: v: let
    r = parseRef v;
    ttl = r.handler.cache.ttl;
    pathPrefix =
      lib.optionalString (r.handler.runtimeInputs != [])
      "PATH=${lib.makeBinPath r.handler.runtimeInputs}:$PATH ";
    run = "${pathPrefix}${r.handler.command v}";
    warn = ''echo "dnvr: could not resolve ${var} (${v})" >&2'';
  in
    if ttl == null
    then ''
      if ${var}="$( ${run} 2>/dev/null )"; then
        export ${var}
      else
        ${warn}
      fi
    ''
    else ''
      if ${refCacheFresh v ttl}; then
        export ${var}="$(${pkgs.coreutils}/bin/cat "${refCachePath v}")"
      elif ${var}="$( ${run} 2>/dev/null )"; then
        ${refCacheWrite var v}
        export ${var}
      else
        ${warn}
      fi
    '';

  # Everything with an inShell handler exports at entry: process refs (so
  # ad-hoc scripts see the same values the process will) and shell-level
  # refs (entry-only; they never reach the runner).
  entryRefs =
    lib.filterAttrs (_: v: (parseRef v).handler.inShell)
    (lib.foldl' (a: r: a // r) {} (lib.attrValues processRefs) // envRefs);

  refEntryExports = lib.concatStrings (lib.mapAttrsToList entryResolveRef entryRefs);

  # Rust owns process scoping, stale-state cleanup, and the lifetime PID lock.
  # A shell wrapper remains only when ref handlers need to execute configured
  # resolver commands before the final process command.
  wrapProcess = procName: p: let
    refs = processRefs.${procName};
    resolveRefs = lib.concatStrings (lib.mapAttrsToList procResolveRef refs);
    handlerInputs =
      lib.unique (lib.concatMap (v: (parseRef v).handler.runtimeInputs) (lib.attrValues refs));
    wrapped =
      if refs != {}
      then
        pkgs.writeShellApplication {
          name = "${procName}-scoped";
          runtimeInputs = handlerInputs;
          text = ''
            : "''${DNVR_STATE:?DNVR_STATE must be set}"
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
    cli = {
      tail = "${pkgs.coreutils}/bin/tail";
      help = helpText;
      list = listText;
      ps_width = psWidth;
      scripts = lib.mapAttrs (_: package: lib.getExe package) scriptPkgsByName;
    };
  };

  inherit (import ./env-export.nix {inherit lib;}) exportLine refersToRoot;

  # Values referencing $DNVR_ROOT can't go through mkShell's static `env`
  # attr — nothing would expand them there. They export in the shellHook
  # instead, right after DNVR_ROOT is set.
  envForShell =
    lib.mapAttrs (_: v: toString v)
    (lib.filterAttrs (_: v: !(refersToRoot v)) allEnv);

  rootedEnvExports =
    lib.concatStringsSep "\n"
    (lib.mapAttrsToList exportLine (lib.filterAttrs (_: refersToRoot) allEnv));

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

  # What `dnvr --list` offers (and thereby what <tab> completes and what
  # --help shows): `up` first, then the scripts. `state` and `completions`
  # still work as subcommands but stay out of both.
  listRows =
    [
      {
        name = "up";
        desc = "launch process group (${lib.concatStringsSep ", " (map procLabel (lib.attrNames wrappedProcesses))})";
      }
      {
        name = "ps";
        desc = "process status (pid + liveness)";
      }
      {
        name = "logs";
        desc = "clean process logs for humans and agents";
      }
    ]
    ++ scriptRows;

  # Column width for `dnvr ps`: longest label, header included.
  psWidth =
    2 + lib.foldl' lib.max (lib.stringLength "PROCESS") (map lib.stringLength knownProcs);

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

  dnvrCli = upScript;

  completionFile = shell:
    pkgs.runCommand "dnvr-${shell}-completion" {} ''
      ${dnvrCli}/bin/dnvr completions ${shell} > "$out"
    '';

  nuCompletionFile = completionFile "nushell";

  # Completion files in standard discovery locations. Their contents come
  # from clap's single typed command model rather than four Nix templates.
  dnvrShare = pkgs.linkFarm "dnvr-completions" [
    {
      name = "share/bash-completion/completions/dnvr";
      path = completionFile "bash";
    }
    {
      name = "share/zsh/site-functions/_dnvr";
      path = completionFile "zsh";
    }
    {
      name = "share/fish/vendor_completions.d/dnvr.fish";
      path = completionFile "fish";
    }
    {
      name = "share/nushell/vendor/autoload/dnvr-completions.nu";
      path = nuCompletionFile;
    }
  ];

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
      type = types.attrsOf (types.submoduleWith {
        modules = [./script-module.nix];
        specialArgs = dnvrSpecialArgs;
      });
      default = {};
      description = "Scripts exposed on the devshell's PATH.";
    };

    processes = mkOption {
      type = types.attrsOf (types.submoduleWith {
        modules = [./process-module.nix];
        specialArgs = dnvrSpecialArgs;
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
        Env vars set on the devshell and exported to the runner. Refs of
        schemes with `inShell = true` (e.g. op://) are allowed here: they
        resolve best-effort at shell entry and never reach the runner.
        Schemes with `inShell = false` (dnvr://) are an eval error here —
        they resolve at process start, so they belong on the consuming
        process.
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
          inShell = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Also resolve refs of this scheme at devshell entry —
              best-effort: a failure warns on stderr and skips the export,
              never blocking the shell. The built-in dnvr handler disables
              this; its values are runtime-published and would be absent or
              stale at entry.
            '';
          };
          cache.ttl = mkOption {
            type = types.nullOr types.int;
            default = null;
            description = ''
              Seconds a resolved value stays cached — a plaintext file under
              `$DNVR_STATE/ref-cache` (written with umask 077), keyed by the
              ref URL. Used at shell entry and process start alike. null
              disables caching. Flush with `dnvr state cache-clear`.
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
      default = runners.tmux;
      description = "Function `{name, processes, env, prerun, cli}: drv` that produces the runner.";
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

    cli = mkOption {
      type = types.package;
      readOnly = true;
      description = "The shell-scoped dnvr CLI package.";
    };
  };

  config.refHandlers.dnvr = {
    command = url: let
      r = parseDnvrRef url;
    in "dnvr-state wait ${r.proc}.${r.key} --timeout 120";
    inShell = false;
    runtimeInputs = [];
  };

  config.dependencies = depGraph;

  config.up = checkProblems upScript;

  config.cli = checkProblems dnvrCli;

  config.shell = checkProblems (pkgs.mkShell ({
      name = "dnvr-${name}";
      packages = config.packages ++ processPackages ++ scriptPkgs ++ [config.cli];
      shellHook = ''
        export DNVR_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || pwd)"
        export DNVR_STATE="$DNVR_ROOT/.dnvr"
        mkdir -p "$DNVR_STATE"
        ${rootedEnvExports}
        ${refEntryExports}
        export XDG_DATA_DIRS="${dnvrShare}/share''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
        export NIX_PROFILES="''${NIX_PROFILES:+$NIX_PROFILES }${dnvrShare}"
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
