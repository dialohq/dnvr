{
  name,
  config,
  lib,
  pkgs,
  mkScript,
  runners,
  presets,
  denverState,
  ...
}: let
  inherit (lib) mkOption types;

  serviceValues = lib.attrValues config.services;

  servicePackages = lib.concatMap (s: s.packages) serviceValues;
  serviceProcesses = lib.foldl' (a: s: a // s.processes) {} serviceValues;
  serviceEnv = lib.foldl' (a: s: a // s.env) {} serviceValues;
  serviceScripts = lib.foldl' (a: s: a // s.scripts) {} serviceValues;

  allProcesses = serviceProcesses // config.processes;
  allEnv = serviceEnv // config.env;
  allScripts = serviceScripts // config.scripts;

  scriptPkgs =
    lib.mapAttrsToList
    (n: s:
      mkScript {
        name = n;
        inherit (s) shell text runtimeInputs;
      })
    allScripts;

  # Wrap each process's command so DEVENV_RUNTIME_DIR points at the per-service
  # runtime/<procname> directory and denver-state is on PATH. Lets the inner
  # command just say `denver-state set port 5432` without knowing its own name.
  wrapProcess = procName: p: let
    original = p.command or null;
    wrapped =
      if lib.isDerivation original
      then
        pkgs.writeShellApplication {
          name = "${procName}-scoped";
          runtimeInputs = [denverState];
          text = ''
            : "''${DEVENV_STATE:?DEVENV_STATE must be set}"
            export DEVENV_RUNTIME_DIR="$DEVENV_STATE/runtime/${procName}"
            mkdir -p "$DEVENV_RUNTIME_DIR"
            exec ${lib.getExe original} "$@"
          '';
        }
      else original;
  in
    if wrapped != null
    then p // {command = wrapped;}
    else p;

  wrappedProcesses = lib.mapAttrs wrapProcess allProcesses;

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
  serviceNames = lib.attrNames config.services;

  scriptRows =
    lib.mapAttrsToList (n: s: {
      name = n;
      desc = s.description;
    })
    allScripts;

  # Subcommands of the `denver` CLI. `denver --list` prints these as
  # tab-separated name/description lines; the shell completers emitted by
  # `denver completions <shell>` complete by calling `denver --list` at
  # completion time, so one snippet in a shell config covers every devenv.
  commandRows =
    [
      {
        name = "up";
        desc = "launch process group (${lib.concatStringsSep ", " (lib.attrNames wrappedProcesses)})";
      }
    ]
    ++ scriptRows
    ++ [
      {
        name = "state";
        desc = "runtime state (denver-state passthrough)";
      }
      {
        name = "completions";
        desc = "print completion code: bash|zsh|fish|nushell";
      }
    ];

  renderRows = prefix: rows: let
    nameWidth = lib.foldl' lib.max 0 (map (c: lib.stringLength c.name) rows);
  in
    map (c: "  ${prefix}${c.name}${padTo (nameWidth + 2) c.name}${c.desc}") rows;

  helpText = lib.concatStringsSep "\n" (
    ["denver: ${name}${titleSuffix}"]
    ++ lib.optional (serviceNames != []) "services: ${lib.concatStringsSep ", " serviceNames}"
    ++ ["" "commands:"]
    ++ renderRows "denver " commandRows
    ++ [
      ""
      "Scripts are also on the shell PATH directly; `denver <script>` and `<script>` are equivalent."
      "Completion: add the output of `denver completions <bash|zsh|fish|nushell>` to your shell"
      "config once; it completes via `denver --list`, so it follows whichever devenv is active."
    ]
  );

  listText = lib.concatMapStrings (c: "${c.name}\t${c.desc}\n") commandRows;

  bashCompletion = ''
    _denver() {
      local cur
      cur="''${COMP_WORDS[COMP_CWORD]}"
      [ "$COMP_CWORD" -eq 1 ] || return 0
      mapfile -t COMPREPLY < <(compgen -W "$(denver --list 2>/dev/null | cut -f1)" -- "$cur")
    }
    complete -F _denver denver
  '';

  zshCompletion = ''
    _denver() {
      local -a lines cmds
      lines=("''${(@f)$(denver --list 2>/dev/null)}")
      cmds=("''${lines[@]//$'\t'/:}")
      _describe -t commands 'denver command' cmds
    }
    compdef _denver denver
  '';

  fishCompletion = ''
    complete -c denver -f
    complete -c denver -n __fish_use_subcommand -a '(denver --list 2>/dev/null)'
  '';

  nuCompletion = ''
    def "nu-complete denver" [] {
      if (which denver | is-empty) {
        return []
      }
      ^denver --list | lines | each {|line|
        let parts = ($line | split row "\t")
        {
          value: ($parts | first)
          description: (if ($parts | length) > 1 { $parts | get 1 } else { "" })
        }
      }
    }

    export extern "denver" [
      command?: string@"nu-complete denver"
      ...args: string
    ]
  '';

  scriptDispatch = lib.concatMapStrings (n: ''
    "${n}")
      shift
      exec "${n}" "$@"
      ;;
  '') (lib.attrNames allScripts);

  denverCli = pkgs.writeShellApplication {
    name = "denver";
    runtimeInputs = [upScript denverState] ++ scriptPkgs;
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
          exec denver-state "$@"
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
              echo "usage: denver completions <bash|zsh|fish|nushell>" >&2
              exit 64
              ;;
          esac
          ;;
      ${scriptDispatch}
        *)
          echo "denver: unknown command '$cmd' (try 'denver --help')" >&2
          exit 64
          ;;
      esac
    '';
  };

  bannerLines = let
    serviceLine =
      lib.optional (serviceNames != [])
      "services: ${lib.concatStringsSep ", " serviceNames}";

    rows =
      [
        {
          name = "denver up";
          desc = "launch process group";
        }
      ]
      ++ scriptRows
      ++ [
        {
          name = "denver --help";
          desc = "list everything in this shell";
        }
      ];
  in
    ["devenv: ${name}${titleSuffix}"]
    ++ serviceLine
    ++ ["commands:"]
    ++ renderRows "" rows;

  # Stamp in $DEVENV_STATE; only re-print if the stamp is missing or older than
  # 3 days. Otherwise direnv would blast the banner on every cd in / reload.
  bannerScript = ''
    __devenv_banner_stamp="$DEVENV_STATE/.banner-shown-${name}"
    if [ ! -f "$__devenv_banner_stamp" ] || [ -z "$(${pkgs.findutils}/bin/find "$__devenv_banner_stamp" -newermt '3 days ago' 2>/dev/null)" ]; then
      ${pkgs.gum}/bin/gum style \
        --border rounded \
        --border-foreground 6 \
        --foreground 7 \
        --padding "0 1" \
        --margin "1 0 0 0" \
        ${lib.escapeShellArgs bannerLines}
      ${pkgs.coreutils}/bin/touch "$__devenv_banner_stamp"
    fi
    unset __devenv_banner_stamp
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

    services = mkOption {
      type = types.attrsOf (types.submoduleWith {
        modules = [./service-module.nix];
        specialArgs = {inherit pkgs presets;};
      });
      default = {};
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
      type = types.attrsOf types.anything;
      default = {};
      description = "Processes that the runner orchestrates. Merged on top of service-contributed processes.";
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
        Has DEVENV_ROOT and DEVENV_STATE available. Anything `export`ed here
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
      name = "devenv-${name}";
      packages = config.packages ++ servicePackages ++ scriptPkgs ++ [upScript denverState denverCli];
      shellHook = ''
        export DEVENV_ROOT="$(${pkgs.git}/bin/git rev-parse --show-toplevel)"
        export DEVENV_STATE="$DEVENV_ROOT/.devenv"
        mkdir -p "$DEVENV_STATE"
        ${bannerScript}
        ${config.shellHook}
      '';
    }
    // (lib.optionalAttrs (envForShell != {}) {env = envForShell;}));
}
