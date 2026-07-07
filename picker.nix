{
  pkgs,
  lib,
  names,
}: let
  joined = lib.concatStringsSep " " (map lib.escapeShellArg names);
in
  pkgs.mkShell {
    name = "devenv-picker";
    packages = [pkgs.gum];
    shellHook = ''
      # Pick a devenv, write `.envrc`, `direnv allow`, then `exit 0` so nix
      # develop's bash quits and the caller's shell takes over. The caller's
      # direnv prompt hook fires on the next prompt and loads the chosen env.
      choice=$(${pkgs.gum}/bin/gum choose --header "pick a devenv:" ${joined}) || {
        echo "cancelled — run 'nix develop .#<name>' to skip the picker" >&2
        exit 0
      }
      [ -z "''${choice:-}" ] && exit 0
      __target_root=$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || pwd)
      printf 'use flake .#%s\n' "$choice" > "$__target_root/.envrc"
      (cd "$__target_root" && ${pkgs.direnv}/bin/direnv allow .) || true
      echo "wrote $__target_root/.envrc → 'cd' here auto-loads $choice via direnv"
      exit 0
    '';
  }
