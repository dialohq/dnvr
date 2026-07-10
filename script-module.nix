{
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkOption types;
in {
  options = {
    shell = mkOption {
      type = types.package;
      default = pkgs.bash;
      description = "Interpreter package, e.g. pkgs.bash, pkgs.nushell, pkgs.zsh.";
    };
    text = mkOption {
      type = types.lines;
      description = "Script body. Shebang is added automatically.";
    };
    runtimeInputs = mkOption {
      type = types.listOf types.package;
      default = [];
    };
    description = mkOption {
      type = types.str;
      default = "";
      description = "Shown in the entry banner.";
    };
  };
}
