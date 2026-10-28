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

  # Bash helpers over the pid-lock liveness contract, for runner verbs.
  # They read `$DNVR_STATE/runtime/<proc>/pid` and never create it.
  procHelpers = ''
    __dnvr_running() {
      local f="$DNVR_STATE/runtime/$1/pid"
      [ -f "$f" ] && ! ${pkgs.flock}/bin/flock -ns "$f" true 2>/dev/null
    }
    __dnvr_wait_stopped() {
      local f="$DNVR_STATE/runtime/$1/pid"
      [ -f "$f" ] || return 0
      ${pkgs.flock}/bin/flock -s -w "$2" "$f" true 2>/dev/null
    }
  '';

  # Shared up-script scaffolding: DNVR_STATE guard, env exports (plus a
  # DNVR_ROOT guard when any value expands it), optional reattachment before
  # prerun, then exec the process manager. Process liveness is still the flock
  # each process holds on its pid file, and every process wipes its own keys as
  # it claims it.
  mkUpScript = {
    name,
    env,
    prerun,
    runtimeInputs,
    reattach ? "",
    exec,
    passthru ? {},
  }: let
    rootGuard =
      lib.optionalString (lib.any refersToRoot (lib.attrValues env))
      '': "''${DNVR_ROOT:?DNVR_ROOT must be set (run via nix develop)}"'';

    envExports =
      lib.concatStringsSep "\n"
      (lib.mapAttrsToList exportLine env);
  in
    pkgs.writeShellApplication {
      inherit name runtimeInputs passthru;
      # Env exports single-quote user values, which may legitimately contain
      # `$` (passwords, templates); SC2016 would flag every one of them.
      excludeShellChecks = ["SC2016"];
      text = ''
        : "''${DNVR_STATE:?DNVR_STATE must be set (run via nix develop)}"
        ${rootGuard}
        ${envExports}
        mkdir -p "$DNVR_STATE/logs" "$DNVR_STATE/runtime"
        ${reattach}
        ${prerun}
        ${exec}
      '';
    };
}
