# Run from the repository root:
#
#   nix run --impure --expr 'import ./dev/tmux-ui.nix'
#   nix run --impure --expr 'import ./dev/tmux-ui.nix' '' -- up --runner rex
#   nix run --impure --expr 'import ./dev/tmux-ui.nix' '' -- logs stream
#
# With no arguments the wrapper runs `dnvr up` (rex inside Rex, tmux
# otherwise); arguments are passed to the real shell-scoped dnvr CLI. Under
# rex, clock and stream share one tab. Sidebar changes hot-upgrade on the next run.
# Stop the session with Q only when changing fixture process commands, whose
# panes retain their original command while the session is alive.
let
  # The flake's locked nixpkgs, not the registry's: tmux versions differ.
  locked = (builtins.fromJSON (builtins.readFile ../flake.lock)).nodes.nixpkgs.locked;
  nixpkgs = builtins.getFlake "github:${locked.owner}/${locked.repo}/${locked.rev}";
  pkgs = nixpkgs.legacyPackages.${builtins.currentSystem};
  framework = import ../. {inherit pkgs;};
  result = framework.mkShells [
    {
      dnvr.shells.tmux-ui.processes = {
        clock.runner_settings.rex.tab = "ticks";
        clock.command = ''
          while true; do
            printf '\rclock  %s' "$(${pkgs.coreutils}/bin/date +%T)"
            ${pkgs.coreutils}/bin/sleep 1
          done
        '';

        dies.command = ''
          printf 'This pane exits with status 42 after five seconds.\n'
          ${pkgs.coreutils}/bin/sleep 5
          exit 42
        '';

        input.command = ''
          printf 'Type here; every line is echoed back.\n> '
          while IFS= read -r line; do
            printf 'you typed: %s\n> ' "$line"
          done
        '';

        stream.runner_settings.rex.tab = "ticks";
        stream.command = ''
          n=0
          while true; do
            colour=$((31 + n % 6))
            printf '\033[%smstream line %-6s\033[0m\n' "$colour" "$n"
            n=$((n + 1))
            ${pkgs.coreutils}/bin/sleep 0.2
          done
        '';
      };
    }
  ];
  cli = result.config.dnvr.shells.tmux-ui.cli;
in
  pkgs.writeShellApplication {
    name = "dnvr-tmux-ui-dev";
    runtimeInputs = [cli];
    text = ''
      export DNVR_ROOT="$PWD"
      export DNVR_STATE="$PWD/.dnvr"
      if (( $# == 0 )); then
        set -- up
      fi
      exec dnvr "$@"
    '';
  }
