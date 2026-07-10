{
  name,
  config,
  lib,
  pkgs,
  dnvrState,
  ...
}: let
  inherit (lib) mkOption types;

  upperName = lib.toUpper (lib.replaceStrings ["-"] ["_"] name);

  # A connectable address for `host`/`httpUrl`: wildcard binds normalize to
  # loopback.
  hostAddr =
    if lib.elem config.listenHost ["*" "0.0.0.0" "::"]
    then "127.0.0.1"
    else config.listenHost;

  # Ports are resolved by clickhouse at startup via `from_env`. Default to
  # per-process env-var names; callers can override `httpPortEnv`/`tcpPortEnv`
  # to point at shared names like `CH_HTTP_PORT` for dynamic-port setups via
  # the env's `prerun`.
  configXml = pkgs.writeText "${name}-clickhouse.xml" ''
    <?xml version="1.0"?>
    <clickhouse>
      <listen_host>${config.listenHost}</listen_host>
      <http_port from_env="${config.httpPortEnv}"/>
      <tcp_port from_env="${config.tcpPortEnv}"/>
      ${lib.optionalString (config.postgresqlPort != null) "<postgresql_port>${toString config.postgresqlPort}</postgresql_port>"}
      <path>${config.dataDir}/</path>
      <tmp_path>${config.dataDir}/tmp/</tmp_path>
      <user_files_path>${config.dataDir}/user_files/</user_files_path>
      <format_schema_path>${config.dataDir}/format_schemas/</format_schema_path>
      <timezone>${config.timezone}</timezone>
      <logger>
        <level>${config.logLevel}</level>
        <log>${config.logDir}/${name}.log</log>
        <errorlog>${config.logDir}/${name}.err.log</errorlog>
        <console>true</console>
      </logger>
      <profiles>
        <default/>
      </profiles>
      <users>
        <default>
          <password></password>
          <profile>default</profile>
          <quota>default</quota>
          <networks><ip>::/0</ip></networks>
          <access_management>1</access_management>
        </default>
      </users>
      <quotas>
        <default>
          <interval>
            <duration>3600</duration>
            <queries>0</queries>
            <errors>0</errors>
            <result_rows>0</result_rows>
            <read_rows>0</read_rows>
            <execution_time>0</execution_time>
          </interval>
        </default>
      </quotas>
      ${config.extraConfigXml}
    </clickhouse>
  '';
