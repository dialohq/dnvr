{
  pkgs,
  lib,
}: {
  name,
  processes,
  env ? {},
  prerun ? "",
}: let
  runnerLib = import ./lib.nix {inherit pkgs lib;};

  procs =
    lib.mapAttrs (
      n: p:
        (p.runner_settings."process-compose" or {})
        // {
          # process-compose interpolates $VAR/$$ in commands (compose
          # semantics) before any shell sees them; escape so string
          # commands run verbatim, like they do under mprocs. Store-path
          # commands carry no `$`.
          command = lib.replaceStrings ["$"] ["$$"] (runnerLib.resolveCommand n p);
        }
    )
    processes;

  cfg = pkgs.writeText "process-compose-${name}.yaml" (builtins.toJSON {
    version = "0.5";
    log_location = "@PC_LOG@";
    processes = procs;
  });
in
  runnerLib.mkUpScript {
    inherit name processes env prerun;
    runtimeInputs = [pkgs.process-compose];
    # The log path is runtime-dependent ($DNVR_STATE), so it is patched into
    # a temp copy of the store config at launch.
    run = ''
      __cfg=$(${pkgs.coreutils}/bin/mktemp -t process-compose-XXXXXX.yaml)
      trap '${pkgs.coreutils}/bin/rm -f "$__cfg"' EXIT
      ${pkgs.gnused}/bin/sed "s|@PC_LOG@|$DNVR_STATE/logs/process-compose.log|g" ${cfg} > "$__cfg"
      process-compose -f "$__cfg" "$@"
    '';
  }
