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
  # `exec` is the runner-specific tail that starts the process manager.
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
