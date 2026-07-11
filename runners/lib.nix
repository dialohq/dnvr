{
  pkgs,
  lib,
}: let
  inherit (import ../env-export.nix {inherit lib;}) exportLine refersToRoot;
in {
  # A process as handed over by shell-module: {command, runner_settings}
  # where command is a store script (derivation) or a shell string.
  resolveCommand = procName: p:
    if lib.isDerivation p.command
    then "${p.command}/bin/${p.command.meta.mainProgram or p.command.pname or procName}"
    else p.command;

  # Shared up-script scaffolding: DNVR_STATE guard, env exports (plus a
  # DNVR_ROOT guard when any value expands it), scoped runtime wipe, prerun.
  # `exec` is the runner-specific tail that execs the process manager. pid
  # files stay behind on exit — liveness is the flock each process holds,
  # so an unlocked leftover reads `exited` and the next launch wipes it.
  mkUpScript = {
    name,
    processes,
    env,
    prerun,
    runtimeInputs,
    exec,
  }: let
    rootGuard =
      lib.optionalString (lib.any refersToRoot (lib.attrValues env))
      '': "''${DNVR_ROOT:?DNVR_ROOT must be set (run via nix develop)}"'';

    envExports =
      lib.concatStringsSep "\n"
      (lib.mapAttrsToList exportLine env);

    # Wipe this group's stale published keys from a previous launch, per
    # process; consumers `dnvr-state wait` for fresh values, so a stale
    # `pg-test.port` from yesterday would otherwise silently mislead them.
    # $DNVR_STATE is shared by every shell in the repo — another group may
    # be running, and its state is not ours to clear. The pid file is
    # spared: its path identity carries the flock that `dnvr ps`, `get`,
    # and the duplicate-launch guard read — unlinking it would detach a
    # live instance's lock.
    runtimeWipe =
      lib.concatMapStrings
      (n: ''
        if [ -d "$DNVR_STATE/runtime/"${lib.escapeShellArg n} ]; then
          ${pkgs.findutils}/bin/find "$DNVR_STATE/runtime/"${lib.escapeShellArg n} \
            -mindepth 1 -maxdepth 1 ! -name pid -exec ${pkgs.coreutils}/bin/rm -rf {} +
        fi
      '')
      (lib.attrNames processes);

  in
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      # Env exports single-quote user values, which may legitimately contain
      # `$` (passwords, templates); SC2016 would flag every one of them.
      excludeShellChecks = ["SC2016"];
      text = ''
        : "''${DNVR_STATE:?DNVR_STATE must be set (run via nix develop)}"
        ${rootGuard}
        ${envExports}
        mkdir -p "$DNVR_STATE/logs" "$DNVR_STATE/runtime"
        ${runtimeWipe}
        ${prerun}
        ${exec}
      '';
    };
}
