{
  name,
  config,
  lib,
  pkgs,
  dnvrState,
  ...
}: let
  inherit (lib) mkOption types;
  presetLib = import ./lib.nix {inherit lib;};

  upperName = presetLib.envPrefix name;

  hostAddr = presetLib.connectableHost config.listenHost;

  # Deterministic per-process defaults: stable across runs and machines, and
  # distinct between two instances of the preset.
  digest = salt: builtins.hashString "sha256" "dnvr-garage-${salt}-${name}";

  configPath = "$DNVR_ROOT/${config.dataDir}/garage.toml";

  # Replaces ~/.aws/config for `<name>-aws`: hostnames like localhost would
  # otherwise get virtual-hosted bucket URLs, which Garage doesn't serve here.
  awsConfig = pkgs.writeText "${name}-aws-config" ''
    [default]
    s3 =
      addressing_style = path
  '';

  # Signed HEAD of the bucket: answers only once the key and bucket exist.
  bucketProbe = ''curl -sf -o /dev/null -I --aws-sigv4 "aws:amz:${config.region}:s3" --user ${lib.escapeShellArg "${config.accessKey}:${config.secretKey}"} "http://${hostAddr}:''$${config.portEnv}/${config.bucket}"'';
in {
  options = {
    bucket = mkOption {
      type = types.strMatching "[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]";
      description = ''
        Bucket created at startup and readable/writable with `accessKey`.
        Required. Published as `bucket` only once it accepts requests, so
        `dnvr://<name>/bucket` doubles as a readiness signal.
      '';
    };
    package = mkOption {
      type = types.package;
      default = pkgs.garage_2;
      description = "Garage 2.x or later (`server --single-node --default-bucket`).";
    };
    listenHost = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address the S3 API binds to.";
    };
    port = mkOption {
      type = types.nullOr types.port;
      default = 3900;
      description = ''
        Static S3 API port. Set to null to pick a free port at startup
        (or export the env var named in `portEnv` from the shell's `prerun`).
      '';
    };
    portEnv = mkOption {
      type = types.str;
      default = "GARAGE_${upperName}_PORT";
      description = "Name of the env var holding the S3 API port.";
    };
    region = mkOption {
      type = types.str;
      default = "garage";
      description = "S3 region; clients must sign requests with it.";
    };
    accessKey = mkOption {
      type = types.str;
      default = "GK${builtins.substring 0 24 (digest "key")}";
      description = "Access key ID (at least 8 characters). Dev-only: it lands in the Nix store.";
    };
    secretKey = mkOption {
      type = types.str;
      default = digest "secret";
      description = "Secret access key (at least 16 characters). Dev-only: it lands in the Nix store.";
    };
    dataDir = mkOption {
      type = types.str;
      default = ".dnvr/${name}";
      description = "Relative to DNVR_ROOT. Holds metadata, data, and the generated garage.toml.";
    };
    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Raw TOML appended to the generated garage.toml.";
    };

    # Computed, read-only. Static strings usable anywhere in config — no
    # readiness implied, no waiting.
    endpoint = mkOption {
      type = types.str;
      readOnly = true;
      description = "S3 endpoint URL. Reading it with a dynamic port (port = null) is an eval error; use `dnvr://<name>/endpoint` then.";
    };
    dataPath = mkOption {
      type = types.str;
      readOnly = true;
      description = "Absolute data directory (`$DNVR_ROOT/<dataDir>`).";
    };
  };

  config = {
    endpoint =
      if config.port != null
      then "http://${hostAddr}:${toString config.port}"
      else throw "dnvr garage '${name}': `endpoint` needs a static port but it is null (dynamic) — use `dnvr://<name>/endpoint` at runtime";
    dataPath = "$DNVR_ROOT/${config.dataDir}";

    packages = [config.package];

    env = lib.optionalAttrs (config.port != null) {
      "${config.portEnv}" = toString config.port;
    };

    # The garage CLI talks to the node over RPC, so it needs the node's config.
    scripts."${name}-garage" = {
      description = "garage CLI for the ${name} node (buckets, keys, status)";
      runtimeInputs = [config.package];
      text = ''exec garage -c "${configPath}" "$@"'';
    };

    # The endpoint is read live, so dynamic ports work and a stopped node
    # fails loudly instead of the CLI hanging on a dead port.
    scripts."${name}-aws" = {
      description = "AWS CLI connected to the ${name} node (e.g. `${name}-aws s3 ls s3://${config.bucket}`)";
      runtimeInputs = [pkgs.awscli2 dnvrState];
      text = ''
        endpoint=$(dnvr-state get ${name}.endpoint) || {
          echo "${name}-aws: ${name} is not running (start it with 'dnvr up')" >&2
          exit 1
        }
        unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_SESSION_TOKEN
        export AWS_ENDPOINT_URL="$endpoint" \
          AWS_ACCESS_KEY_ID=${lib.escapeShellArg config.accessKey} \
          AWS_SECRET_ACCESS_KEY=${lib.escapeShellArg config.secretKey} \
          AWS_REGION=${lib.escapeShellArg config.region} \
          AWS_CONFIG_FILE=${awsConfig} \
          AWS_SHARED_CREDENTIALS_FILE=/dev/null
        exec aws "$@"
      '';
    };

    command =
      if builtins.stringLength config.accessKey < 8
      then throw "dnvr garage '${name}': accessKey must be at least 8 characters"
      else if builtins.stringLength config.secretKey < 16
      then throw "dnvr garage '${name}': secretKey must be at least 16 characters"
      else
        pkgs.writeShellApplication {
          name = "${name}-garage-server";
          runtimeInputs = [config.package pkgs.coreutils pkgs.curl dnvrState];
          text = ''
            : "''${DNVR_ROOT:?DNVR_ROOT must be set}"

            if [ -z "''${${config.portEnv}:-}" ]; then
              ${config.portEnv}=$(dnvr-state pick-port)
              export ${config.portEnv}
            fi
            # RPC is node-internal; a fresh port per run avoids clashes
            # between instances.
            rpc_port=$(dnvr-state pick-port)

            dir="$DNVR_ROOT/${config.dataDir}"
            mkdir -p "$dir/meta" "$dir/data"
            {
              printf 'metadata_dir = "%s/meta"\n' "$dir"
              printf 'data_dir = "%s/data"\n' "$dir"
              printf 'db_engine = "sqlite"\n'
              printf 'replication_factor = 1\n'
              printf 'rpc_bind_addr = "127.0.0.1:%s"\n' "$rpc_port"
              printf 'rpc_public_addr = "127.0.0.1:%s"\n' "$rpc_port"
              printf 'rpc_secret = "${digest "rpc"}"\n\n'
              printf '[s3_api]\n'
              printf 's3_region = %s\n' ${lib.escapeShellArg (builtins.toJSON config.region)}
              printf 'api_bind_addr = "${config.listenHost}:%s"\n' "''$${config.portEnv}"
              ${lib.optionalString (config.extraConfig != "") "printf '%s\\n' ${lib.escapeShellArg config.extraConfig}"}
            } > "$dir/garage.toml"

            # Discovery keys, published before the server is ready; `bucket`
            # (the readiness key) follows once it accepts requests.
            dnvr-state set port "''$${config.portEnv}"
            dnvr-state set host "${hostAddr}"
            dnvr-state set endpoint "http://${hostAddr}:''$${config.portEnv}"
            dnvr-state set region ${lib.escapeShellArg config.region}
            dnvr-state set accessKey ${lib.escapeShellArg config.accessKey}
            dnvr-state set secretKey ${lib.escapeShellArg config.secretKey}

            GARAGE_DEFAULT_ACCESS_KEY=${lib.escapeShellArg config.accessKey} \
            GARAGE_DEFAULT_SECRET_KEY=${lib.escapeShellArg config.secretKey} \
            GARAGE_DEFAULT_BUCKET=${lib.escapeShellArg config.bucket} \
              garage -c "$dir/garage.toml" server --single-node --default-bucket &
            GARAGE_PID=$!
            trap '
              kill -TERM $GARAGE_PID 2>/dev/null || true
              wait $GARAGE_PID 2>/dev/null || true
            ' EXIT INT TERM

          ${presetLib.untilReady {
            pid = "$GARAGE_PID";
            check = bucketProbe;
            onDead = "[${name}] garage exited before becoming ready";
            interval = "0.2";
          }}
            dnvr-state set bucket ${lib.escapeShellArg config.bucket}
            echo "[${name}] ready — bucket ${config.bucket} at http://${hostAddr}:''$${config.portEnv} (region ${config.region})"

            wait $GARAGE_PID
          '';
        };
  };
}
