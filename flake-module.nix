{
  lib,
  flake-parts-lib,
  ...
}: let
  inherit (lib) mkOption types;
in {
  options = {
    perSystem = flake-parts-lib.mkPerSystemOption ({
      config,
      pkgs,
      lib,
      ...
    }: let
      framework = import ./. {
        inherit pkgs lib;
        inherit (config.denver) extraRunners extraPresets;
      };
    in {
      options.denver = {
        extraRunners = mkOption {
          type = types.attrsOf (types.functionTo types.package);
          default = {};
          description = "Additional runners merged into the built-in `runners` registry.";
        };

        extraPresets = mkOption {
          type = types.attrsOf types.deferredModule;
          default = {};
          description = "Additional service presets merged into the built-in `presets` registry.";
        };

        exposeApps = mkOption {
          type = types.bool;
          default = true;
          description = "Whether to wire each devenv's up-script as `apps.<name>-up`.";
        };

        picker = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = "Add a picker devshell: `nix develop .#<picker.name>` pops a `gum choose` TUI and eval's the chosen devenv's env in place. Single nix develop invocation, no re-exec.";
          };
          name = mkOption {
            type = types.str;
            default = "default";
            description = "Devshell name. Default \"default\" so plain `nix develop` lands on the picker.";
          };
        };

        lib = mkOption {
          type = types.raw;
          readOnly = true;
          description = "Framework handle: `{ mkDevenvs, mkScript, runners, presets, denverState }`.";
        };
      };

      options.devenv = mkOption {
        type = types.attrsOf (types.submoduleWith {
          modules = [./devenv-module.nix];
          specialArgs = {
            inherit pkgs;
            inherit (framework) mkScript runners presets denverState;
          };
        });
        default = {};
        description = "Devenvs declared modularly; one devShell per name.";
      };

      config = {
        _module.args = {
          inherit (framework) mkScript runners presets denverState;
        };

        denver.lib = framework;

        devShells =
          (lib.mapAttrs (_: c: c.shell) config.devenv)
          // (lib.optionalAttrs config.denver.picker.enable {
            "${config.denver.picker.name}" = import ./picker.nix {
              inherit pkgs lib;
              names = lib.attrNames config.devenv;
            };
          });

        apps = lib.optionalAttrs config.denver.exposeApps (
          lib.mapAttrs' (devenvName: c: {
            name = "${devenvName}-up";
            value = {
              type = "app";
              program = "${c.up}/bin/${devenvName}-up";
            };
          })
          config.devenv
        );
      };
    });
  };
}
