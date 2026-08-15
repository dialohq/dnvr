use std::{
    env, fs,
    fs::{File, OpenOptions},
    io::Write,
    os::unix::process::CommandExt,
    path::{Path, PathBuf},
    process::{Command, ExitStatus, Output, Stdio},
    thread,
    time::Duration,
};

use rustix::{
    fs::{FlockOperation, flock},
    io::{FdFlags, fcntl_getfd, fcntl_setfd},
    process::{Pid, Signal, kill_process},
};

use crate::{Result, manifest};

const SESSION: &str = "dnvr";
const DASHBOARD: &str = "dashboard";

fn state_dir() -> Result<PathBuf> {
    Ok(PathBuf::from(
        env::var_os("DNVR_STATE").ok_or("DNVR_STATE must be set (run via nix develop)")?,
    ))
}

fn socket(state: &Path) -> PathBuf {
    state
        .join("runtime")
        .join(format!("tmux-{}.sock", manifest::get().name))
}

fn log_dir(state: &Path) -> PathBuf {
    state
        .join("logs")
        .join(format!("tmux-{}", manifest::get().name))
}

fn tmux_command(socket: &Path) -> Command {
    let mut command = Command::new(&manifest::get().tmux);
    command.arg("-S").arg(socket);
    command
}

fn tmux_output(socket: &Path, args: &[&str]) -> Result<Output> {
    let output = tmux_command(socket).args(args).output()?;
    if output.status.success() {
        Ok(output)
    } else {
        Err(format!(
            "tmux {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        )
        .into())
    }
}

fn tmux_text(socket: &Path, args: &[&str]) -> Result<String> {
    Ok(String::from_utf8(tmux_output(socket, args)?.stdout)?
        .trim_end_matches(['\r', '\n'])
        .to_owned())
}

fn tmux_status(socket: &Path, args: &[&str]) -> Result<ExitStatus> {
    Ok(tmux_command(socket)
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?)
}

fn shell_quote(value: &str) -> String {
    if value.is_empty() {
        return "''".to_owned();
    }
    format!("'{}'", value.replace('\'', "'\\''"))
}

fn shell_command(args: &[&str]) -> String {
    args.iter()
        .map(|value| shell_quote(value))
        .collect::<Vec<_>>()
        .join(" ")
}

fn own_command(args: &[&str]) -> Result<String> {
    let executable = env::current_exe()?;
    let executable = executable.to_string_lossy();
    let mut command = Vec::with_capacity(args.len() + 1);
    command.push(executable.as_ref());
    command.extend_from_slice(args);
    Ok(shell_command(&command))
}

fn expand_root(value: &str) -> Result<String> {
    const TOKEN: &str = "$DNVR_ROOT";
    let Some(root) = env::var_os("DNVR_ROOT") else {
        if value.match_indices(TOKEN).any(|(index, _)| {
            value[index + TOKEN.len()..]
                .chars()
                .next()
                .is_none_or(|next| !next.is_ascii_alphanumeric() && next != '_')
        }) {
            return Err("DNVR_ROOT must be set (run via nix develop)".into());
        }
        return Ok(value.to_owned());
    };
    let root = root.to_string_lossy();
    let mut expanded = String::with_capacity(value.len());
    let mut remaining = value;
    while let Some(index) = remaining.find(TOKEN) {
        expanded.push_str(&remaining[..index]);
        let suffix = &remaining[index + TOKEN.len()..];
        if suffix
            .chars()
            .next()
            .is_some_and(|next| next.is_ascii_alphanumeric() || next == '_')
        {
            expanded.push_str(TOKEN);
        } else {
            expanded.push_str(&root);
        }
        remaining = suffix;
    }
    expanded.push_str(remaining);
    Ok(expanded)
}

fn apply_environment() -> Result<()> {
    for (key, value) in &manifest::get().env {
        let value = expand_root(value)?;
        // The controller is single-threaded and mutates its environment before
        // starting tmux or the sidebar, so no concurrent environment access exists.
        unsafe { env::set_var(key, value) };
    }
    Ok(())
}

fn run_prerun() -> Result<()> {
    let manifest = manifest::get();
    if manifest.prerun.trim().is_empty() {
        return Ok(());
    }
    let status = Command::new(&manifest.shell)
        .arg("-c")
        .arg(&manifest.prerun)
        .status()?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("prerun failed with {status}").into())
    }
}

