{
  pkgs,
  lib ? pkgs.lib,
  extraRunners ? {},
  extraPresets ? {},
}: let
  mkScript = import ./script.nix {inherit pkgs lib;};

  denverState = import ./denver-state.nix {inherit pkgs lib;};

  builtinRunners = {
    mprocs = import ./runners/mprocs.nix {inherit pkgs lib;};
    process-compose = import ./runners/process-compose.nix {inherit pkgs lib;};
  };

  runners = builtinRunners // extraRunners;

  presets = (import ./presets) // extraPresets;

  mkDevenvs = userModules: let
    result = lib.evalModules {
      modules = [./module.nix] ++ userModules;
      specialArgs = {
        inherit pkgs mkScript runners presets denverState;
      };
    };
  in {
    inherit (result.config) devShells ups;
    config = result.config;
  };
in {
  inherit mkDevenvs mkScript runners presets denverState;
}
