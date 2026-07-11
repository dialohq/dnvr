{
  description = "dnvr — declarative dev environments for Nix flakes: processes, presets, and scripts as modules, one devShell per dnvr.shells entry";

  outputs = _: {
    # flake-parts module: import as `inputs.dnvr.flakeModule`.
    flakeModule = ./flake-module.nix;

    lib = {
      # Per-system devShells from a module: everything except the
      # framework's own arguments (pkgs, lib, presets, extraRunners,
      # specialArgs — derived from default.nix's signature, so the two
      # can't drift) is module config, and `imports` / `dnvr.shells.<name>`
      # sit at the top level exactly as they do under flake-parts'
      # perSystem. `specialArgs` injects extra module args (e.g. `inputs`)
      # into every module level:
      #   devShells.<system> = dnvr.lib.mkDevShells {
      #     pkgs = nixpkgs.legacyPackages.<system>;
      #     specialArgs = {inherit inputs;};
      #     imports = [./shells.nix];
      #   };
      mkDevShells = args:
        if builtins.isFunction args
        then
          throw ''
            dnvr.lib.mkDevShells takes an attrset (pkgs plus module config);
            pass function modules via `imports = [ ... ]`''
        else let
          fwArgs = builtins.functionArgs (import ./.);
        in
          ((import ./. (builtins.intersectAttrs fwArgs args)).mkShells
            [(builtins.removeAttrs args (builtins.attrNames fwArgs))])
          .devShells;

      # Full handle for everything else:
      #   dnvr.lib.mkDnvr { inherit pkgs; }
      # returns { mkShells, mkScript, runners, presets, dnvrState };
      # mkShells [modules] returns { devShells, ups, config }.
      mkDnvr = import ./.;
    };
  };
}
