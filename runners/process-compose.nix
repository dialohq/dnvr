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

  envExports =
    lib.concatStringsSep "\n"
    (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg (toString v)}") env);
in
  pkgs.writeShellApplication {
    inherit name;
    runtimeInputs = [pkgs.process-compose];
    text = ''
      ${envExports}
      : "''${DNVR_STATE:?DNVR_STATE must be set (run via nix develop)}"
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
