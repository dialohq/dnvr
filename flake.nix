{
  description = "denver — declarative dev environments for Nix flakes: services, processes, and scripts as modules, one devShell per environment";

  outputs = _: {
    # flake-parts module: import as `inputs.denver.flakeModule`.
    flakeModule = ./flake-module.nix;

    # Standalone entry point for non-flake-parts users:
    #   denver.lib.mkDenver { inherit pkgs; }
    # returns { mkDevenvs, mkScript, runners, presets, devenvState }.
    lib.mkDenver = import ./.;
  };
}
