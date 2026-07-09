{
  name,
  config,
  lib,
  pkgs,
  dnvrState,
  ...
}: let
  inherit (lib) mkOption types;
in {
  options = {
    database = mkOption {
      type = types.str;
      description = ''
        Database to create (if missing) once the server is up. Required.
        Published as `database` only after it exists and the server accepts
        connections, so `dnvr://<name>/database` doubles as a readiness
        signal for consumers.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 5432;
    };
    package = mkOption {
      type = types.package;
      default = pkgs.postgresql;
    };
    dataDir = mkOption {
      type = types.str;
      default = ".dnvr/${name}";
    };
    socketDir = mkOption {
      type = types.str;
      default = ".dnvr/${name}-sockets";
    };
    logDir = mkOption {
      type = types.str;
      default = ".dnvr/logs";
    };
    superuser = mkOption {
      type = types.str;
      default = "postgres";
    };
    extraSettings = mkOption {
      type = types.attrsOf (types.oneOf [types.str types.int types.bool]);
      default = {};
      description = "Extra `-c key=value` postgres settings.";
    };
  };

  config = let
    # Process name may contain dashes (e.g. "pg-test"); bash env var names can't.
    upper = lib.toUpper (lib.replaceStrings ["-"] ["_"] name);
    extraArgs =
      lib.concatStringsSep " "
      (lib.mapAttrsToList (k: v: "-c ${k}=${toString v}") config.extraSettings);
  in {
    packages = [config.package];

    env = {
      "PG_${upper}_PORT" = toString config.port;
      "PG_${upper}_SOCKET_DIR" = config.socketDir;
      "PG_${upper}_DATABASE" = config.database;
      "PG_${upper}_LOG_JSON" = "${config.logDir}/${name}.json";
    };

    command = pkgs.writeShellApplication {
      name = "${name}-pg";
      runtimeInputs = [config.package pkgs.coreutils pkgs.fblog dnvrState];
      text = ''
        set -e
        : "''${DNVR_ROOT:?DNVR_ROOT must be set}"
        mkdir -p "$DNVR_ROOT/${config.socketDir}" "$DNVR_ROOT/${config.logDir}"
        if [ ! -d "$DNVR_ROOT/${config.dataDir}" ]; then
          echo "[${name}] initdb $DNVR_ROOT/${config.dataDir} ..."
          initdb -D "$DNVR_ROOT/${config.dataDir}" --username=${config.superuser}
        fi

        # Publish discovery info for other processes (atlas-watch, tests, …)
        # via dnvr-state. Published before postgres is *ready* — consumers
        # that only need "where is it?" read these; `database` is published
        # separately below, only once the server accepts connections.
        dnvr-state set port "${toString config.port}"
        dnvr-state set socketDir "$DNVR_ROOT/${config.socketDir}"
        dnvr-state set dataDir "$DNVR_ROOT/${config.dataDir}"
        dnvr-state set user "${config.superuser}"
        dnvr-state set bootstrapDatabase postgres

        # Native postgres jsonlog → .dnvr/logs/<name>.json (what agents
        # tail). We also tail it through fblog to render a pretty stream on
        # stdout for the human-facing mprocs pane. Postgres dies with the
        # wrapper via the trap.
        LOG_JSON="$DNVR_ROOT/${config.logDir}/${name}.json"
        echo "[${name}] starting postgres on port ${toString config.port} ..."
        postgres -D "$DNVR_ROOT/${config.dataDir}" \
          -c listen_addresses=127.0.0.1 \
          -c port=${toString config.port} \
          -c unix_socket_directories="$DNVR_ROOT/${config.socketDir}" \
          -c logging_collector=on \
          -c log_destination=jsonlog \
          -c log_directory="$DNVR_ROOT/${config.logDir}" \
          -c log_filename=${lib.escapeShellArg "${name}.log"} \
          -c log_rotation_size=0 \
          -c log_rotation_age=0 \
          -c log_truncate_on_rotation=off ${extraArgs} &
        PG_PID=$!
        # SIGINT → postgres "fast shutdown" (disconnect active sessions and
        # exit). SIGTERM is "smart shutdown" — postmaster waits for active
        # sessions to drain, which never happens with atlas-watch/tests
        # holding connections, so the wrapper would hang.
        trap '
          kill -INT $PG_PID 2>/dev/null || true
          wait $PG_PID 2>/dev/null || true
        ' EXIT INT TERM

        # Wait for the jsonlog to materialise (postgres usually creates it
        # within ~1s once logging_collector spins up).
        for _ in $(seq 1 100); do
          [ -f "$LOG_JSON" ] && break
          if ! kill -0 $PG_PID 2>/dev/null; then
            echo "[${name}] postgres exited before log appeared" >&2
            exit 1
          fi
          sleep 0.1
        done
        if [ ! -f "$LOG_JSON" ]; then
          echo "[${name}] timed out waiting for $LOG_JSON" >&2
          exit 1
        fi

        # Wait until the server accepts connections, ensure the configured
        # database exists, then publish it. Consumers holding
        # `dnvr://<name>/database` refs unblock here — after the DB is
        # actually usable, not merely after the postmaster forked.
        PGARGS=(-h "$DNVR_ROOT/${config.socketDir}" -p ${toString config.port} -U ${config.superuser})
        until pg_isready -q "''${PGARGS[@]}"; do
          if ! kill -0 $PG_PID 2>/dev/null; then
            echo "[${name}] postgres exited before becoming ready" >&2
            exit 1
          fi
          sleep 0.1
        done
        if [ -z "$(psql "''${PGARGS[@]}" -d postgres -tAc \
            "SELECT 1 FROM pg_database WHERE datname = '${config.database}'")" ]; then
          echo "[${name}] creating database ${config.database} ..."
          createdb "''${PGARGS[@]}" ${lib.escapeShellArg config.database}
        fi
        dnvr-state set database ${lib.escapeShellArg config.database}

        # fblog renders structured logs. Postgres jsonlog uses `timestamp`
        # (in fblog's defaults) and `message` (also default), but `level` →
        # `error_severity`. `stdbuf -oL` line-buffers tail so output is
        # immediate, not held in a 4 KB pipe block. `--pid` makes tail exit
        # when postgres dies, cascading EOF to fblog.
        #
        # Run the pipeline in background and `wait` on it: bash defers
        # signal traps while a *foreground* command runs, so a foreground
        # `tail | fblog` would queue SIGTERM forever (tail -F never returns)
        # and the trap'd kill of postgres would never fire. `wait` returns
        # immediately when a trapped signal arrives, letting the trap kill
        # postgres → tail --pid exits → fblog EOFs → wait completes.
        stdbuf -oL tail --pid=$PG_PID -F -n +0 "$LOG_JSON" | fblog -l error_severity &
        PIPE_PID=$!
        wait $PIPE_PID
      '';
    };
  };
}
