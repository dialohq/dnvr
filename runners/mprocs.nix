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
    lib.mapAttrs (n: p: {
      shell = resolveCommand n p;
    })
    processes;

  # The proc shells are all static nix-store paths, so the config needs no
  # runtime substitution.
  cfg = pkgs.writeText "mprocs-${name}.yaml" (builtins.toJSON {
    procs = procs;
  });

  envExports =
    lib.concatStringsSep "\n"
    (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg (toString v)}") env);
in
  pkgs.writeShellApplication {
    inherit name;
    runtimeInputs = [pkgs.mprocs];
    text = ''
      ${envExports}
      : "''${DNVR_STATE:?DNVR_STATE must be set (run via nix develop)}"
      mkdir -p "$DNVR_STATE/logs" "$DNVR_STATE/runtime"
      # Wipe stale runtime/ from a previous launch; consumers `dnvr-state
      # wait` for fresh values so a stale `pg-test.port` from yesterday would
      # otherwise silently mislead them.
      ${pkgs.coreutils}/bin/rm -rf "$DNVR_STATE/runtime"
      mkdir -p "$DNVR_STATE/runtime"
      ${prerun}
      # mprocs hardcodes its own diagnostic log to `mprocs.log` in the cwd
      # (flexi_logger FileSpec::default; no config/env override), so run it
      # from the logs dir to keep it out of the project root. Every process
      # sets its own cwd via $DNVR_ROOT, so mprocs' cwd doesn't affect them.
      cd "$DNVR_STATE/logs"
      exec mprocs --config ${cfg} "$@"
    '';
  }
