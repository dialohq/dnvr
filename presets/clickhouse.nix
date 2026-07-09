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

  # Ports are resolved by clickhouse at startup via `from_env`. Default to
  # per-process env-var names; callers can override `httpPortEnv`/`tcpPortEnv`
  # to point at shared names like `CH_HTTP_PORT` for dynamic-port setups via
  # the env's `prerun`.
  configXml = pkgs.writeText "${name}-clickhouse.xml" ''
    <?xml version="1.0"?>
    <clickhouse>
      <listen_host>127.0.0.1</listen_host>
      <http_port from_env="${config.httpPortEnv}"/>
      <tcp_port from_env="${config.tcpPortEnv}"/>
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
    </clickhouse>
  '';
in {
  options = {
    package = mkOption {
      type = types.package;
      default = pkgs.clickhouse;
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
  };

  config = {
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

        # Publish discovery info so consumers (the tests pane, anything else
        # that needs CLICKHOUSE_HOST) can `dnvr-state wait` for us.
        dnvr-state set httpPort "''$${config.httpPortEnv}"
        dnvr-state set tcpPort  "''$${config.tcpPortEnv}"
        dnvr-state set host     "http://127.0.0.1:''$${config.httpPortEnv}"

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
        exec clickhouse-server --config-file=${configXml}
      '';
    };
  };
}
