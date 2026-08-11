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
      readyName = ".launch-${toString index}";
      guardedCommand = ''
        while [[ ! -e "$DNVR_STATE/logs/tmux-${name}/${readyName}" ]]; do
          ${pkgs.coreutils}/bin/sleep 0.01
        done
        ${command}
      '';
      launch =
        if index == 0
        then ''
          __pane=$(tmux -S "$__socket" split-window -h -d -P -F '#{pane_id}' \
            -t "$__sidebar" ${lib.escapeShellArg guardedCommand})
        ''
        else ''
          __pane=$(tmux -S "$__socket" new-window -d -P -F '#{pane_id}' \
            -t "=$__session:" -n ${lib.escapeShellArg procName} \
            ${lib.escapeShellArg guardedCommand})
        '';
    in ''
      __ready="$__proc_logs/${readyName}"
      ${pkgs.coreutils}/bin/rm -f "$__ready"
      ${launch}
      tmux -S "$__socket" set-option -p -t "$__pane" @dnvr_role process
      tmux -S "$__socket" set-option -p -t "$__pane" @dnvr_name \
        ${lib.escapeShellArg procName}
      tmux -S "$__socket" set-option -p -t "$__pane" @dnvr_index \
        ${toString index}
      __log="$__proc_logs/${logName}.log"
      printf -v __pipe '%q >> %q' ${pkgs.coreutils}/bin/cat "$__log"
      tmux -S "$__socket" pipe-pane -o -t "$__pane" "$__pipe"
      ${pkgs.coreutils}/bin/touch "$__ready"
    '') processNames);

  tmuxConfig = pkgs.writeText "dnvr-tmux.conf" ''
    set-option -g status off
    set-option -g remain-on-exit on
    set-option -g mouse on
    # Agent-facing `dnvr logs` reads the complete retained pane history.
    set-option -g history-limit 100000
    set-option -g pane-border-status top
    set-option -g pane-border-indicators off
    set-option -g pane-border-format \
      '#{?pane_active,#[fg=cyan],#[fg=colour244]}#{?#{==:#{@dnvr_role},sidebar},Processes,#{@dnvr_name} #{?pane_dead,DOWN,UP}}#[default] '
    set-option -g pane-border-style fg=colour238
    set-option -g pane-active-border-style fg=colour238
    set-window-option -g window-size latest
    set-window-option -g main-pane-width 30
    set-option -g default-shell ${pkgs.bash}/bin/bash
    set-option -s escape-time 0
    set-option -g prefix None
    set-option -g prefix2 None

    bind-key -n C-g detach-client
    bind-key -n C-a select-pane -t '#{@dnvr_sidebar}' \; \
      run-shell '${pkgs.coreutils}/bin/kill -USR1 #{@dnvr_sidebar_pid}'

    set-hook -g pane-died \
      'run-shell "${pkgs.coreutils}/bin/kill -USR1 #{@dnvr_sidebar_pid}"'
    set-hook -g client-attached \
      'select-layout -t "=dnvr:dashboard" main-vertical ; run-shell "${pkgs.coreutils}/bin/kill -USR1 #{@dnvr_sidebar_pid}"'
    set-hook -g client-resized \
      'select-layout -t "=dnvr:dashboard" main-vertical'
  '';

  configureSession = ''
    # Runtime identities are the only imperative configuration. The config
    # resolves these user options when a binding or hook actually fires.
    tmux -S "$__socket" set-option -g @dnvr_sidebar "$__sidebar"
    tmux -S "$__socket" set-option -g @dnvr_sidebar_pid "$__sidebar_pid"
    tmux -S "$__socket" source-file ${tmuxConfig}
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

      tmux -S "$__socket" -f ${tmuxConfig} new-session -d \
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

      ${lib.optionalString (processNames != []) ''
        tmux -S "$__socket" select-layout -t "=$__session:dashboard" main-vertical
      ''}
      tmux -S "$__socket" select-pane -t "$__sidebar"
      exec tmux -S "$__socket" attach-session -t "=$__session"
    '';
  }