fn locked_error(process: &manifest::Process, message: &str) -> Box<dyn std::error::Error> {
    format!("[{}] {message}", process.name).into()
}

fn try_lock(file: &File, operation: FlockOperation) -> Result<bool> {
    match flock(file, operation) {
        Ok(()) => Ok(true),
        Err(error) if error == rustix::io::Errno::WOULDBLOCK => Ok(false),
        Err(error) => Err(error.into()),
    }
}

fn open_lock(path: &Path) -> Result<File> {
    Ok(OpenOptions::new()
        .read(true)
        .append(true)
        .create(true)
        .open(path)?)
}

fn claim_process(state: &Path, process: &manifest::Process) -> Result<File> {
    let runtime = state.join("runtime").join(&process.name);
    fs::create_dir_all(&runtime)?;

    let launch = open_lock(&runtime.join("launch.lock"))?;
    if !try_lock(&launch, FlockOperation::NonBlockingLockExclusive)? {
        return Err(locked_error(process, "another launch is in progress"));
    }

    let probe = open_lock(&runtime.join("pid"))?;
    if !try_lock(&probe, FlockOperation::NonBlockingLockShared)? {
        return Err(locked_error(
            process,
            "pid file is locked — already running?",
        ));
    }
    flock(&probe, FlockOperation::Unlock)?;
    drop(probe);

    for entry in fs::read_dir(&runtime)? {
        let entry = entry?;
        if matches!(entry.file_name().to_str(), Some("pid" | "launch.lock")) {
            continue;
        }
        let file_type = entry.file_type()?;
        if file_type.is_dir() && !file_type.is_symlink() {
            fs::remove_dir_all(entry.path())?;
        } else {
            fs::remove_file(entry.path())?;
        }
    }

    let mut pid = open_lock(&runtime.join("pid"))?;
    if !try_lock(&pid, FlockOperation::NonBlockingLockExclusive)? {
        return Err(locked_error(
            process,
            "pid file is locked — already running?",
        ));
    }
    pid.set_len(0)?;
    writeln!(pid, "{}", std::process::id())?;
    pid.flush()?;
    let mut flags = fcntl_getfd(&pid)?;
    flags.remove(FdFlags::CLOEXEC);
    fcntl_setfd(&pid, flags)?;
    drop(launch);
    Ok(pid)
}

fn prepend_own_path() -> Result<()> {
    let executable = env::current_exe()?;
    let bin = executable
        .parent()
        .ok_or("dnvr executable has no parent directory")?;
    let mut path = bin.as_os_str().to_owned();
    if let Some(existing) = env::var_os("PATH") {
        path.push(":");
        path.push(existing);
    }
    // This hidden process worker is single-threaded and mutates PATH before exec.
    unsafe { env::set_var("PATH", path) };
    Ok(())
}

fn sidebar_pane(socket: &Path) -> Result<String> {
    let panes = tmux_text(
        socket,
        &[
            "list-panes",
            "-s",
            "-t",
            "=dnvr",
            "-F",
            "#{@dnvr_role}\t#{pane_id}",
        ],
    )?;
    panes
        .lines()
        .find_map(|line| line.strip_prefix("sidebar\t").map(str::to_owned))
        .ok_or_else(|| "existing tmux session has no sidebar pane".into())
}

fn wait_for_sidebar(socket: &Path, pane: &str) -> Result<()> {
    for _ in 0..200 {
        if tmux_text(
            socket,
            &["display-message", "-p", "-t", pane, "#{@dnvr_ready}"],
        )? == "1"
        {
            return Ok(());
        }
        thread::sleep(Duration::from_millis(25));
    }
    Err("tmux sidebar did not become ready".into())
}

fn pane_contents(socket: &Path, pane: &str) -> String {
    tmux_text(socket, &["capture-pane", "-p", "-S", "-", "-t", pane]).unwrap_or_default()
}

