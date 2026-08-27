{
  description = "dnvr — declarative dev environments for Nix flakes: processes, presets, and scripts as modules, one devShell per dnvr.shells entry";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = {nixpkgs, ...}: let
    resolve = args:
      builtins.removeAttrs args ["system"]
      // {
        pkgs =
          nixpkgs.legacyPackages.${
            args.system or (throw ''dnvr: pass `system` (e.g. "aarch64-darwin")'')
          };
      };
  in {
    # flake-parts module: import as `inputs.dnvr.flakeModule`.
    flakeModule = import ./flake-module.nix nixpkgs;

    lib = {
      # Per-system devShells from a module: everything except the
      # framework's own arguments (system → pkgs, lib, presets,
      # extraRunners, specialArgs — derived from default.nix's signature,
      # so the two can't drift) is module config, and `imports` /
      # `dnvr.shells.<name>` sit at the top level exactly as they do under
      # flake-parts' perSystem. `specialArgs` injects extra module args
      # (e.g. `inputs`) into every module level:
      #   devShells.<system> = dnvr.lib.mkDevShells {
      #     system = "<system>";
      #     specialArgs = {inherit inputs;};
      #     imports = [./shells.nix];
      #   };
      mkDevShells = args:
        if builtins.isFunction args
        then
          throw ''
            dnvr.lib.mkDevShells takes an attrset (system plus module config);
            pass function modules via `imports = [ ... ]`''
        else let
          fwArgs = builtins.functionArgs (import ./.);
          resolved = resolve args;
        in
          ((import ./. (builtins.intersectAttrs fwArgs resolved)).mkShells
            [(builtins.removeAttrs resolved (builtins.attrNames fwArgs))])
          .devShells;

      # Full handle for everything else:
      #   dnvr.lib.mkDnvr { system = "<system>"; }
      # returns { mkShells, mkScript, runners, presets, dnvrState };
      # mkShells [modules] returns { devShells, ups, config }.
      mkDnvr = args: import ./. (resolve args);
    };
  };
}
