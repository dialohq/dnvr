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
        inherit (config.dnvr) extraRunners extraPresets;
      };
    in {
      options.dnvr = {
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
          description = "Whether to wire each env's up-script as `apps.<name>-up`.";
        };

        picker = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = "Add a picker devshell: `nix develop .#<picker.name>` pops a `gum choose` TUI and eval's the chosen env in place. Single nix develop invocation, no re-exec.";
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
          description = "Framework handle: `{ mkEnvs, mkScript, runners, presets, dnvrState }`.";
        };

        envs = mkOption {
          type = types.attrsOf (types.submoduleWith {
            modules = [./env-module.nix];
            specialArgs = {
              inherit pkgs;
              inherit (framework) mkScript runners presets dnvrState;
            };
          });
          default = {};
          description = "Envs declared modularly; one devShell per name.";
        };
      };

      config = {
        _module.args = {
          inherit (framework) mkScript runners presets dnvrState;
        };

        dnvr.lib = framework;

        devShells =
          (lib.mapAttrs (_: c: c.shell) config.dnvr.envs)
          // (lib.optionalAttrs config.dnvr.picker.enable {
            "${config.dnvr.picker.name}" = import ./picker.nix {
              inherit pkgs lib;
              names = lib.attrNames config.dnvr.envs;
            };
          });

        apps = lib.optionalAttrs config.dnvr.exposeApps (
          lib.mapAttrs' (envName: c: {
            name = "${envName}-up";
            value = {
              type = "app";
              program = "${c.up}/bin/${envName}-up";
            };
          })
          config.dnvr.envs
        );
      };
    });
  };
}
