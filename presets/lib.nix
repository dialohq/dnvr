{lib}: {
  # "pg-test" -> "PG_TEST": process names may contain dashes, env var
  # names can't.
  envPrefix = name: lib.toUpper (lib.replaceStrings ["-"] ["_"] name);

  # A connectable address for published host/url values: wildcard binds
  # normalize to loopback, otherwise the first listed address.
  connectableHost = listen: let
    first = lib.head (lib.splitString "," listen);
  in
    if lib.elem first ["*" "0.0.0.0" "::"]
    then "127.0.0.1"
    else first;

  # Poll `check` until it succeeds, bailing out if the daemon ($pid) dies
  # first.
  untilReady = {
    pid,
    check,
    onDead,
    interval ? "0.1",
  }: ''
    until ${check}; do
      if ! kill -0 ${pid} 2>/dev/null; then
        echo ${lib.escapeShellArg onDead} >&2
        exit 1
      fi
      sleep ${interval}
    done
  '';
}
