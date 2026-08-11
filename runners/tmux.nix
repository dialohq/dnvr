{
  pkgs,
  lib,
}: {
  name,
  processes,
  env ? {},
  prerun ? "",
}: let
  runnerLib = import ./lib.nix {inherit pkgs lib;};
  processNames = lib.attrNames processes;

  sidebar = pkgs.rustPlatform.buildRustPackage {
    pname = "dnvr-tmux-sidebar";
    version = "0.1.0";
    src = ./tmux-sidebar;
    cargoLock.lockFile = ./tmux-sidebar/Cargo.lock;
  };

  launchProcesses = lib.concatStringsSep "\n" (lib.imap0 (index: procName: let
      process = processes.${procName};
      command = runnerLib.resolveCommand procName process;
      logName = lib.replaceStrings ["/"] ["_"] procName;
    in ''
      __pane=$(tmux -S "$__socket" new-window -d -P -F '#{pane_id}' \
        -t "=$__session:" -n ${lib.escapeShellArg procName} \
        ${lib.escapeShellArg command})
      tmux -S "$__socket" set-option -p -t "$__pane" @dnvr_role process
      tmux -S "$__socket" set-option -p -t "$__pane" @dnvr_name \
        ${lib.escapeShellArg procName}
      tmux -S "$__socket" set-option -p -t "$__pane" @dnvr_index \
        ${toString index}
      __log="$__proc_logs/${logName}.log"
      printf -v __pipe '%q >> %q' ${pkgs.coreutils}/bin/cat "$__log"
      tmux -S "$__socket" pipe-pane -o -t "$__pane" "$__pipe"
    '') processNames);

  configureSession = ''
    tmux -S "$__socket" set-option -g status off
    tmux -S "$__socket" set-option -g remain-on-exit on
    tmux -S "$__socket" set-option -g mouse on
    tmux -S "$__socket" set-option -g pane-border-status top
    tmux -S "$__socket" set-option -g pane-border-indicators off
    tmux -S "$__socket" set-option -g pane-border-format \
      '#{?pane_active,#[fg=cyan],#[fg=colour244]}#{?#{==:#{@dnvr_role},sidebar},Processes,#{@dnvr_name} #{?pane_dead,DOWN,UP}}#[default] '
    tmux -S "$__socket" set-option -g pane-border-style fg=colour238
    tmux -S "$__socket" set-option -g pane-active-border-style fg=colour238
    tmux -S "$__socket" set-window-option -g window-size latest
    tmux -S "$__socket" set-option -g default-shell ${pkgs.bash}/bin/bash
    tmux -S "$__socket" set-option -s escape-time 0
    tmux -S "$__socket" set-option -g prefix None
    tmux -S "$__socket" set-option -g prefix2 None
    tmux -S "$__socket" bind-key -n C-g detach-client
    tmux -S "$__socket" bind-key -n C-a \
      "select-pane -t '$__sidebar' ; run-shell '${pkgs.coreutils}/bin/kill -USR1 $__sidebar_pid'"
    tmux -S "$__socket" set-hook -g pane-died \
      "run-shell '${pkgs.coreutils}/bin/kill -USR1 $__sidebar_pid'"
    tmux -S "$__socket" set-hook -g client-attached \
      "resize-pane -t '$__sidebar' -x 30 ; run-shell '${pkgs.coreutils}/bin/kill -USR1 $__sidebar_pid'"
    tmux -S "$__socket" set-hook -g client-resized \
      "resize-pane -t '$__sidebar' -x 30 ; run-shell '${pkgs.coreutils}/bin/kill -USR1 $__sidebar_pid'"
  '';
