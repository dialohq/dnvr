{
  pkgs,
  lib,
}:
pkgs.rustPlatform.buildRustPackage {
  pname = "dnvr-state";
  version = "0.1.0";
  src = ./runners/tmux-sidebar;
  cargoLock.lockFile = ./runners/tmux-sidebar/Cargo.lock;
  cargoBuildFlags = ["--no-default-features" "--bin" "dnvr-state"];
  cargoInstallFlags = ["--no-default-features" "--bin" "dnvr-state"];
  # The manifest-specialized runner build exercises the whole crate. Avoid
  # nixpkgs' default check hook rebuilding the default TUI feature graph here.
  doCheck = false;

  meta = {
    description = "Runtime state exchange for dnvr processes";
    mainProgram = "dnvr-state";
    platforms = lib.platforms.unix;
  };
}
