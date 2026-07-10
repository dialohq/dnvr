{
  pkgs,
  lib,
  names,
}: let
  joined = lib.concatStringsSep " " (map lib.escapeShellArg names);

  # First line of every picker-written .envrc. Only files carrying it are
  # ever overwritten — anything else is the user's, hands off.
  sentinel = "# written by dnvr picker";
in
  pkgs.mkShell {
    name = "dnvr-picker";
    packages = [pkgs.gum];
    shellHook = ''
      # Pick a shell, write `.envrc`, `direnv allow`, then `exit 0` so nix
      # develop's bash quits and the caller's shell takes over. The caller's
      # direnv prompt hook fires on the next prompt and loads the chosen env.
      choice=$(${pkgs.gum}/bin/gum choose --header "pick a shell:" ${joined}) || {
        echo "cancelled — run 'nix develop .#<name>' to skip the picker" >&2
        exit 0
      }
      [ -z "''${choice:-}" ] && exit 0
      __target_root=$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null || pwd)
      if [ -f "$__target_root/.envrc" ]; then
        IFS= read -r __dnvr_first < "$__target_root/.envrc" || true
        if [ "$__dnvr_first" != ${lib.escapeShellArg sentinel} ]; then
          echo "$__target_root/.envrc exists and wasn't written by the dnvr picker — add 'use flake .#$choice' to it yourself" >&2
          exit 0
        fi
      fi
      printf '%s\nuse flake .#%s\n' ${lib.escapeShellArg sentinel} "$choice" > "$__target_root/.envrc"
      (cd "$__target_root" && ${pkgs.direnv}/bin/direnv allow .) || true
      echo "wrote $__target_root/.envrc → 'cd' here auto-loads $choice via direnv"
      exit 0
    '';
  }
