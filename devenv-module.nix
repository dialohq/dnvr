{
  name,
  config,
  lib,
  pkgs,
  mkScript,
  runners,
  presets,
  devenvState,
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
  # runtime/<procname> directory and devenv-state is on PATH. Lets the inner
  # command just say `devenv-state set port 5432` without knowing its own name.
  wrapProcess = procName: p: let
    original = p.command or null;
    wrapped =
      if lib.isDerivation original
      then
        pkgs.writeShellApplication {
          name = "${procName}-scoped";
          runtimeInputs = [devenvState];
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

  bannerLines = let
    serviceNames = lib.attrNames config.services;
    serviceLine =
      lib.optional (serviceNames != [])
      "services: ${lib.concatStringsSep ", " serviceNames}";

    cmds =
      [
        {
          name = "${name}-up";
          desc = "launch process group";
        }
      ]
      ++ lib.mapAttrsToList (n: s: {
        name = n;
        desc = s.description;
      })
      allScripts;

    nameWidth = lib.foldl' lib.max 0 (map (c: lib.stringLength c.name) cmds);
    fmtCmd = c: "${c.name}${padTo (nameWidth + 2) c.name}${c.desc}";

    titleSuffix = lib.optionalString (config.description != "") " — ${config.description}";
  in
    ["devenv: ${name}${titleSuffix}"]
    ++ serviceLine
    ++ ["commands:"]
    ++ (map (c: "  ${fmtCmd c}") cmds);

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
      packages = config.packages ++ servicePackages ++ scriptPkgs ++ [upScript devenvState];
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