fn configure_session(socket: &Path, sidebar: &str) -> Result<()> {
    let sidebar_pid = tmux_text(
        socket,
        &[
            "display-message",
            "-p",
            "-t",
            sidebar,
            "#{@dnvr_sidebar_pid}",
        ],
    )?;
    tmux_output(socket, &["set-option", "-g", "@dnvr_sidebar", sidebar])?;
    tmux_output(
        socket,
        &["set-option", "-g", "@dnvr_sidebar_pid", &sidebar_pid],
    )?;
    tmux_output(
        socket,
        &["source-file", manifest::get().tmux_config.as_str()],
    )?;
    Ok(())
}

fn refresh_sidebar(socket: &Path, sidebar: &str) -> Result<()> {
    let raw_pid = tmux_text(
        socket,
        &[
            "display-message",
            "-p",
            "-t",
            sidebar,
            "#{@dnvr_sidebar_pid}",
        ],
    )?
    .parse()?;
    let pid = Pid::from_raw(raw_pid).ok_or("sidebar published an invalid process id")?;
    kill_process(pid, Signal::Usr1)?;
    Ok(())
}

fn recorder_command(process: &manifest::Process) -> Result<String> {
    let manifest = manifest::get();
    own_command(&[
        "__record",
        &manifest.rotatelogs,
        &manifest.ansifilter,
        &manifest.name,
        &process.log_name,
    ])
}

fn configure_recorders(socket: &Path) -> Result<()> {
    let panes = tmux_text(
        socket,
        &[
            "list-panes",
            "-s",
            "-t",
            "=dnvr",
            "-F",
            "#{@dnvr_index}\t#{pane_id}\t#{pane_dead}",
        ],
    )?;
    for process in &manifest::get().processes {
        let wanted = process.index.to_string();
        let pane = panes.lines().find_map(|line| {
            let mut fields = line.splitn(3, '\t');
            match (fields.next(), fields.next(), fields.next()) {
                (Some(index), Some(pane), Some("0")) if index == wanted => Some(pane),
                _ => None,
            }
        });
        if let Some(pane) = pane {
            tmux_output(
                socket,
                &["pipe-pane", "-t", pane, &recorder_command(process)?],
            )?;
        }
    }
    Ok(())
}

fn upgrade_sidebar(socket: &Path, sidebar: &str) -> Result<()> {
    let expected = own_command(&["__sidebar"])?;
    let running = tmux_text(
        socket,
        &[
            "display-message",
            "-p",
            "-t",
            sidebar,
            "#{@dnvr_sidebar_command}",
        ],
    )?;
    if running == expected {
        return Ok(());
    }
    tmux_output(
        socket,
        &["set-option", "-p", "-t", sidebar, "@dnvr_ready", "0"],
    )?;
    tmux_output(socket, &["respawn-pane", "-k", "-t", sidebar, &expected])?;
    wait_for_sidebar(socket, sidebar)?;
    tmux_output(
        socket,
        &[
            "set-option",
            "-p",
            "-t",
            sidebar,
            "@dnvr_sidebar_command",
            &expected,
        ],
    )?;
    Ok(())
}

fn attach(socket: &Path) -> Result<()> {
    let error = tmux_command(socket)
        .args(["attach-session", "-t", "=dnvr"])
        .exec();
    Err(error.into())
}

fn reattach(socket: &Path) -> Result<()> {
    let sidebar = sidebar_pane(socket)?;
    upgrade_sidebar(socket, &sidebar)?;
    configure_session(socket, &sidebar)?;
    configure_recorders(socket)?;
    attach(socket)
}

