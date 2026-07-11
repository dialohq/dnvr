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

  # Names the module system or the framework itself provides as module args.
  # Letting user specialArgs shadow them breaks things silently — a user
  # `name` collapses every shell/process to one identity, a user `pkgs`
  # swaps nixpkgs out from under the prebuilt dnvr-state/runners — so
  # reject them loudly instead of merging.
  reservedArgNames = [
    "name"
    "lib"
    "config"
    "options"
    "specialArgs"
    "modulesPath"
    "pkgs"
    "mkScript"
    "runners"
    "presets"
    "dnvrState"
    "dnvrSpecialArgs"
  ];

  clashes =
    builtins.filter (n: builtins.elem n reservedArgNames)
    (builtins.attrNames specialArgs);

  # The one composed set every dnvr module level receives — top-level
  # modules and each shell/process/script submodule alike: the framework
  # args plus the user's specialArgs. Lazy fixpoint: the set contains
  # itself as `dnvrSpecialArgs`, so every submoduleWith site is the same
  # `specialArgs = dnvrSpecialArgs` pass-through with no re-wrapping.
  # (It is infinitely self-nested — fine for module-arg selection, but
  # never deepSeq/toJSON it.)
  dnvrSpecialArgs =
    if clashes != []
    then
      throw ''
        dnvr: specialArgs may not define reserved module args: ${lib.concatStringsSep ", " clashes}
        (registries are extended via the presets/extraRunners arguments)''
    else
      {
        inherit pkgs mkScript runners dnvrState;
        presets = allPresets;
      }
      // specialArgs
      // {inherit dnvrSpecialArgs;};

  mkShells = userModules: let
    result = lib.evalModules {
      modules = [./module.nix] ++ userModules;
      specialArgs = dnvrSpecialArgs;
    };
  in {
    inherit (result.config) devShells ups;
    config = result.config;
  };
in {
  inherit mkShells mkScript runners dnvrState dnvrSpecialArgs;
  presets = allPresets;
}
