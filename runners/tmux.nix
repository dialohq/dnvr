{
  pkgs,
  lib,
}: {
  name,
  processes,
  env ? {},
  prerun ? "",
  settings ? {},
}: let
  runnerLib = import ./lib.nix {inherit pkgs lib;};
  processNames = lib.attrNames processes;

  sidebar = pkgs.rustPlatform.buildRustPackage {
    pname = "dnvr-tmux-sidebar";
    version = "0.1.0";
    src = ./tmux-sidebar;
    cargoLock.lockFile = ./tmux-sidebar/Cargo.lock;
  };

  # Start the sidebar only after every process pane and its metadata exist,
  # so its first reload renders the complete list. Previously it started as
  # the session's first pane and remained empty until another event woke it.
  sidebarStart = ''
    while [[ ! -e "$DNVR_STATE/logs/tmux-${name}/.sidebar-ready" ]]; do
      ${pkgs.coreutils}/bin/sleep 0.01
    done
    exec ${sidebar}/bin/dnvr-tmux-sidebar
  '';

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
    # Keep sizing under the client-resized hook below. With `latest`, tmux
    # schedules the window resize for a later server tick, redraws the client
    # at the old geometry, and only then lets window-resized restore the fixed
    # sidebar. That intermediate frame is the visible horizontal-resize flash.
    set-window-option -g window-size manual
    set-window-option -g main-pane-width 30
    set-option -g default-shell ${pkgs.bash}/bin/bash
    set-option -s escape-time 0
    set-option -g prefix None
    set-option -g prefix2 None

    bind-key -n C-g detach-client
  '';

  configureSession = ''
    tmux -S "$__socket" source-file ${tmuxConfig}
    # Bind concrete runtime identities on every attach. Looking them up as
    # user options when a binding fires depends on its pane/window context
    # and can occasionally resolve to an invalid pane target.
    tmux -S "$__socket" bind-key -n C-a \
      "select-pane -t '$__sidebar' ; run-shell '${pkgs.coreutils}/bin/kill -USR1 $__sidebar_pid'"
    tmux -S "$__socket" set-hook -g pane-died \
      "run-shell '${pkgs.coreutils}/bin/kill -USR1 $__sidebar_pid'"
    # Clear hooks installed by older runners. The pane screen is retained
    # while detached, so forcing another Rust redraw on attach only flashes
    # an identical frame.
    tmux -S "$__socket" set-hook -gu client-attached
    # In manual mode tmux does not asynchronously resize this window before
    # the hook runs. Apply the attached client geometry and restore the
    # divider in one command queue, before tmux paints the next client frame.
    # `resize-window -A` is used instead of client_width/client_height: tmux
    # 3.7c does not retain those formats in a client-resized hook's command
    # context. With one client this is its exact size; with several, keeping
    # the largest viewport avoids clipping the others.
    tmux -S "$__socket" set-hook -gu window-resized
    tmux -S "$__socket" set-hook -g client-resized \
      "resize-window -A -t '=$__session:dashboard' ; resize-pane -t '$__sidebar' -x 30"
  '';
  verbPrelude = ''
    : "''${DNVR_STATE:?DNVR_STATE must be set (run via nix develop)}"
    __socket="$DNVR_STATE/runtime/tmux-${name}.sock"
    __procs=(${lib.escapeShellArgs processNames})
    ${runnerLib.procHelpers}
    __dnvr_pane() {
      [ -S "$__socket" ] || return 0
      tmux -S "$__socket" list-panes -s -t =dnvr \
        -F '#{@dnvr_index}:#{pane_id}' 2>/dev/null \
        | awk -F : -v wanted="$1" '$1 == wanted { print $2; exit }'
    }
  '';

  mkVerb = verb: text:
    pkgs.writeShellApplication {
      name = "${name}-tmux-${verb}";
      runtimeInputs = [pkgs.tmux pkgs.coreutils pkgs.gawk pkgs.ansifilter];
      text = verbPrelude + text;
    };

  # Args: <process> <index> <logName> <follow> <ansi> <lines>
  logs = mkVerb "logs" ''
    __process="$1"
    __pane=$(__dnvr_pane "$2")
    __log="$DNVR_STATE/logs/tmux-${name}/$3.log"
    __follow="$4"
    __ansi="$5"
    __lines="$6"
    [ -n "$__pane" ] || {
      echo "dnvr logs: no pane for '$__process' (run 'dnvr up' first)" >&2
      exit 1
    }
    if "$__follow"; then
      [ -f "$__log" ] || {
        echo "dnvr logs: no log yet for '$__process'" >&2
        exit 1
      }
      __tail=(-n "''${__lines:-+1}" -F)
      if "$__ansi"; then
        exec tail "''${__tail[@]}" "$__log"
      else
        tail "''${__tail[@]}" "$__log" | ansifilter
      fi
    else
      __capture=(-p -J -S - -t "$__pane")
      "$__ansi" && __capture=(-e "''${__capture[@]}")
      if "$__ansi"; then
        if [ -n "$__lines" ]; then
          tmux -S "$__socket" capture-pane "''${__capture[@]}" | tail -n "$__lines"
        else
          exec tmux -S "$__socket" capture-pane "''${__capture[@]}"
        fi
      else
        # capture-pane includes unused screen rows and tmux's synthetic
        # "Pane is dead" footer. Keep real internal blank lines while
        # trimming that display-only tail from agent-facing output.
        tmux -S "$__socket" capture-pane "''${__capture[@]}" \
          | awk '
              /^Pane is dead \(status [0-9]+,/ { next }
              { line[NR] = $0; if ($0 !~ /^[[:space:]]*$/) last = NR }
              END { for (i = 1; i <= last; i++) print line[i] }
            ' \
          | if [ -n "$__lines" ]; then
              tail -n "$__lines"
            else
              cat
            fi
      fi
    fi
  '';

  # Interrupt first: closing a pane only SIGHUPs its process, which some
  # servers (postgres) treat as a config reload rather than a stop.
  down = mkVerb "down" ''
    if ! tmux -S "$__socket" has-session -t =dnvr 2>/dev/null; then
      echo "dnvr down: no tmux group is running" >&2
      exit 1
    fi
    for __i in "''${!__procs[@]}"; do
      __pane=$(__dnvr_pane "$__i")
      if [ -n "$__pane" ] && __dnvr_running "''${__procs[$__i]}"; then
        tmux -S "$__socket" send-keys -t "$__pane" C-c
      fi
    done
    for __proc in "''${__procs[@]}"; do
      __dnvr_wait_stopped "$__proc" 10 \
        || echo "dnvr down: $__proc still running after 10s; closing its pane" >&2
    done
    tmux -S "$__socket" kill-session -t =dnvr
  '';

  # Args: <process> <index>
  restart = mkVerb "restart" ''
    __pane=$(__dnvr_pane "$2")
    [ -n "$__pane" ] || {
      echo "dnvr restart: no pane for '$1' (run 'dnvr up' first)" >&2
      exit 1
    }
    if __dnvr_running "$1"; then
      tmux -S "$__socket" send-keys -t "$__pane" C-c
      __dnvr_wait_stopped "$1" 10 \
        || echo "dnvr restart: $1 still running after 10s; killing its pane" >&2
    fi
    tmux -S "$__socket" respawn-pane -k -t "$__pane"
    __sidebar_pid=$(tmux -S "$__socket" list-panes -s -t =dnvr \
      -f '#{==:#{@dnvr_role},sidebar}' -F '#{@dnvr_sidebar_pid}')
    [ -z "$__sidebar_pid" ] || kill -USR1 "$__sidebar_pid" 2>/dev/null || true
  '';
in
  runnerLib.mkUpScript {
    inherit name env prerun;
    runtimeInputs = [pkgs.tmux];
    passthru.commands = {inherit logs down restart;};

    # The socket is scoped by DNVR_STATE, so a fixed session name is enough and
    # avoids tmux's punctuation restrictions on session names.
    reattach = ''
      __socket="$DNVR_STATE/runtime/tmux-${name}.sock"
      __session=dnvr
      if tmux -S "$__socket" has-session -t "=$__session" 2>/dev/null; then
        __sidebar=$(tmux -S "$__socket" list-panes -s -t "=$__session" \
          -f '#{==:#{@dnvr_role},sidebar}' -F '#{pane_id}')
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
        # Bring a detached session to this terminal's geometry before it is
        # visible. Otherwise tmux attaches at the old width and corrects it a
        # frame later, exposing the sidebar's stale narrow/wide buffer.
        if read -r __rows __cols < <(${pkgs.coreutils}/bin/stty size 2>/dev/null) \
          && (( __rows >= 2 && __cols >= 32 )); then
          tmux -S "$__socket" resize-window -t "=$__session:dashboard" \
            -x "$__cols" -y "$__rows"
          tmux -S "$__socket" resize-pane -t "$__sidebar" -x 30
        fi
        exec tmux -S "$__socket" attach-session -t "=$__session"
      fi
    '';

    exec = ''
      __socket="$DNVR_STATE/runtime/tmux-${name}.sock"
      __session=dnvr
      __proc_logs="$DNVR_STATE/logs/tmux-${name}"
      mkdir -p "$__proc_logs"
      __sidebar_gate="$__proc_logs/.sidebar-ready"
      ${pkgs.coreutils}/bin/rm -f "$__sidebar_gate"

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
        ${lib.escapeShellArg sidebarStart}
      __sidebar=$(tmux -S "$__socket" display-message -p \
        -t "=$__session:dashboard.0" '#{pane_id}')
      tmux -S "$__socket" set-option -p -t "$__sidebar" @dnvr_role sidebar
      tmux -S "$__socket" set-option -p -t "$__sidebar" @dnvr_name Processes

      ${launchProcesses}
      ${pkgs.coreutils}/bin/touch "$__sidebar_gate"

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
      tmux -S "$__socket" set-option -p -t "$__sidebar" \
        @dnvr_sidebar_command ${sidebar}/bin/dnvr-tmux-sidebar

      ${configureSession}

      ${lib.optionalString (processNames != []) ''
        tmux -S "$__socket" select-layout -t "=$__session:dashboard" main-vertical
      ''}
      tmux -S "$__socket" select-pane -t "$__sidebar"
      exec tmux -S "$__socket" attach-session -t "=$__session"
    '';
  }
