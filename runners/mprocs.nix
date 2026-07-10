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
    lib.mapAttrs (n: p:
      (p.runner_settings.mprocs or {})
      // {
        shell = runnerLib.resolveCommand n p;
      })
    processes;

  # The config is static — commands are store paths or literal shell
  # strings — so it needs no runtime substitution.
  cfg = pkgs.writeText "mprocs-${name}.yaml" (builtins.toJSON {
    inherit procs;
  });
in
  runnerLib.mkUpScript {
    inherit name processes env prerun;
    runtimeInputs = [pkgs.mprocs];
    # mprocs hardcodes its own diagnostic log to `mprocs.log` in the cwd
    # (flexi_logger FileSpec::default; no config/env override), so run it
    # from the logs dir to keep it out of the project root. Every process
    # sets its own cwd via $DNVR_ROOT, so mprocs' cwd doesn't affect them.
    exec = ''
      cd "$DNVR_STATE/logs"
      exec mprocs --config ${cfg} "$@"
    '';
  }
