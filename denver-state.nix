{
  pkgs,
  lib,
}:
pkgs.writeShellApplication {
  name = "denver-state";
  runtimeInputs = [pkgs.coreutils pkgs.python3];
  text = ''
    # Per-service runtime state directory. Convention:
    #   $DEVENV_STATE/runtime/<service>/<key>
    # Each service's wrapper has DEVENV_RUNTIME_DIR pointing at its own dir
    # (set by devenv-module.nix), so `set` and `get` (own-scope) need no
    # service name. Cross-service reads use `get <svc>.<key>`.

    usage() {
      cat >&2 <<EOF
    denver-state — runtime state for denver devenvs

      denver-state set <key> <value>          publish to own scope (needs DEVENV_RUNTIME_DIR)
      denver-state get <svc>.<key>            read another service's value, fail if missing
      denver-state wait <svc>.<key> [--timeout=N]  block until <svc>.<key> exists (default 30s)
      denver-state pick-port                  echo a random free TCP port
      denver-state dump                       list everything under \$DEVENV_STATE/runtime/

    EOF
      exit 64
    }

    : "''${DEVENV_STATE:?DEVENV_STATE must be set (run via nix develop)}"
    RUNTIME="$DEVENV_STATE/runtime"

    # Split "svc.key" → svc, key. Service names may contain dashes; keys must
    # not contain dots.
    split_ref() {
      local ref="$1"
      if [[ "$ref" != *.* ]]; then
        echo "denver-state: expected '<svc>.<key>', got '$ref'" >&2
        exit 2
      fi
      svc="''${ref%%.*}"
      key="''${ref#*.}"
    }

    cmd="''${1:-}"
    [ -z "$cmd" ] && usage
    shift || true

    case "$cmd" in
      set)
        [ "$#" -eq 2 ] || usage
        : "''${DEVENV_RUNTIME_DIR:?denver-state set must run in a service-scoped wrapper (DEVENV_RUNTIME_DIR unset)}"
        mkdir -p "$DEVENV_RUNTIME_DIR"
        # Atomic write: temp + rename, so readers never see a half-written file.
        tmp=$(mktemp -p "$DEVENV_RUNTIME_DIR" ".tmp.$1.XXXXXX")
        printf '%s\n' "$2" > "$tmp"
        mv "$tmp" "$DEVENV_RUNTIME_DIR/$1"
        ;;

      get)
        [ "$#" -eq 1 ] || usage
        split_ref "$1"
        file="$RUNTIME/$svc/$key"
        if [ ! -f "$file" ]; then
          echo "denver-state: $1 not published (no $file)" >&2
          exit 1
        fi
        cat "$file"
        ;;

      wait)
        [ "$#" -ge 1 ] || usage
        ref="$1"; shift
        timeout=30
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --timeout=*) timeout="''${1#--timeout=}"; shift ;;
            --timeout)
              [ "$#" -ge 2 ] || { echo "denver-state wait: --timeout needs a value" >&2; exit 2; }
              timeout="$2"; shift 2 ;;
            *) echo "denver-state wait: unknown arg $1" >&2; exit 2 ;;
          esac
        done
        split_ref "$ref"
        file="$RUNTIME/$svc/$key"
        started=$(date +%s)
        deadline=$(( started + timeout ))
        # Only chatter if stderr is a tty — keeps process-compose logs and
        # other non-interactive consumers clean.
        report=false
        [ -t 2 ] && report=true
        next_report=$(( started + 1 ))
        first=true
        while [ ! -f "$file" ]; do
          now=$(date +%s)
          if [ "$now" -ge "$deadline" ]; then
            echo "denver-state: timeout waiting $timeout s for $ref ($file)" >&2
            exit 1
          fi
          if "$report" && [ "$now" -ge "$next_report" ]; then
            elapsed=$(( now - started ))
            if "$first"; then
              echo "denver-state: waiting for $ref ..." >&2
              first=false
            else
              echo "denver-state: still waiting for $ref (''${elapsed}s elapsed) ..." >&2
            fi
            next_report=$(( now + 5 ))
          fi
          sleep 0.1
        done
        if "$report" && ! "$first"; then
          elapsed=$(( $(date +%s) - started ))
          echo "denver-state: $ref ready (''${elapsed}s)" >&2
        fi
        cat "$file"
        ;;

      pick-port)
        # Bind to port 0, ask the kernel which port it gave us, release.
        # Race window between close and a consumer binding is small enough for
        # dev use; if it ever matters we can add SO_REUSEADDR / retry logic.
        python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()'
        ;;

      dump)
        if [ ! -d "$RUNTIME" ]; then
          echo "(no runtime state yet — $RUNTIME does not exist)" >&2
          exit 0
        fi
        cd "$RUNTIME"
        for svc in */; do
          svc="''${svc%/}"
          for key in "$svc"/*; do
            [ -f "$key" ] || continue
            printf '%s.%s = %s\n' "$svc" "$(basename "$key")" "$(cat "$key")"
          done
        done
        ;;

      *)
        echo "denver-state: unknown subcommand '$cmd'" >&2
        usage
        ;;
    esac
  '';
}
