{
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
in {
  options = {
    command = mkOption {
      type = types.either types.package types.str;
      description = ''
        What the runner executes. Derivations are wrapped so DNVR_RUNTIME_DIR
        points at the per-process runtime dir and dnvr-state is on PATH;
        strings pass through as-is.
      '';
    };

    packages = mkOption {
      type = types.listOf types.package;
      default = [];
      description = "Packages this process contributes to the devshell PATH.";
    };

    env = mkOption {
      type = types.attrsOf types.anything;
      default = {};
      description = "Env vars this process contributes to the devshell and the runner.";
    };

    scripts = mkOption {
      type = types.attrsOf types.anything;
      default = {};
      description = "Scripts this process contributes to the devshell PATH.";
    };

    runner_settings = mkOption {
      type = types.attrsOf (types.attrsOf types.anything);
      default = {};
      description = ''
        Per-runner passthrough config, keyed by runner name, e.g.
        `runner_settings."process-compose".depends_on`. Each runner reads
        only its own key.
      '';
    };
  };
}