fn create(socket: &Path, state: &Path) -> Result<()> {
    run_prerun()?;
    let logs = log_dir(state);
    fs::create_dir_all(&logs)?;

    let (mut columns, mut rows) = crossterm::terminal::size().unwrap_or((80, 24));
    if rows < 2 || columns < 32 {
        rows = 24;
        columns = 80;
    }
    let sidebar_command = own_command(&["__sidebar"])?;
    let manifest = manifest::get();
    tmux_output(
        socket,
        &[
            "-f",
            &manifest.tmux_config,
            "new-session",
            "-d",
            "-x",
            &columns.to_string(),
            "-y",
            &rows.to_string(),
            "-s",
            SESSION,
            "-n",
            DASHBOARD,
            &sidebar_command,
        ],
    )?;
    let sidebar = tmux_text(
        socket,
        &[
            "display-message",
            "-p",
            "-t",
            "=dnvr:dashboard.0",
            "#{pane_id}",
        ],
    )?;
    tmux_output(
        socket,
        &["set-option", "-p", "-t", &sidebar, "@dnvr_role", "sidebar"],
    )?;
    tmux_output(
        socket,
        &[
            "set-option",
            "-p",
            "-t",
            &sidebar,
            "@dnvr_name",
            "Processes",
        ],
    )?;
    tmux_output(
        socket,
        &[
            "set-option",
            "-p",
            "-t",
            &sidebar,
            "@dnvr_sidebar_command",
            &sidebar_command,
        ],
    )?;
    if let Err(error) = wait_for_sidebar(socket, &sidebar) {
        let output = pane_contents(socket, &sidebar);
        let _ = tmux_output(socket, &["kill-session", "-t", "=dnvr"]);
        return if output.trim().is_empty() {
            Err(error)
        } else {
            Err(format!("{error}:\n{output}").into())
        };
    }
    configure_session(socket, &sidebar)?;

    for process in &manifest.processes {
        let ready = logs.join(format!(".launch-{}", process.index));
        match fs::remove_file(&ready) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
        let process_command = own_command(&["__process", &process.index.to_string()])?;
        let pane = if process.index == 0 {
            tmux_text(
                socket,
                &[
                    "split-window",
                    "-h",
                    "-d",
                    "-P",
                    "-F",
                    "#{pane_id}",
                    "-t",
                    &sidebar,
                    &process_command,
                ],
            )?
        } else {
            tmux_text(
                socket,
                &[
                    "new-window",
                    "-d",
                    "-P",
                    "-F",
                    "#{pane_id}",
                    "-t",
                    "=dnvr:",
                    "-n",
                    &process.name,
                    &process_command,
                ],
            )?
        };
        tmux_output(
            socket,
            &["set-option", "-p", "-t", &pane, "@dnvr_role", "process"],
        )?;
        tmux_output(
            socket,
            &["set-option", "-p", "-t", &pane, "@dnvr_name", &process.name],
        )?;
        tmux_output(
            socket,
            &[
                "set-option",
                "-p",
                "-t",
                &pane,
                "@dnvr_index",
                &process.index.to_string(),
            ],
        )?;
        tmux_output(
            socket,
            &["pipe-pane", "-o", "-t", &pane, &recorder_command(process)?],
        )?;
        fs::write(ready, [])?;
    }

    if !manifest.processes.is_empty() {
        tmux_output(
            socket,
            &["select-layout", "-t", "=dnvr:dashboard", "main-vertical"],
        )?;
    }
    refresh_sidebar(socket, &sidebar)?;
    tmux_output(socket, &["select-pane", "-t", &sidebar])?;
    attach(socket)
}

pub(crate) fn up() -> Result<()> {
    apply_environment()?;
    let state = state_dir()?;
    fs::create_dir_all(state.join("logs"))?;
    fs::create_dir_all(state.join("runtime"))?;
    let socket = socket(&state);
    if tmux_status(&socket, &["has-session", "-t", "=dnvr"])?.success() {
        reattach(&socket)
    } else {
        create(&socket, &state)
    }
}

pub(crate) fn process(index: usize) -> Result<()> {
    let state = state_dir()?;
    let process = manifest::get()
        .processes
        .iter()
        .find(|process| process.index == index)
        .ok_or_else(|| format!("unknown process index {index}"))?;
    let ready = log_dir(&state).join(format!(".launch-{index}"));
    while !ready.exists() {
        thread::sleep(Duration::from_millis(10));
    }
    let runtime = state.join("runtime").join(&process.name);
    // This hidden process worker is single-threaded and sets its scoped
    // environment before starting any resolver or user command.
    unsafe { env::set_var("DNVR_RUNTIME_DIR", &runtime) };
    prepend_own_path()?;
    let _pid_lock = claim_process(&state, process)?;
    let error = Command::new(&manifest::get().shell)
        .arg("-c")
        .arg(&process.command)
        .exec();
    Err(error.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_tmux_shell_commands() {
        assert_eq!(shell_command(&["a b", "c'd", ""]), "'a b' 'c'\\''d' ''");
    }
}
