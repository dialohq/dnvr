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
    dnvr.shells = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submoduleWith {
        modules = [./shell-module.nix];
        specialArgs = {inherit pkgs mkScript runners presets dnvrState;};
      });
      default = {};
    };

    devShells = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      readOnly = true;
      description = "One devshell per `dnvr.shells.<name>`.";
    };

    ups = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      readOnly = true;
      description = "Per-shell up-scripts, as standalone derivations.";
    };
  };

  config.devShells = lib.mapAttrs (_: c: c.shell) config.dnvr.shells;
  config.ups = lib.mapAttrs (_: c: c.up) config.dnvr.shells;
}