in {
  options = {
    database = mkOption {
      type = types.str;
      description = ''
        Database to create (if missing) once the server answers queries.
        Required. Published as `database` only after it exists, so
        `dnvr://<name>/database` doubles as a readiness signal.
      '';
    };
    package = mkOption {
      type = types.package;
      default = pkgs.clickhouse;
    };
    listenHost = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "clickhouse `listen_host`.";
    };
    httpPort = mkOption {
      type = types.nullOr types.port;
      default = 8123;
      description = ''
        Static HTTP port. Set to null when callers want dynamic ports
        — the runner's `prerun` must then export the env var named in
        `httpPortEnv` before the runner exec.
      '';
    };
    tcpPort = mkOption {
      type = types.nullOr types.port;
      default = 9000;
    };
    postgresqlPort = mkOption {
      type = types.nullOr types.port;
      default = null;
      description = "Expose the postgres wire protocol on this port (clickhouse `postgresql_port`).";
    };
    httpPortEnv = mkOption {
      type = types.str;
      default = "CH_${upperName}_HTTP_PORT";
      description = "Name of the env var clickhouse reads via `from_env` for its HTTP port.";
    };
    tcpPortEnv = mkOption {
      type = types.str;
      default = "CH_${upperName}_TCP_PORT";
    };
    dataDir = mkOption {
      type = types.str;
      default = ".dnvr/${name}";
      description = "Relative to DNVR_ROOT.";
    };
    logDir = mkOption {
      type = types.str;
      default = ".dnvr/logs";
    };
    logLevel = mkOption {
      type = types.enum ["trace" "debug" "information" "warning" "error"];
      default = "information";
    };
    timezone = mkOption {
      type = types.str;
      default = "UTC";
    };
    extraConfigXml = mkOption {
      type = types.lines;
      default = "";
      description = "Raw XML injected into the server config, inside <clickhouse>.";
    };

    # Computed, read-only. Static strings usable anywhere in config — no
    # readiness implied, no waiting.
    httpUrl = mkOption {
      type = types.str;
      readOnly = true;
      description = "HTTP endpoint. Reading it with a dynamic port (httpPort = null) is an eval error; use `dnvr://<name>/httpUrl` then.";
    };
    dataPath = mkOption {
      type = types.str;
      readOnly = true;
      description = "Absolute data directory (`$DNVR_ROOT/<dataDir>`).";
    };
  };

  config = {
    httpUrl =
      if config.httpPort != null
      then "http://${hostAddr}:${toString config.httpPort}"
      else throw "dnvr clickhouse '${name}': `httpUrl` needs a static httpPort but it is null (dynamic) — use `dnvr://<name>/httpUrl` at runtime";
    dataPath = "$DNVR_ROOT/${config.dataDir}";

    packages = [config.package];

    # Set the port env vars statically when httpPort/tcpPort have values. The
    # env-level `prerun` can override these by `export`ing the same names —
    # process env wins over the env-level env map.
    env =
      (lib.optionalAttrs (config.httpPort != null) {
        "${config.httpPortEnv}" = toString config.httpPort;
      })
      // (lib.optionalAttrs (config.tcpPort != null) {
        "${config.tcpPortEnv}" = toString config.tcpPort;
      })
      // {
        "CH_${upperName}_DATABASE" = config.database;
        "CH_${upperName}_LOG" = "${config.logDir}/${name}.log";
      };

    command = pkgs.writeShellApplication {
      name = "${name}-ch";
      runtimeInputs = [config.package pkgs.coreutils dnvrState];
      text = ''
        set -e
        : "''${DNVR_ROOT:?DNVR_ROOT must be set}"

        # If a static port wasn't configured, pick one now. The clickhouse
        # XML reads ports via <… from_env="..."/>, so all we need is to
        # export the right env vars before the exec.
        if [ -z "''${${config.httpPortEnv}:-}" ]; then
          ${config.httpPortEnv}=$(dnvr-state pick-port)
          export ${config.httpPortEnv}
        fi
        if [ -z "''${${config.tcpPortEnv}:-}" ]; then
          ${config.tcpPortEnv}=$(dnvr-state pick-port)
          export ${config.tcpPortEnv}
        fi

        # Publish discovery info before the server is *ready* — consumers
        # that only need "where is it?" read these; `database` is published
        # separately below, once the server answers queries.
        dnvr-state set httpPort "''$${config.httpPortEnv}"
        dnvr-state set tcpPort  "''$${config.tcpPortEnv}"
        dnvr-state set host     "${hostAddr}"
        dnvr-state set httpUrl  "http://${hostAddr}:''$${config.httpPortEnv}"
        dnvr-state set user     default
        ${lib.optionalString (config.postgresqlPort != null) ''
          dnvr-state set postgresqlPort "${toString config.postgresqlPort}"
        ''}

        mkdir -p \
          "$DNVR_ROOT/${config.dataDir}" \
          "$DNVR_ROOT/${config.dataDir}/tmp" \
          "$DNVR_ROOT/${config.dataDir}/user_files" \
          "$DNVR_ROOT/${config.dataDir}/format_schemas" \
          "$DNVR_ROOT/${config.logDir}"
        # Paths in the XML are relative; cd to DNVR_ROOT so they resolve.
        cd "$DNVR_ROOT"
        # Native dual output: <log>file</log> + <console>true</console> writes
        # to both the log file (for agents) and stderr (for mprocs panes).
        clickhouse-server --config-file=${configXml} &
        CH_PID=$!
        trap '
          kill -TERM $CH_PID 2>/dev/null || true
          wait $CH_PID 2>/dev/null || true
        ' EXIT INT TERM

        # Wait until the server answers queries, ensure the configured
        # database exists, then publish it. Consumers holding
        # `dnvr://<name>/database` refs unblock here.
        until clickhouse-client --host "${hostAddr}" --port "''$${config.tcpPortEnv}" \
            --query "SELECT 1" >/dev/null 2>&1; do
          if ! kill -0 $CH_PID 2>/dev/null; then
            echo "[${name}] clickhouse exited before becoming ready" >&2
            exit 1
          fi
          sleep 0.2
        done
        clickhouse-client --host "${hostAddr}" --port "''$${config.tcpPortEnv}" \
          --query 'CREATE DATABASE IF NOT EXISTS "${config.database}"'
        dnvr-state set database ${lib.escapeShellArg config.database}
        echo "[${name}] ready — database ${config.database} on tcp ''$${config.tcpPortEnv} / http ''$${config.httpPortEnv}"

        wait $CH_PID
      '';
    };
  };
}
