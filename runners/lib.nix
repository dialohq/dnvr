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

    # Stamp each process's state dir before anything spawns. `dnvr-state
    # wait` accepts a key only if it is at least as new as this stamp, so
    # yesterday's values can never satisfy today's waits — including
    # completion sentinels, which stay readable after their producer
    # exits precisely because their mtime beats the stamp. Nothing is
    # deleted here: each process wipes its own keys when it claims its
    # pid file, and $DNVR_STATE is shared by every shell in the repo —
    # another group may be running, and its state is not ours to touch.
    launchStamp =
      lib.concatMapStrings
      (n: ''
        ${pkgs.coreutils}/bin/mkdir -p "$DNVR_STATE/runtime/"${lib.escapeShellArg n}
        ${pkgs.coreutils}/bin/touch "$DNVR_STATE/runtime/"${lib.escapeShellArg n}/.launch
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
        ${launchStamp}
        ${prerun}
        ${exec}
      '';
    };
}
