{
  name,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
in {
  options = {
    packages = mkOption {
      type = types.listOf types.package;
      default = [];
    };

    processes = mkOption {
      type = types.attrsOf types.anything;
      default = {};
    };

    env = mkOption {
      type = types.attrsOf types.anything;
      default = {};
    };

    scripts = mkOption {
      type = types.attrsOf types.anything;
      default = {};
    };
  };

  config._module.args.serviceName = name;
}
