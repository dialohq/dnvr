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
        inherit (config.dnvr) extraRunners presets;
      };
    in {
      options.dnvr = {
        extraRunners = mkOption {
          type = types.attrsOf (types.functionTo types.package);
          default = {};
          description = "Additional runners merged into the built-in `runners` registry.";
        };

        presets = mkOption {
          type = types.attrsOf types.deferredModule;
          default = {};
          description = "Custom process presets merged over the built-in `presets` registry.";
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
            description = "Add a picker devshell: a `gum choose` TUI over the declared shells that writes `.envrc` for the chosen one and hands off to direnv.";
          };
          shellName = mkOption {
            type = types.str;
            default = "default";
            description = "devShell attr the picker is exposed as (`nix develop .#<shellName>`). Default \"default\" so plain `nix develop` lands on the picker; must not collide with a `dnvr.shells` name.";
          };
        };

        lib = mkOption {
          type = types.raw;
          readOnly = true;
          description = "Framework handle: `{ mkShells, mkScript, runners, presets, dnvrState }`.";
        };

        shells = mkOption {
          type = types.attrsOf (types.submoduleWith {
            modules = [./shell-module.nix];
            specialArgs = {
              inherit pkgs;
              inherit (framework) mkScript runners presets dnvrState;
            };
          });
          default = {};
          description = "Shells declared modularly; one devShell per name.";
        };
      };

      config = {
        _module.args = {
          inherit (framework) mkScript runners presets dnvrState;
        };

        dnvr.lib = framework;

        devShells =
          (lib.mapAttrs (_: c: c.shell) config.dnvr.shells)
          // (lib.optionalAttrs config.dnvr.picker.enable {
            "${config.dnvr.picker.shellName}" =
              if config.dnvr.shells ? ${config.dnvr.picker.shellName}
              then
                throw "dnvr: picker.shellName \"${config.dnvr.picker.shellName}\" collides with dnvr.shells.${config.dnvr.picker.shellName} — rename one of them"
              else
                import ./picker.nix {
                  inherit pkgs lib;
                  names = lib.attrNames config.dnvr.shells;
                };
          });

        apps = lib.optionalAttrs config.dnvr.exposeApps (
          lib.mapAttrs' (shellName: c: {
            name = "${shellName}-up";
            value = {
              type = "app";
              program = "${c.up}/bin/${shellName}-up";
            };
          })
          config.dnvr.shells
        );
      };
    });
  };
}
