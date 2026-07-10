{
  pkgs,
  lib,
}: {
  name,
  processes,
  env ? {},
  prerun ? "",
}: let
  resolveCommand = procName: p: let
    cmd = p.command or p;
  in
    if lib.isDerivation cmd
    then "${cmd}/bin/${cmd.meta.mainProgram or cmd.pname or procName}"
    else cmd;

  procs =
    lib.mapAttrs (
      n: p:
        (p.runner_settings."process-compose" or {})
        // {
          command = resolveCommand n p;
        }
    )
    processes;

  cfg = pkgs.writeText "process-compose-${name}.yaml" (builtins.toJSON {
    version = "0.5";
    log_location = "@PC_LOG@";
    processes = procs;
  });

  inherit (import ../env-export.nix {inherit lib;}) exportLine refersToRoot;

  # `$DNVR_ROOT` in env values expands at export time (see env-export.nix);
  # only then does this script need DNVR_ROOT itself.
  rootGuard =
    lib.optionalString (lib.any refersToRoot (lib.attrValues env))
    '': "''${DNVR_ROOT:?DNVR_ROOT must be set (run via nix develop)}"'';

  envExports =
    lib.concatStringsSep "\n"
    (lib.mapAttrsToList exportLine env);
in
  pkgs.writeShellApplication {
    inherit name;
    # Env exports single-quote user values, which may legitimately contain
    # `$` (passwords, templates); SC2016 would flag every one of them.
    excludeShellChecks = ["SC2016"];
    runtimeInputs = [pkgs.process-compose];
    text = ''
      : "''${DNVR_STATE:?DNVR_STATE must be set (run via nix develop)}"
      ${rootGuard}
      ${envExports}
      mkdir -p "$DNVR_STATE/logs"
      # Wipe stale runtime/; see comment in runners/mprocs.nix.
      ${pkgs.coreutils}/bin/rm -rf "$DNVR_STATE/runtime"
      mkdir -p "$DNVR_STATE/runtime"
      __cfg=$(${pkgs.coreutils}/bin/mktemp -t process-compose-XXXXXX.yaml)
      trap '${pkgs.coreutils}/bin/rm -f "$__cfg"' EXIT
      ${pkgs.gnused}/bin/sed "s|@PC_LOG@|$DNVR_STATE/logs/process-compose.log|g" ${cfg} > "$__cfg"
      ${prerun}
      exec process-compose -f "$__cfg" "$@"
    '';
  }
