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
            "''${__pane_env[@]}" -t "$__sidebar" \
            ${lib.escapeShellArg guardedCommand})
        ''
        else ''
          __pane=$(tmux -S "$__socket" new-window -d -P -F '#{pane_id}' \
            "''${__pane_env[@]}" -t "=$__session:" \
            -n ${lib.escapeShellArg procName} ${lib.escapeShellArg guardedCommand})
        '';
    in ''
      __ready="$__proc_logs/${readyName}"
      ${pkgs.coreutils}/bin/rm -f "$__ready"
      __pane_env=()
      for __override_key in "''${!__dnvr_env_overrides[@]}"; do
        if [[ "$__override_key" == ${lib.escapeShellArg procName}.* ]]; then
          __override_var="''${__override_key#*.}"
          __pane_env+=(-e "$__override_var=''${__dnvr_env_overrides[$__override_key]}")
        fi
      done
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
    '')
    processNames);

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
in
  runnerLib.mkUpScript {
    inherit name env prerun;
    runtimeInputs = [pkgs.tmux];

    # The socket is scoped by DNVR_STATE, so a fixed session name is enough and
    # avoids tmux's punctuation restrictions on session names.
    reattach = ''
      declare -A __dnvr_env_overrides=()
      while (( $# > 0 )); do
        case "$1" in
          --env)
            if (( $# < 2 )); then
              echo "dnvr up: --env requires process.VARIABLE=value" >&2
              exit 64
            fi
            __override=$2
            shift 2
            ;;
          --env=*)
            __override="''${1#*=}"
            shift
            ;;
          *)
            echo "dnvr up: unknown argument '$1'" >&2
            exit 64
            ;;
        esac

        if [[ "$__override" != *=* ]]; then
          echo "dnvr up: invalid --env '$__override' (expected process.VARIABLE=value)" >&2
          exit 64
        fi
        __override_name="''${__override%%=*}"
        __override_value="''${__override#*=}"
        if [[ "$__override_name" != *.* ]]; then
          echo "dnvr up: invalid --env '$__override' (expected process.VARIABLE=value)" >&2
          exit 64
        fi
        __override_process="''${__override_name%%.*}"
        __override_var="''${__override_name#*.}"
        ${
        if processNames == []
        then ''
          echo "dnvr up: unknown process '$__override_process'" >&2
          exit 64
        ''
        else ''
          case "$__override_process" in
            ${lib.concatMapStringsSep " | " lib.escapeShellArg processNames}) ;;
            *)
              echo "dnvr up: unknown process '$__override_process'" >&2
              exit 64
              ;;
          esac
        ''
      }
        if [[ ! "$__override_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
          echo "dnvr up: invalid environment variable '$__override_var'" >&2
          exit 64
        fi
        __dnvr_env_overrides["$__override_name"]="$__override_value"
      done

      __socket="$DNVR_STATE/runtime/tmux-${name}.sock"
      __session=dnvr
      if tmux -S "$__socket" has-session -t "=$__session" 2>/dev/null; then
        if (( ''${#__dnvr_env_overrides[@]} > 0 )); then
          echo "dnvr up: --env cannot change an already-running process group" >&2
          exit 1
        fi
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