in
  runnerLib.mkUpScript {
    inherit name env prerun;
    runtimeInputs = [pkgs.tmux];

    # The socket is scoped by DNVR_STATE, so a fixed session name is enough and
    # avoids tmux's punctuation restrictions on session names.
    reattach = ''
      __socket="$DNVR_STATE/runtime/tmux-${name}.sock"
      __session=dnvr
      if tmux -S "$__socket" has-session -t "=$__session" 2>/dev/null; then
        __sidebar=$(tmux -S "$__socket" list-panes -s -t "=$__session" \
          -F '#{@dnvr_role}\t#{pane_id}' \
          | ${pkgs.gawk}/bin/awk -F '\t' '$1 == "sidebar" { print $2; exit }')
        __sidebar_command=${sidebar}/bin/dnvr-tmux-sidebar
        __running_sidebar_command=$(tmux -S "$__socket" display-message -p \
          -t "$__sidebar" '#{@dnvr_sidebar_command}')
        if [[ "$__running_sidebar_command" != "$__sidebar_command" ]]; then
          # The process panes belong to the persistent session, but the
          # sidebar is disposable UI. Upgrade it in place when a rebuilt
          # runner points at a new Nix store path.
          tmux -S "$__socket" set-option -p -t "$__sidebar" @dnvr_ready 0
          tmux -S "$__socket" respawn-pane -k -t "$__sidebar" \
            "$__sidebar_command"
          __sidebar_ready=false
          for ((i = 0; i < 100; i++)); do
            if [[ "$(tmux -S "$__socket" display-message -p \
              -t "$__sidebar" '#{@dnvr_ready}')" == 1 ]]; then
              __sidebar_ready=true
              break
            fi
            ${pkgs.coreutils}/bin/sleep 0.01
          done
          if [[ "$__sidebar_ready" != true ]]; then
            echo "dnvr: updated tmux sidebar did not become ready" >&2
            exit 1
          fi
          tmux -S "$__socket" set-option -p -t "$__sidebar" \
            @dnvr_sidebar_command "$__sidebar_command"
        fi
        __sidebar_pid=$(tmux -S "$__socket" display-message -p \
          -t "$__sidebar" '#{@dnvr_sidebar_pid}')
        ${configureSession}
        exec tmux -S "$__socket" attach-session -t "=$__session"
      fi
    '';

    exec = ''
      __socket="$DNVR_STATE/runtime/tmux-${name}.sock"
      __session=dnvr
      __proc_logs="$DNVR_STATE/logs/tmux-${name}"
      mkdir -p "$__proc_logs"

      # A detached tmux server otherwise starts at 80x24 and proportionally
      # stretches that layout when the first real client attaches. Seed it
      # with the invoking terminal's dimensions so the fixed sidebar is right
      # from the first frame, not corrected one frame later.
      if ! read -r __rows __cols < <(${pkgs.coreutils}/bin/stty size 2>/dev/null); then
        __rows=24
        __cols=80
      fi
      if (( __rows < 2 || __cols < 32 )); then
        __rows=24
        __cols=80
      fi

      tmux -S "$__socket" -f /dev/null new-session -d \
        -x "$__cols" -y "$__rows" -s "$__session" -n dashboard \
        ${sidebar}/bin/dnvr-tmux-sidebar
      __sidebar=$(tmux -S "$__socket" display-message -p \
        -t "=$__session:dashboard.0" '#{pane_id}')
      tmux -S "$__socket" set-option -p -t "$__sidebar" @dnvr_role sidebar
      tmux -S "$__socket" set-option -p -t "$__sidebar" @dnvr_name Processes
      tmux -S "$__socket" set-option -p -t "$__sidebar" \
        @dnvr_sidebar_command ${sidebar}/bin/dnvr-tmux-sidebar

      __sidebar_ready=false
      for ((i = 0; i < 100; i++)); do
        if [[ "$(tmux -S "$__socket" display-message -p -t "$__sidebar" '#{@dnvr_ready}')" == 1 ]]; then
          __sidebar_ready=true
          break
        fi
        ${pkgs.coreutils}/bin/sleep 0.01
      done
      if [[ "$__sidebar_ready" != true ]]; then
        echo "dnvr: tmux sidebar did not become ready" >&2
        tmux -S "$__socket" kill-session -t "=$__session"
        exit 1
      fi
      __sidebar_pid=$(tmux -S "$__socket" display-message -p \
        -t "$__sidebar" '#{@dnvr_sidebar_pid}')

      ${configureSession}

      ${launchProcesses}

      __first=$(tmux -S "$__socket" list-panes -s -t "=$__session" \
        -F '#{@dnvr_index}	#{pane_id}' \
        | ${pkgs.gawk}/bin/awk -F '\t' '$1 ~ /^[0-9]+$/ { print }' \
        | ${pkgs.coreutils}/bin/sort -n -t $'\t' -k1,1 \
        | ${pkgs.coreutils}/bin/head -n1 \
        | ${pkgs.coreutils}/bin/cut -f2)
      if [[ -n "$__first" ]]; then
        tmux -S "$__socket" join-pane -h -s "$__first" -t "$__sidebar"
        tmux -S "$__socket" resize-pane -t "$__sidebar" -x 30
      fi
      tmux -S "$__socket" select-pane -t "$__sidebar"
      exec tmux -S "$__socket" attach-session -t "=$__session"
    '';
  }
