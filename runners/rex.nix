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
  shellName = lib.removeSuffix "-up" name;
  where = "dnvr shell '${shellName}', runner_settings.rex";

  defaults = {
    layout = "tabs";
    arrangement = "tiled";
    placement = "new-session";
    focus = true;
  };

  choices = {
    layout = ["tabs" "panes"];
    arrangement = ["tiled" "columns" "rows"];
    placement = ["new-session" "current-session"];
  };

  showChoices = vs: lib.concatMapStringsSep ", " (v: ''"${v}"'') vs;

  unknownSettings = lib.attrNames (removeAttrs settings (lib.attrNames defaults));

  cfg =
    if unknownSettings != []
    then throw "${where}: unknown keys ${lib.concatStringsSep ", " unknownSettings} (expected ${lib.concatStringsSep ", " (lib.attrNames defaults)})"
    else
      lib.mapAttrs (
        k: v:
          if choices ? ${k} && !(lib.elem v choices.${k})
          then throw "${where}.${k} = ${builtins.toJSON v}; expected one of ${showChoices choices.${k}}"
          else if k == "focus" && !builtins.isBool v
          then throw "${where}.focus must be a bool"
          else v
      )
      (defaults // settings);

  tabOf = p: let
    tab = processes.${p}.runner_settings.rex.tab or null;
  in
    if tab == null
    then
      if cfg.layout == "panes"
      then shellName
      else p
    else if builtins.isString tab && tab != ""
    then tab
    else throw "dnvr shell '${shellName}': processes.${p}.runner_settings.rex.tab must be a non-empty string";

  tabs =
    map (label: {
      inherit label;
      procs = lib.filter (p: tabOf p == label) processNames;
    })
    (lib.unique (map tabOf processNames));

  logName = p: lib.replaceStrings ["/"] ["_"] p;

  # Rex starts blocks from its server's environment, so the launcher adopts
  # the up-script's exported snapshot first. `script` keeps the process on a
  # pty while appending its raw output to the log that `dnvr logs -f` tails.
  launcher = p: let
    run = pkgs.writeShellScript "dnvr-${shellName}-${logName p}-run" (runnerLib.resolveCommand p processes.${p});
    record =
      if pkgs.stdenv.hostPlatform.isDarwin
      then ''exec /usr/bin/script -q -a -F "$__log" ${run}''
      else ''exec ${pkgs.util-linux}/bin/script -q -a -f -e -c ${run} "$__log"'';
  in
    pkgs.writeShellScript "dnvr-${shellName}-${logName p}-launch" ''
      source "$1"
      __log="$DNVR_STATE/logs/rex-${name}/${logName p}.log"
      mkdir -p "''${__log%/*}"
      ${record}
    '';

  leaf = p: {
    block = {
      flavor = "com.superlogical.terminal.shell";
      label = p;
      options = {
        shell = "none";
        cwd = "@CWD@";
        command = ["${launcher p}" "@ENV@"];
        exit.on_completion = false;
      };
    };
  };

  # Halving keeps leaves in declaration order, which is the order Rex
  # returns block IDs in; k/n ratios give every pane an equal share.
  tree = depth: procs: let
    n = lib.length procs;
    k = n / 2;
    horizontal = cfg.arrangement == "columns" || (cfg.arrangement == "tiled" && lib.mod depth 2 == 0);
  in
    if n == 1
    then leaf (lib.head procs)
    else {
      split = {
        direction =
          if horizontal
          then "horizontal"
          else "vertical";
        ratio = k * 1.0 / n;
        before = tree (depth + 1) (lib.take k procs);
        after = tree (depth + 1) (lib.drop k procs);
      };
    };

  windowsJson = pkgs.writeText "dnvr-${shellName}-rex-windows.json" (builtins.toJSON (map (t: {
      window_label = t.label;
      layout = tree 0 t.procs;
      inherit (t) procs;
    })
    tabs));

  leavesJson = pkgs.writeText "dnvr-${shellName}-rex-leaves.json" (builtins.toJSON (lib.genAttrs processNames leaf));

  runtimeInputs = [pkgs.jq pkgs.coreutils pkgs.gnugrep pkgs.ansifilter];

  substitute = ''walk(if . == "@ENV@" then $env elif . == "@CWD@" then $cwd else . end)'';

  prelude = ''
    : "''${DNVR_STATE:?DNVR_STATE must be set (run via nix develop)}"
    command -v rex >/dev/null || {
      echo "dnvr: the rex runner needs the Rex terminal's 'rex' CLI on PATH" >&2
      exit 1
    }
    __rex_state="$DNVR_STATE/runtime/rex-${name}.json"
    __rex_env="$DNVR_STATE/runtime/rex-${name}.env"
    __procs=(${lib.escapeShellArgs processNames})
    ${runnerLib.procHelpers}

    # Block IDs currently in session $1; fails when the session is gone.
    __rex_blocks() {
      jq -nc --arg s "$1" '{session_id: $s}' \
        | rex api call session.view - 2>/dev/null \
        | jq -r '.windows[].layers[].blocks[].block_id'
    }

    __rex_get() {
      jq -r "$1 // empty" "$__rex_state"
    }

    __rex_set() {
      jq "''${@:2}" "$1" "$__rex_state" > "$__rex_state.tmp"
      mv "$__rex_state.tmp" "$__rex_state"
    }

    __rex_leaf() {
      jq -c --arg p "$1" --arg env "$__rex_env" --arg cwd "$(__rex_get .cwd)" \
        '.[$p] | ${substitute}' ${leavesJson}
    }

    # Start <proc> afresh: beside its old block, which is then closed so the
    # new block takes its place, or in a new tab when the old one is gone.
    __rex_respawn() {
      local proc="$1" sid old new created
      sid=$(__rex_get .session_id)
      old=$(__rex_get ".blocks[\"$proc\"]")
      if [ -n "$old" ] && __rex_blocks "$sid" | grep -qxF "$old"; then
        new=$(jq -nc --arg s "$sid" --arg a "$old" --argjson l "$(__rex_leaf "$proc")" \
          '{session_id: $s, anchor_id: $a, direction: "horizontal", side: "after", layout: $l}' \
          | rex api call session.new_split - | jq -r '.block_ids[0]')
        rex block close -s "$sid" "$old" >/dev/null
      else
        created=$(jq -nc --arg s "$sid" --arg p "$proc" --argjson l "$(__rex_leaf "$proc")" \
          '{session_id: $s, window_label: $p, focus: false, layout: $l}' \
          | rex api call session.new_window -)
        new=$(jq -r '.block_ids[0]' <<<"$created")
        __rex_set '.windows += [$w]' --arg w "$(jq -r .window_id <<<"$created")"
      fi
      __rex_set '.blocks[$p] = $b' --arg p "$proc" --arg b "$new"
    }

    # The Rex app to switch: one showing the session `dnvr up` ran in, else
    # the only connected app. Non-app clients never answer actions.
    __rex_app() {
      rex client ls --json 2>/dev/null | jq -r --arg s "''${REX_SESSION:-}" '
        [.clients[] | select(.info.kind? == "app")] as $apps
        | [$apps[] | select((.session_ids // []) | index($s))]
          + (if ($apps | length) == 1 then $apps else [] end)
        | first | .client_id // empty'
    }

    # Rex reports no Remote Control setting, so the action's own refusal is
    # how a disabled app is detected.
    __rex_focus() {
      ${lib.boolToString cfg.focus} || return 0
      local label app err
      label=$(__rex_get .label)
      app=$(__rex_app)
      if [ -z "$app" ]; then
        echo "dnvr: open the Rex session '$label' to see the processes" >&2
        return 0
      fi
      if ! err=$(rex -C "$app" --timeout 5s "do" session.select \
        session_id="$(__rex_get .session_id)" 2>&1 >/dev/null); then
        case "$err" in
          *"not accepting actions"*)
            echo "dnvr: turn on Remote Control in Rex.app (Settings → Rex Server) to switch to the group automatically; for now, open the Rex session '$label'" >&2
            ;;
          *)
            echo "dnvr: could not switch Rex to '$label' (''${err#Error: }); open it to see the processes" >&2
            ;;
        esac
      fi
    }
  '';

  mkVerb = verb: text:
    pkgs.writeShellApplication {
      name = "${name}-rex-${verb}";
      inherit runtimeInputs;
      # jq filters are single-quoted and carry their own `$` variables.
      excludeShellChecks = ["SC2016"];
      text = prelude + text;
    };

  # Args: <process> <index> <logName> <follow> <ansi> <lines>
  logs = mkVerb "logs" ''
    __process="$1"
    __log="$DNVR_STATE/logs/rex-${name}/$3.log"
    __follow="$4"
    __ansi="$5"
    __lines="$6"
    __tail() {
      if [ -n "$__lines" ]; then
        tail -n "$__lines"
      else
        cat
      fi
    }
    if "$__follow"; then
      [ -f "$__log" ] || {
        echo "dnvr logs: no log yet for '$__process'" >&2
        exit 1
      }
      __args=(-n "''${__lines:-+1}" -F)
      if "$__ansi"; then
        exec tail "''${__args[@]}" "$__log"
      else
        tail "''${__args[@]}" "$__log" | ansifilter
      fi
      exit
    fi
    __block=
    if [ -f "$__rex_state" ]; then
      __sid=$(__rex_get .session_id)
      __block=$(__rex_get ".blocks[\"$__process\"]")
      if [ -n "$__block" ] && ! { __rex_blocks "$__sid" || true; } | grep -qxF "$__block"; then
        __block=
      fi
    fi
    if [ -n "$__block" ]; then
      if "$__ansi"; then
        rex capture -s "$__sid" -b "$__block" --trim --format=vt | __tail
      else
        rex capture -s "$__sid" -b "$__block" --trim --unwrap | __tail
      fi
    elif [ -f "$__log" ]; then
      if "$__ansi"; then
        tr -d '\r' < "$__log" | __tail
      else
        ansifilter < "$__log" | tr -d '\r' | __tail
      fi
    else
      echo "dnvr logs: no block or log for '$__process' (run 'dnvr up' first)" >&2
      exit 1
    fi
  '';

  # Interrupt first: closing a block only SIGHUPs its process, which some
  # servers (postgres) treat as a config reload rather than a stop.
  down = mkVerb "down" ''
    [ -f "$__rex_state" ] || {
      echo "dnvr down: no Rex group is running" >&2
      exit 1
    }
    __sid=$(__rex_get .session_id)
    __live=$(__rex_blocks "$__sid" || true)
    for __proc in "''${__procs[@]}"; do
      __block=$(__rex_get ".blocks[\"$__proc\"]")
      if [ -n "$__block" ] && grep -qxF "$__block" <<<"$__live" && __dnvr_running "$__proc"; then
        rex send-key -s "$__sid" -b "$__block" ctrl+c
      fi
    done
    for __proc in "''${__procs[@]}"; do
      __dnvr_wait_stopped "$__proc" 10 \
        || echo "dnvr down: $__proc still running after 10s; closing its terminal" >&2
    done
    if [ -n "$__live" ]; then
      if [ "$(__rex_get .placement)" = new-session ]; then
        rex kill "$__sid" >/dev/null
      else
        while read -r __window; do
          rex window close -s "$__sid" "$__window" >/dev/null 2>&1 || true
        done < <(__rex_get '.windows[]')
      fi
    fi
    rm -f "$__rex_state" "$__rex_env"
  '';

  # Args: <process> <index>
  restart = mkVerb "restart" ''
    __proc="$1"
    if [ ! -f "$__rex_state" ] || ! __live=$(__rex_blocks "$(__rex_get .session_id)"); then
      echo "dnvr restart: no Rex group is running (run 'dnvr up' first)" >&2
      exit 1
    fi
    if __dnvr_running "$__proc"; then
      __block=$(__rex_get ".blocks[\"$__proc\"]")
      if [ -n "$__block" ] && grep -qxF "$__block" <<<"$__live"; then
        rex send-key -s "$(__rex_get .session_id)" -b "$__block" ctrl+c
      fi
      __dnvr_wait_stopped "$__proc" 10 \
        || echo "dnvr restart: $__proc still running after 10s; closing its terminal" >&2
    fi
    __rex_respawn "$__proc"
  '';
in
  runnerLib.mkUpScript {
    inherit name env prerun;
    runtimeInputs = runtimeInputs ++ [pkgs.flock];
    passthru.commands = {inherit logs down restart;};

    # A live group is focused, with any process block the user closed
    # started again; a group with no surviving blocks is created afresh.
    reattach = ''
      ${prelude}
      if [ -f "$__rex_state" ]; then
        __live=$(__rex_blocks "$(__rex_get .session_id)" || true)
        __missing=()
        __alive=false
        for __proc in "''${__procs[@]}"; do
          __block=$(__rex_get ".blocks[\"$__proc\"]")
          if [ -n "$__block" ] && grep -qxF "$__block" <<<"$__live"; then
            __alive=true
          else
            __missing+=("$__proc")
          fi
        done
        if "$__alive"; then
          for __proc in "''${__missing[@]}"; do
            __rex_respawn "$__proc"
          done
          __rex_focus
          exit 0
        fi
        rm -f "$__rex_state"
      fi
    '';

    exec = ''
      ${lib.optionalString (processNames == []) ''
        echo "dnvr up: no processes configured" >&2
        exit 0
      ''}
      ${lib.optionalString (cfg.placement == "current-session") ''
        [ -n "''${REX_SESSION:-}" ] || {
          echo "dnvr up: runner_settings.rex.placement = \"current-session\" needs 'dnvr up' to run inside Rex" >&2
          exit 1
        }
      ''}

      # The terminal's own identity must come from the block, not from here.
      rm -f "$__rex_env"
      (
        unset TERM TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM TERMINFO \
          REX_SESSION REX_BLOCK TMUX TMUX_PANE SHLVL PWD OLDPWD COLUMNS LINES
        umask 077
        export -p > "$__rex_env"
      )

      __label="$(basename "''${DNVR_ROOT:-''${DNVR_STATE%/*}}")/${shellName}"
      __windows=$(jq -c --arg env "$__rex_env" --arg cwd "$PWD" '${substitute}' ${windowsJson})
      ${
        if cfg.placement == "new-session"
        then ''
          __created=$(jq -nc --arg l "$__label" --argjson w "$__windows" \
            '{label: $l, initial_windows: [$w[] | del(.procs)]}' \
            | rex api call session.create -)
          __sid=$(jq -r .session_id <<<"$__created")
          __results=$(jq -c .initial_windows <<<"$__created")
        ''
        else ''
          __sid="$REX_SESSION"
          __results=$(jq -c '.[] | del(.procs)' <<<"$__windows" | while read -r __window; do
            jq -c --arg s "$__sid" '. + {session_id: $s, focus: false}' <<<"$__window" \
              | rex api call session.new_window -
          done | jq -sc .)
        ''
      }
      jq -n --arg sid "$__sid" --arg label "$__label" --arg cwd "$PWD" \
        --argjson w "$__windows" --argjson r "$__results" '{
          session_id: $sid,
          placement: ${builtins.toJSON cfg.placement},
          label: $label,
          cwd: $cwd,
          windows: [$r[].window_id],
          blocks: ([range(0; $w | length) as $i
            | [$w[$i].procs, $r[$i].block_ids] | transpose[]
            | {key: .[0], value: .[1]}] | from_entries)
        }' > "$__rex_state"
      ${lib.optionalString cfg.focus ''
        rex focus -s "$__sid" "$(__rex_get '.windows[0]')" >/dev/null 2>&1 || true
      ''}
      __rex_focus
    '';
  }
