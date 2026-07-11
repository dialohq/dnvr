{
  pkgs,
  lib ? pkgs.lib,
  extraRunners ? {},
  presets ? {},
  specialArgs ? {},
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
    # User specialArgs reach every level: the top-level modules and — via
    # dnvrSpecialArgs, threaded through the submoduleWith calls — shell,
    # process, and script submodules.
    allArgs =
      {
        inherit pkgs mkScript runners dnvrState;
        presets = allPresets;
      }
      // specialArgs;
    result = lib.evalModules {
      modules = [./module.nix] ++ userModules;
      specialArgs = allArgs // {dnvrSpecialArgs = allArgs;};
    };
  in {
    inherit (result.config) devShells ups;
    config = result.config;
  };
in {
  inherit mkShells mkScript runners dnvrState;
  presets = allPresets;
}
