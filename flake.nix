{
  description = "dnvr — declarative dev environments for Nix flakes: processes, presets, and scripts as modules, one devShell per dnvr.shells entry";

  outputs = _: {
    # flake-parts module: import as `inputs.dnvr.flakeModule`.
    flakeModule = ./flake-module.nix;

    lib = {
      # Per-system devShells from a module: everything except `pkgs`,
      # `presets`, and `extraRunners` is module config, so `imports` and
      # `dnvr.shells.<name>` sit at the top level exactly as they do under
      # flake-parts' perSystem:
      #   devShells.<system> = dnvr.lib.mkDevShells {
      #     pkgs = nixpkgs.legacyPackages.<system>;
      #     imports = [./shells.nix];
      #   };
      mkDevShells = args:
        ((import ./. {
            inherit (args) pkgs;
            presets = args.presets or {};
            extraRunners = args.extraRunners or {};
          }).mkShells [(builtins.removeAttrs args ["pkgs" "presets" "extraRunners"])])
        .devShells;

      # Full handle for everything else:
      #   dnvr.lib.mkDnvr { inherit pkgs; }
      # returns { mkShells, mkScript, runners, presets, dnvrState };
      # mkShells [modules] returns { devShells, ups, config }.
      mkDnvr = import ./.;
    };
  };
}
