{lib}: {
  # A process as handed over by shell-module: {command, runner_settings}
  # where command is a store script (derivation) or a shell string.
  resolveCommand = procName: p:
    if lib.isDerivation p.command
    then "${p.command}/bin/${p.command.meta.mainProgram or p.command.pname or procName}"
    else p.command;

}
