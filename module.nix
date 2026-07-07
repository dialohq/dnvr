{
  config,
  lib,
  pkgs,
  mkScript,
  runners,
  presets,
  devenvState,
  ...
}: {
  options = {
    devenv = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submoduleWith {
        modules = [./devenv-module.nix];
        specialArgs = {inherit pkgs mkScript runners presets devenvState;};
      });
      default = {};
    };

    devShells = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      readOnly = true;
      description = "One devshell per `devenv.<name>`.";
    };

    ups = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      readOnly = true;
      description = "Per-devenv up-scripts, also available standalone (handy for `nix run`).";
    };
  };

  config.devShells = lib.mapAttrs (_: c: c.shell) config.devenv;
  config.ups = lib.mapAttrs (_: c: c.up) config.devenv;
}
