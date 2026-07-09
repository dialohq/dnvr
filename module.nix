{
  config,
  lib,
  pkgs,
  mkScript,
  runners,
  presets,
  dnvrState,
  ...
}: {
  options = {
    dnvr.envs = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submoduleWith {
        modules = [./env-module.nix];
        specialArgs = {inherit pkgs mkScript runners presets dnvrState;};
      });
      default = {};
    };

    devShells = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      readOnly = true;
      description = "One devshell per `dnvr.envs.<name>`.";
    };

    ups = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      readOnly = true;
      description = "Per-env up-scripts, also available standalone (handy for `nix run`).";
    };
  };

  config.devShells = lib.mapAttrs (_: c: c.shell) config.dnvr.envs;
  config.ups = lib.mapAttrs (_: c: c.up) config.dnvr.envs;
}
