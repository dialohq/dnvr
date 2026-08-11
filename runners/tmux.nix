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

  sidebar = pkgs.writeShellApplication {
    name = "dnvr-tmux-sidebar-${name}";
    runtimeInputs = [pkgs.coreutils pkgs.tmux];
    text = ''
      sidebar_pane="$TMUX_PANE"
      session_id=$(tmux display-message -p -t "$sidebar_pane" '#{session_id}')
      selected=0

      load_processes() {
        mapfile -t rows < <(
          tmux list-panes -s -t "$session_id" \
            -F '#{@dnvr_index}	#{pane_id}	#{@dnvr_name}	#{pane_dead}	#{window_id}' \
          | ${pkgs.gawk}/bin/awk -F '\t' '$1 ~ /^[0-9]+$/ { print }' \
          | ${pkgs.coreutils}/bin/sort -n -t $'\t' -k1,1
        )
        count="''${#rows[@]}"
        if (( count == 0 )); then
          selected=0
        elif (( selected >= count )); then
          selected=$((count - 1))
        fi
      }

      field() {
        printf '%s' "$1" | ${pkgs.coreutils}/bin/cut -f "$2"
      }

      selected_pane() {
        if (( count > 0 )); then
          field "''${rows[$selected]}" 2
        fi
      }

      visible_pane() {
        tmux list-panes -t "$sidebar_pane" \
          -F '#{?#{==:#{@dnvr_role},process},#{pane_id},}' \
          | ${pkgs.gawk}/bin/awk 'NF { print; exit }'
      }

      show_selected() {
        local focus_target="''${1:-true}" target current
        target=$(selected_pane)
        [[ -n "$target" ]] || return 0
        current=$(visible_pane)
        if [[ "$current" != "$target" ]]; then
          if [[ -n "$current" ]]; then
            # Keep the dashboard layout intact. The selected background pane
            # trades places with the visible process pane, producing one
            # content diff instead of break/join/resize layout churn.
            tmux swap-pane -d -s "$target" -t "$current"
          else
            tmux join-pane -h -s "$target" -t "$sidebar_pane"
            tmux resize-pane -t "$sidebar_pane" -x 30
          fi
        fi
        if [[ "$focus_target" == true ]]; then
          tmux select-pane -t "$target"
        fi
      }

      activate_selected() {
        local target current
        target=$(selected_pane)
        [[ -n "$target" ]] || return 0
        current=$(visible_pane)
        if [[ "$current" == "$target" ]]; then
          tmux select-pane -t "$target"
        else
          show_selected false
        fi
      }

      handle_mouse() {
        local sequence="" char="" row
        # tmux forwards SGR mouse events requested by this pane. Read the
        # remainder of the escape sequence without delaying ordinary Escape.
        while IFS= read -rsn1 -t 0.05 char; do
          sequence+="$char"
          [[ "$char" == M || "$char" == m ]] && break
        done
        if [[ "$sequence" =~ ^\[\<0\;[0-9]+\;([0-9]+)M$ ]]; then
          row="''${BASH_REMATCH[1]}"
          if (( row >= 1 && row <= count )); then
            selected=$((row - 1))
            show_selected false
            return 0
          fi
        fi
        return 1
      }

      render() {
        local i row pane proc dead current current_active marker status style reset height footer_row rendered old footer_hint
        local -a next_lines=()
        current=$(visible_pane)
        current_active=0
        if [[ -n "$current" ]]; then
          current_active=$(tmux display-message -p -t "$current" '#{pane_active}')
        fi
        height=$(tmux display-message -p -t "$sidebar_pane" '#{pane_height}')
        for ((i = 0; i < height; i++)); do
          next_lines[i]=""
        done
        for ((i = 0; i < count; i++)); do
          row="''${rows[$i]}"
          pane=$(field "$row" 2)
          proc=$(field "$row" 3)
          dead=$(field "$row" 4)
          marker=' '
          status='UP'
          style='\033[32m'
          if [[ "$pane" == "$current" ]]; then
            marker='●'
            if [[ "$current_active" == 1 ]]; then
              marker='▶'
            fi
          fi
          if [[ "$dead" == 1 ]]; then
            status='DOWN'
            style='\033[31m'
          fi
          reset='\033[0m'
          if (( i == selected )); then
            printf -v rendered '\033[7m%s %-16.16s %b%4s\033[39m\033[K\033[0m' \
              "$marker" "$proc" "$style" "$status"
          else
            printf -v rendered '%s %-16.16s %b%4s%b' \
              "$marker" "$proc" "$style" "$status" "$reset"
          fi
          if (( i < height )); then
            next_lines[i]="$rendered"
          fi
        done
        footer_row=$((height - 3))
        if (( footer_row <= count + 1 )); then
          footer_row=$((count + 2))
        fi
        footer_hint='j/k move    enter view'
        if [[ "$(selected_pane)" == "$current" ]]; then
          footer_hint='j/k move    enter interact'
        fi
        if [[ "$current_active" == 1 ]]; then
          footer_hint='process active  C-a sidebar'
        fi
        if (( footer_row <= height )); then
          printf -v rendered '\033[2m%s\033[0m' "$footer_hint"
          next_lines[footer_row - 1]="$rendered"
        fi
        if (( footer_row + 1 <= height )); then
          next_lines[footer_row]=$'\033[2m r restart   x interrupt\033[0m'
        fi
        if (( footer_row + 2 <= height )); then
          next_lines[footer_row + 1]=$'\033[2m C-a sidebar C-g detach\033[0m'
        fi
        if (( footer_row + 3 <= height )); then
          next_lines[footer_row + 2]=$'\033[2m Q stop all\033[0m'
        fi

        # tmux already diffs the composed terminal. Avoid invalidating the
        # whole sidebar before it gets there: update only rows whose rendered
        # contents actually changed.
        for ((i = 0; i < height; i++)); do
          old="''${screen_lines[i]-}"
          if [[ "$old" != "''${next_lines[i]}" ]]; then
            printf '\033[%d;1H%s\033[K' "$((i + 1))" "''${next_lines[i]}"
          fi
        done
        screen_lines=("''${next_lines[@]}")
      }

      # Ask tmux to forward left-click events using the unambiguous SGR form.
      saved_stty=$(stty -g)
      stty -echo
      printf '\033[?1000h\033[?1006h\033[?25l'
      cleanup() {
        stty "$saved_stty"
        printf '\033[?1000l\033[?1006l\033[?25h'
      }
      trap cleanup EXIT
      request_refresh() {
        load_processes
        render
      }
      trap request_refresh USR1
      tmux set-option -p -t "$sidebar_pane" @dnvr_sidebar_pid "$BASHPID"

      # The sidebar is deliberately event-driven: no timer means no idle
      # redraws competing with process output. Only state-changing input and
      # explicit tmux lifecycle signals repaint it.
      screen_lines=()
      printf '\033[H\033[2J'
      load_processes
      render
      tmux set-option -p -t "$sidebar_pane" @dnvr_ready 1
      while true; do
        key=""
        if IFS= read -rsn1 key; then
          redraw=false
          case "$key" in
            j)
              if (( count > 0 )); then
                selected=$(((selected + 1) % count))
                redraw=true
              fi
              ;;
            k)
              if (( count > 0 )); then
                selected=$(((selected + count - 1) % count))
                redraw=true
              fi
              ;;
            "")
              activate_selected
              redraw=true
              ;;
            r)
              pane=$(selected_pane)
              [[ -n "$pane" ]] && tmux respawn-pane -k -t "$pane"
              redraw=true
              ;;
            x)
              pane=$(selected_pane)
              [[ -n "$pane" ]] && tmux send-keys -t "$pane" C-c
              ;;
            $'\033')
              if handle_mouse; then redraw=true; fi
              ;;
            $'\f') redraw=true ;;
            Q) tmux kill-session -t "$session_id" ;;
          esac
          if [[ "$redraw" == true ]]; then
            load_processes
            render
          fi
        fi
      done
    '';
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
        ${sidebar}/bin/dnvr-tmux-sidebar-${name}
      __sidebar=$(tmux -S "$__socket" display-message -p \
        -t "=$__session:dashboard.0" '#{pane_id}')
      tmux -S "$__socket" set-option -p -t "$__sidebar" @dnvr_role sidebar
      tmux -S "$__socket" set-option -p -t "$__sidebar" @dnvr_name Processes

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

      tmux -S "$__socket" set-option -g status off
      tmux -S "$__socket" set-option -g remain-on-exit on
      tmux -S "$__socket" set-option -g mouse on
      tmux -S "$__socket" set-option -g pane-border-status top
      tmux -S "$__socket" set-option -g pane-border-indicators off
      tmux -S "$__socket" set-option -g pane-border-format \
        ' #{?pane_active,#[fg=cyan],#[fg=colour244]}#{?#{==:#{@dnvr_role},sidebar},Processes,#{@dnvr_name} #{?pane_dead,DOWN,UP}}#[default] '
      tmux -S "$__socket" set-option -g pane-border-style fg=colour238
      tmux -S "$__socket" set-option -g pane-active-border-style fg=colour238
      tmux -S "$__socket" set-window-option -g window-size latest
      tmux -S "$__socket" set-option -g default-shell ${pkgs.bash}/bin/bash
      tmux -S "$__socket" set-option -s escape-time 0
      tmux -S "$__socket" unbind-key C-b
      tmux -S "$__socket" bind-key -n C-g detach-client
      tmux -S "$__socket" bind-key -n C-a \
        "select-pane -t '$__sidebar' ; run-shell '${pkgs.coreutils}/bin/kill -USR1 $__sidebar_pid'"
      tmux -S "$__socket" set-hook -g pane-died \
        "run-shell '${pkgs.coreutils}/bin/kill -USR1 $__sidebar_pid'"
      tmux -S "$__socket" set-hook -g client-attached \
        "resize-pane -t '$__sidebar' -x 30 ; run-shell '${pkgs.coreutils}/bin/kill -USR1 $__sidebar_pid'"
      tmux -S "$__socket" set-hook -g client-resized \
        "resize-pane -t '$__sidebar' -x 30 ; run-shell '${pkgs.coreutils}/bin/kill -USR1 $__sidebar_pid'"

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
