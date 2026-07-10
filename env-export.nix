{lib}: {
  # Render an `export K=V` line where the literal substring `$DNVR_ROOT` in V
  # is left for the executing shell to expand; everything else — including
  # any other `$` — is escaped verbatim. This is what lets eval stay pure
  # while values carry location-dependent paths: the expansion happens
  # wherever the export runs (shellHook, runner, wrapper), where DNVR_ROOT
  # is live. Exactly `$DNVR_ROOT` is special; no other variable is expanded.
  exportLine = k: v: let
    parts = lib.splitString "$DNVR_ROOT" (toString v);
  in "export ${k}=" + lib.concatStringsSep "\"$DNVR_ROOT\"" (map lib.escapeShellArg parts);

  refersToRoot = v: lib.hasInfix "$DNVR_ROOT" (toString v);
}
