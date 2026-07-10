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
    extraDatabases = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Additional databases created alongside `database`.";
    };
    initialScript = mkOption {
      type = types.nullOr types.lines;
      default = null;
      description = ''
        SQL run against `database` right after it is first created —
        not on subsequent launches.
      '';
    };
    port = mkOption {
      type = types.port;
      default = 5432;
    };
    listenAddresses = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        postgres `listen_addresses`. Empty string disables TCP entirely
        (socket-only); `host` and `url` are then not published.
      '';
    };
    package = mkOption {
      type = types.package;
      default = pkgs.postgresql;
    };
    extensions = mkOption {
      type = types.nullOr (types.functionTo (types.listOf types.package));
      default = null;
      example = lib.literalExpression "ps: [ps.postgis ps.plpgsql_check]";
      description = "Extensions to bake in via `package.withPackages`.";
    };
    initdbArgs = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Extra initdb arguments (besides -D and --username).";
    };
    authentication = mkOption {
      type = types.lines;
      default = "";
      description = "Lines appended to pg_hba.conf right after initdb.";
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
    settings = mkOption {
      type = types.attrsOf (types.oneOf [types.str types.int types.bool]);
      default = {};
      description = "Extra `-c key=value` postgres settings.";
    };

    # Computed, read-only. Static strings usable anywhere in config — no
    # readiness implied, no waiting. Paths are `$DNVR_ROOT`-relative shell
    # strings, expanded at export time (see env-export.nix).
    socketPath = mkOption {
      type = types.str;
      readOnly = true;
      description = "Absolute socket directory (`$DNVR_ROOT/<socketDir>`), e.g. for PGHOST.";
    };
    dataPath = mkOption {
      type = types.str;
      readOnly = true;
      description = "Absolute data directory (`$DNVR_ROOT/<dataDir>`).";
    };
    url = mkOption {
      type = types.str;
      readOnly = true;
      description = "TCP connection URL. Reading it with TCP disabled (listenAddresses = \"\") is an eval error; use `socketUrl` then.";
    };
    socketUrl = mkOption {
      type = types.str;
      readOnly = true;
      description = "Unix-socket connection URL (`$DNVR_ROOT`-relative).";
    };
  };

  config = let
    # Process name may contain dashes (e.g. "pg-test"); bash env var names can't.
    upper = lib.toUpper (lib.replaceStrings ["-"] ["_"] name);
    postgresPkg =
      if config.extensions == null
      then config.package
      else config.package.withPackages config.extensions;
    extraArgs =
      lib.concatStringsSep " "
      (lib.mapAttrsToList (k: v: "-c ${k}=${toString v}") config.settings);
    tcpEnabled = config.listenAddresses != "";
    # A connectable address for `host`/`url`: wildcard binds normalize to
    # loopback, otherwise the first listed address.
    hostAddr = let
      first = lib.head (lib.splitString "," config.listenAddresses);
    in
      if lib.elem first ["*" "0.0.0.0" "::"]
      then "127.0.0.1"
      else first;
    allDatabases = [config.database] ++ config.extraDatabases;
    initialScriptFile =
      if config.initialScript == null
      then null
      else pkgs.writeText "${name}-initial.sql" config.initialScript;
  in {
    socketPath = "$DNVR_ROOT/${config.socketDir}";
    dataPath = "$DNVR_ROOT/${config.dataDir}";
    url =
      if tcpEnabled
      then "postgresql://${config.superuser}@${hostAddr}:${toString config.port}/${config.database}"
      else throw "dnvr postgres '${name}': `url` needs TCP but listenAddresses is empty — use `socketUrl`";
    socketUrl = "postgresql://${config.superuser}@/${config.database}?host=$DNVR_ROOT/${config.socketDir}";

    packages = [postgresPkg];

    env = {
      "PG_${upper}_PORT" = toString config.port;
      "PG_${upper}_SOCKET_DIR" = config.socketPath;
      "PG_${upper}_DATABASE" = config.database;
      "PG_${upper}_LOG_JSON" = "$DNVR_ROOT/${config.logDir}/${name}.json";
    };

    command = pkgs.writeShellApplication {
      name = "${name}-pg";
      runtimeInputs = [postgresPkg pkgs.coreutils pkgs.fblog dnvrState];
      text = ''
        set -e
        : "''${DNVR_ROOT:?DNVR_ROOT must be set}"
        mkdir -p "$DNVR_ROOT/${config.socketDir}" "$DNVR_ROOT/${config.logDir}"
        if [ ! -d "$DNVR_ROOT/${config.dataDir}" ]; then
          echo "[${name}] initdb $DNVR_ROOT/${config.dataDir} ..."
          initdb -D "$DNVR_ROOT/${config.dataDir}" --username=${config.superuser} ${lib.escapeShellArgs config.initdbArgs}
          ${lib.optionalString (config.authentication != "") ''
          printf '%s\n' ${lib.escapeShellArg config.authentication} >> "$DNVR_ROOT/${config.dataDir}/pg_hba.conf"
        ''}
        fi

        # Discovery keys, published before postgres is ready; the readiness
        # keys (database/url/socketUrl) follow once the server accepts
        # connections.
        dnvr-state set port "${toString config.port}"
        dnvr-state set socketDir "$DNVR_ROOT/${config.socketDir}"
        dnvr-state set dataDir "$DNVR_ROOT/${config.dataDir}"
        dnvr-state set user "${config.superuser}"
        dnvr-state set bootstrapDatabase postgres
        ${lib.optionalString tcpEnabled ''
          dnvr-state set host "${hostAddr}"
        ''}

        # Native postgres jsonlog → .dnvr/logs/<name>.json (what agents
        # tail). We also tail it through fblog to render a pretty stream on
        # stdout for the human-facing mprocs pane. Postgres dies with the
        # wrapper via the trap.
        LOG_JSON="$DNVR_ROOT/${config.logDir}/${name}.json"
        echo "[${name}] starting postgres on port ${toString config.port} ..."
        postgres -D "$DNVR_ROOT/${config.dataDir}" \
          -c listen_addresses=${lib.escapeShellArg config.listenAddresses} \
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

        # Wait for readiness, ensure the configured databases exist, then
        # publish the readiness keys — `dnvr://<name>/database` (or
        # url/socketUrl) refs unblock only here.
        PGARGS=(-h "$DNVR_ROOT/${config.socketDir}" -p ${toString config.port} -U ${config.superuser})
        until pg_isready -q "''${PGARGS[@]}"; do
          if ! kill -0 $PG_PID 2>/dev/null; then
            echo "[${name}] postgres exited before becoming ready" >&2
            exit 1
          fi
          sleep 0.1
        done
        ${lib.concatMapStrings (db: ''
          if [ -z "$(psql "''${PGARGS[@]}" -d postgres -tAc \
              "SELECT 1 FROM pg_database WHERE datname = '${db}'")" ]; then
            echo "[${name}] creating database ${db} ..."
            createdb "''${PGARGS[@]}" ${lib.escapeShellArg db}
            ${lib.optionalString (db == config.database && initialScriptFile != null) ''
            echo "[${name}] running initialScript against ${db} ..."
            psql "''${PGARGS[@]}" -d ${lib.escapeShellArg db} -v ON_ERROR_STOP=1 -f ${initialScriptFile}
          ''}
          fi
        '')
        allDatabases}
        ${lib.optionalString tcpEnabled ''
          dnvr-state set url "postgresql://${config.superuser}@${hostAddr}:${toString config.port}/${config.database}"
        ''}
        dnvr-state set socketUrl "postgresql://${config.superuser}@/${config.database}?host=$DNVR_ROOT/${config.socketDir}"
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
