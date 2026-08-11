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
            tmux resize-pane -t "$sidebar_pane" -x 28
          fi
        fi
        if [[ "$focus_target" == true ]]; then
          tmux select-pane -t "$target"
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
          if (( row >= 3 && row < count + 3 )); then
            selected=$((row - 3))
            show_selected false
            return 0
          fi
        fi
        return 1
      }

      render() {
        local i row pane proc dead current marker status style reset
        current=$(visible_pane)
        printf '\033[H\033[2J\033[1m Processes\033[0m\n\n'
        for ((i = 0; i < count; i++)); do
          row="''${rows[$i]}"
          pane=$(field "$row" 2)
          proc=$(field "$row" 3)
          dead=$(field "$row" 4)
          marker=' '
          [[ "$pane" == "$current" ]] && marker='●'
          status='UP'
          style='\033[32m'
          if [[ "$dead" == 1 ]]; then
            status='DOWN'
            style='\033[31m'
          fi
          reset='\033[0m'
          if (( i == selected )); then
            printf '\033[7m%s %-16.16s %b%4s%b\033[0m\n' \
              "$marker" "$proc" "$style" "$status" "$reset"
          else
            printf '%s %-16.16s %b%4s%b\n' \
              "$marker" "$proc" "$style" "$status" "$reset"
          fi
        done
        printf '\n \033[2mj/k select  enter open\n r restart   x interrupt\n C-a sidebar C-g detach\n Q stop all\033[0m'
      }

      # Ask tmux to forward left-click events using the unambiguous SGR form.
      saved_stty=$(stty -g)
      stty -echo
      printf '\033[?1000h\033[?1006h'
      cleanup() {
        stty "$saved_stty"
        printf '\033[?1000l\033[?1006l'
      }
      trap cleanup EXIT

      # The sidebar is deliberately event-driven: no timer means no idle
      # redraws competing with process output. Only state-changing input and
      # pane-died (which sends C-l) repaint it.
      load_processes
      render
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
              show_selected
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

      tmux -S "$__socket" -f /dev/null new-session -d \
        -s "$__session" -n dashboard \
        ${sidebar}/bin/dnvr-tmux-sidebar-${name}
      __sidebar=$(tmux -S "$__socket" display-message -p \
        -t "=$__session:dashboard.0" '#{pane_id}')
      tmux -S "$__socket" set-option -p -t "$__sidebar" @dnvr_role sidebar
      tmux -S "$__socket" set-option -p -t "$__sidebar" @dnvr_name Processes

      tmux -S "$__socket" set-option -g status off
      tmux -S "$__socket" set-option -g remain-on-exit on
      tmux -S "$__socket" set-option -g mouse on
      tmux -S "$__socket" set-option -g pane-border-status top
      tmux -S "$__socket" set-option -g pane-border-format \
        ' #{?#{==:#{@dnvr_role},sidebar},Processes,#{@dnvr_name} #{?pane_dead,DOWN,UP}} '
      tmux -S "$__socket" set-option -g pane-active-border-style fg=cyan
      tmux -S "$__socket" set-option -g pane-border-style fg=colour238
      tmux -S "$__socket" set-option -g default-shell ${pkgs.bash}/bin/bash
      tmux -S "$__socket" set-option -s escape-time 0
      tmux -S "$__socket" unbind-key C-b
      tmux -S "$__socket" bind-key -n C-g detach-client
      tmux -S "$__socket" bind-key -n C-a select-pane -t "$__sidebar"
      tmux -S "$__socket" set-hook -g pane-died \
        "send-keys -t '$__sidebar' C-l"

      ${launchProcesses}

      __first=$(tmux -S "$__socket" list-panes -s -t "=$__session" \
        -F '#{@dnvr_index}	#{pane_id}' \
        | ${pkgs.gawk}/bin/awk -F '\t' '$1 ~ /^[0-9]+$/ { print }' \
        | ${pkgs.coreutils}/bin/sort -n -t $'\t' -k1,1 \
        | ${pkgs.coreutils}/bin/head -n1 \
        | ${pkgs.coreutils}/bin/cut -f2)
      if [[ -n "$__first" ]]; then
        tmux -S "$__socket" join-pane -h -s "$__first" -t "$__sidebar"
        tmux -S "$__socket" resize-pane -t "$__sidebar" -x 28
      fi
      tmux -S "$__socket" select-pane -t "$__sidebar"
      exec tmux -S "$__socket" attach-session -t "=$__session"
    '';
  }
