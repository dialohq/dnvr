{
  pkgs,
  lib,
}: {
  name,
  processes,
  env ? {},
  prerun ? "",
  cli,
}: let
  runnerLib = import ./lib.nix {inherit lib;};
  processNames = lib.attrNames processes;

  tmuxConfig = pkgs.writeText "dnvr-tmux.conf" ''
    set-option -g status off
    set-option -g remain-on-exit on
    set-option -g mouse on
    # Agent-facing `dnvr logs` reads the complete retained pane history.
    set-option -g history-limit 100000
    set-option -g pane-border-status top
    set-option -g pane-border-indicators off
    set-option -g pane-border-format \
      '#{?pane_active,#[fg=cyan],#[fg=colour244]}#{?#{==:#{@dnvr_role},sidebar},Processes,#{@dnvr_name} #{?pane_dead,#{?#{==:#{pane_dead_status},0},Completed,DOWN},UP}}#[default] '
    set-option -g pane-border-style fg=colour238
    set-option -g pane-active-border-style fg=colour238
    set-window-option -g window-size latest
    set-window-option -g main-pane-width 30
    set-option -g default-shell ${pkgs.bash}/bin/bash
    set-option -s escape-time 0
    set-option -g prefix None
    set-option -g prefix2 None

    bind-key -n C-g detach-client
    bind-key -n C-a select-pane -t '#{@dnvr_sidebar}' \; \
      run-shell '${pkgs.coreutils}/bin/kill -USR1 #{@dnvr_sidebar_pid}'

    set-hook -g pane-died \
      'run-shell "${pkgs.coreutils}/bin/kill -USR1 #{@dnvr_sidebar_pid}"'
    set-hook -g client-attached \
      'select-layout -t "=dnvr:dashboard" main-vertical ; run-shell "${pkgs.coreutils}/bin/kill -USR1 #{@dnvr_sidebar_pid}"'
    set-hook -g client-resized \
      'select-layout -t "=dnvr:dashboard" main-vertical'
  '';

  manifest = pkgs.writeText "dnvr-tmux-manifest.json" (builtins.toJSON {
    inherit name prerun cli;
    env = lib.mapAttrs (_: value: toString value) env;
    tmux = "${pkgs.tmux}/bin/tmux";
    shell = "${pkgs.bash}/bin/bash";
    tmux_config = toString tmuxConfig;
    rotatelogs = "${pkgs.apacheHttpd}/bin/rotatelogs";
    ansifilter = "${pkgs.ansifilter}/bin/ansifilter";
    processes = lib.imap0 (index: procName: {
      inherit index;
      name = procName;
      log_name = lib.replaceStrings ["/"] ["_"] procName;
      command = runnerLib.resolveCommand procName processes.${procName};
    }) processNames;
  });

  controller = pkgs.rustPlatform.buildRustPackage {
    pname = "dnvr-tmux";
    version = "0.1.0";
    src = ./tmux-sidebar;
    cargoLock.lockFile = ./tmux-sidebar/Cargo.lock;
    DNVR_MANIFEST_PATH = manifest;
    postInstall = ''
      ln -s dnvr-tmux-sidebar "$out/bin/${name}"
      ln -s dnvr-tmux-sidebar "$out/bin/dnvr"
    '';
    meta.mainProgram = name;
  };
in
  controller
