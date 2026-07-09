{
  description = "dnvr — declarative dev environments for Nix flakes: services, processes, and scripts as modules, one devShell per environment";

  outputs = _: {
    # flake-parts module: import as `inputs.dnvr.flakeModule`.
    flakeModule = ./flake-module.nix;

    # Standalone entry point for non-flake-parts users:
    #   dnvr.lib.mkDnvr { inherit pkgs; }
    # returns { mkEnvs, mkScript, runners, presets, dnvrState }.
    lib.mkDnvr = import ./.;
  };
}
