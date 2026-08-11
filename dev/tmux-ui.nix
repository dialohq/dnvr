# Run from the repository root:
#
#   nix run --impure --expr 'import ./dev/tmux-ui.nix'
#
# Stop the session with Q before rerunning after a source edit; otherwise the
# runner correctly reattaches to the existing session and its old store paths.
let
  pkgs = (builtins.getFlake "nixpkgs").legacyPackages.${builtins.currentSystem};
  runner = import ../runners/tmux.nix {
    inherit pkgs;
    lib = pkgs.lib;
  };
  process = command: {
    inherit command;
    runner_settings = {};
  };
in let
  ui = runner {
    name = "tmux-ui";
    processes = {
      clock = process ''
        while true; do
          printf '\rclock  %s' "$(${pkgs.coreutils}/bin/date +%T)"
          ${pkgs.coreutils}/bin/sleep 1
        done
      '';

      dies = process ''
        printf 'This pane exits with status 42 after five seconds.\n'
        ${pkgs.coreutils}/bin/sleep 5
        exit 42
      '';

      input = process ''
        printf 'Type here; every line is echoed back.\n> '
        while IFS= read -r line; do
          printf 'you typed: %s\n> ' "$line"
        done
      '';

      stream = process ''
        n=0
        while true; do
          colour=$((31 + n % 6))
          printf '\033[%smstream line %-6s\033[0m\n' "$colour" "$n"
          n=$((n + 1))
          ${pkgs.coreutils}/bin/sleep 0.2
        done
      '';
    };
  };
in
  pkgs.writeShellApplication {
    name = "dnvr-tmux-ui-dev";
    text = ''
      export DNVR_STATE="$PWD/.dnvr"
      exec ${ui}/bin/tmux-ui
    '';
  }
