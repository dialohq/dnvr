{
  pkgs,
  lib ? pkgs.lib,
  extraRunners ? {},
  presets ? {},
}: let
  mkScript = import ./script.nix {inherit pkgs lib;};

  dnvrState = import ./dnvr-state.nix {inherit pkgs lib;};

  builtinRunners = {
    mprocs = import ./runners/mprocs.nix {inherit pkgs lib;};
    process-compose = import ./runners/process-compose.nix {inherit pkgs lib;};
  };

  runners = builtinRunners // extraRunners;

  allPresets = (import ./presets) // presets;

  mkShells = userModules: let
    result = lib.evalModules {
      modules = [./module.nix] ++ userModules;
      specialArgs = {
        inherit pkgs mkScript runners dnvrState;
        presets = allPresets;
      };
    };
  in {
    inherit (result.config) devShells ups;
    config = result.config;
  };
in {
  inherit mkShells mkScript runners dnvrState;
  presets = allPresets;
}
