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
  # DNVR_ROOT guard when any value expands it), prerun, then exec the
  # process manager. The up script is just the viewer — it owns no state:
  # liveness is the flock each process holds on its pid file, and every
  # process wipes its own keys as it claims it.
  mkUpScript = {
    name,
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
        ${prerun}
        ${exec}
      '';
    };
}
