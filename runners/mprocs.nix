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
    lib.mapAttrs (n: p:
      (p.runner_settings.mprocs or {})
      // {
        shell = resolveCommand n p;
      })
    processes;

  # The proc shells are all static nix-store paths, so the config needs no
  # runtime substitution.
  cfg = pkgs.writeText "mprocs-${name}.yaml" (builtins.toJSON {
    procs = procs;
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

  # Wipe only this group's stale runtime state from a previous launch;
  # consumers `dnvr-state wait` for fresh values, so a stale `pg-test.port`
  # from yesterday would otherwise silently mislead them. $DNVR_STATE is
  # shared by every shell in the repo — another group may be running, and
  # its published state is not ours to clear.
  runtimeWipe =
    lib.concatMapStrings
    (n: ''
      ${pkgs.coreutils}/bin/rm -rf "$DNVR_STATE/runtime/"${lib.escapeShellArg n}
    '')
    (lib.attrNames processes);
in
  pkgs.writeShellApplication {
    inherit name;
    # Env exports single-quote user values, which may legitimately contain
    # `$` (passwords, templates); SC2016 would flag every one of them.
    excludeShellChecks = ["SC2016"];
    runtimeInputs = [pkgs.mprocs];
    text = ''
      : "''${DNVR_STATE:?DNVR_STATE must be set (run via nix develop)}"
      ${rootGuard}
      ${envExports}
      mkdir -p "$DNVR_STATE/logs" "$DNVR_STATE/runtime"
      ${runtimeWipe}
      ${prerun}
      # mprocs hardcodes its own diagnostic log to `mprocs.log` in the cwd
      # (flexi_logger FileSpec::default; no config/env override), so run it
      # from the logs dir to keep it out of the project root. Every process
      # sets its own cwd via $DNVR_ROOT, so mprocs' cwd doesn't affect them.
      cd "$DNVR_STATE/logs"
      exec mprocs --config ${cfg} "$@"
    '';
  }
