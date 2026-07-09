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
  allEnv = lib.foldl' (a: p: a // p.env) {} processValues // config.env;
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
  # The runner receives only {command, runner_settings} — the devshell-facing
  # buckets (packages, env, scripts) must not leak into runner configs.
  wrapProcess = procName: p: let
    wrapped =
      if lib.isDerivation p.command
      then
        pkgs.writeShellApplication {
          name = "${procName}-scoped";
          runtimeInputs = [dnvrState];
          text = ''
            : "''${DNVR_STATE:?DNVR_STATE must be set}"
            export DNVR_RUNTIME_DIR="$DNVR_STATE/runtime/${procName}"
            mkdir -p "$DNVR_RUNTIME_DIR"
            exec ${lib.getExe p.command} "$@"
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
        desc = "launch process group (${lib.concatStringsSep ", " (lib.attrNames wrappedProcesses)})";
      }
    ]
    ++ scriptRows;

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
      description = "Env vars set on the devshell and exported to the runner.";
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

  config.up = upScript;

  config.shell = pkgs.mkShell ({
      name = "dnvr-${name}";
      packages = config.packages ++ processPackages ++ scriptPkgs ++ [dnvrState dnvrCli];
      shellHook = ''
        export DNVR_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
        export DNVR_STATE="$DNVR_ROOT/.dnvr"
        mkdir -p "$DNVR_STATE"
        export XDG_DATA_DIRS="${dnvrShare}/share''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
        export FPATH="${dnvrShare}/share/zsh/site-functions''${FPATH:+:$FPATH}"
        ${pkgs.coreutils}/bin/install -m 0644 ${nuCompletionFile} "$DNVR_STATE/dnvr-completions.nu"
        if [ -n "''${BASH_VERSION:-}" ] && [[ $- == *i* ]]; then
          eval "$(dnvr completions bash)"
        fi
        ${bannerScript}
        ${config.shellHook}
      '';
    }
    // (lib.optionalAttrs (envForShell != {}) {env = envForShell;}));
}
