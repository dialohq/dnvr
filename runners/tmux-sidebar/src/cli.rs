use std::{
    env,
    ffi::{OsStr, OsString},
    fs,
    io::{self, Write},
    os::unix::process::CommandExt,
    path::{Path, PathBuf},
    process::{self, Command as ProcessCommand},
};

use clap::{Args, CommandFactory, Parser, Subcommand, ValueEnum};
use clap_complete::{Shell, generate};
use clap_complete_nushell::Nushell;

use crate::{Result, manifest};

#[derive(Parser)]
#[command(
    name = "dnvr",
    disable_help_flag = true,
    disable_help_subcommand = true
)]
struct DnvrArgs {
    #[arg(short = 'h', long)]
    help: bool,
    #[arg(long)]
    list: bool,
    #[command(subcommand)]
    command: Option<DnvrCommand>,
}

#[derive(Subcommand)]
enum DnvrCommand {
    Up,
    Ps,
    Logs(LogArgs),
    State(crate::state::StateArgs),
    Completions {
        shell: CompletionShell,
    },
    #[command(external_subcommand)]
    External(Vec<OsString>),
}

#[derive(Args)]
struct LogArgs {
    process: OsString,
    #[arg(short = 'f', long)]
    follow: bool,
    #[arg(short = 'n', long)]
    tail: Option<usize>,
    #[arg(long)]
    ansi: bool,
}

#[derive(Clone, Copy, ValueEnum)]
enum CompletionShell {
    Bash,
    Zsh,
    Fish,
    Nushell,
}

fn fail(message: impl std::fmt::Display, code: i32) -> ! {
    eprintln!("{message}");
    process::exit(code);
}

fn exec(executable: &str, args: impl IntoIterator<Item = OsString>) -> Result<()> {
    let error = ProcessCommand::new(executable).args(args).exec();
    Err(error.into())
}

fn state_dir() -> PathBuf {
    env::var_os("DNVR_STATE")
        .map(PathBuf::from)
        .unwrap_or_else(|| fail("DNVR_STATE must be set (run via nix develop)", 1))
}

fn socket(state: &Path) -> PathBuf {
    state
        .join("runtime")
        .join(format!("tmux-{}.sock", manifest::get().name))
}

fn process_info(name: &OsStr) -> &'static manifest::Process {
    manifest::get()
        .processes
        .iter()
        .find(|process| OsStr::new(&process.name) == name)
        .unwrap_or_else(|| {
            fail(
                format!("dnvr logs: unknown process '{}'", name.to_string_lossy()),
                64,
            )
        })
}

fn pane_for(state: &Path, process: &manifest::Process) -> String {
    let socket = socket(state);
    if !socket.exists() {
        fail(
            format!(
                "dnvr logs: no pane for '{}'; run 'dnvr up' first",
                process.name
            ),
            1,
        );
    }
    let output = ProcessCommand::new(&manifest::get().tmux)
        .arg("-S")
        .arg(&socket)
        .args([
            "list-panes",
            "-s",
            "-t",
            "=dnvr",
            "-F",
            "#{@dnvr_index}\t#{pane_id}",
        ])
        .output()
        .unwrap_or_else(|error| fail(error, 1));
    if !output.status.success() {
        fail(String::from_utf8_lossy(&output.stderr).trim(), 1);
    }
    let wanted = process.index.to_string();
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .find_map(|line| {
            let (index, pane) = line.split_once('\t')?;
            (index == wanted).then(|| pane.to_owned())
        })
        .unwrap_or_else(|| {
            fail(
                format!(
                    "dnvr logs: no pane for '{}'; run 'dnvr up' first",
                    process.name
                ),
                1,
            )
        })
}

fn logs(args: LogArgs) -> Result<()> {
    let state = state_dir();
    let process = process_info(&args.process);
    let pane = pane_for(&state, process);
    let suffix = if args.ansi { ".log" } else { ".plain.log" };
    let log = state
        .join("logs")
        .join(format!("tmux-{}", manifest::get().name))
        .join(format!("{}{suffix}", process.log_name));

    if args.follow {
        if !log.exists() {
            fail(format!("dnvr logs: no log yet for '{}'", process.name), 1);
        }
        let count = args
            .tail
            .map_or_else(|| "+1".to_owned(), |count| count.to_string());
        return exec(
            &manifest::get().cli.tail,
            [
                OsString::from("-n"),
                OsString::from(count),
                OsString::from("-F"),
                log.into_os_string(),
            ],
        );
    }

    let socket = socket(&state);
    let mut command = ProcessCommand::new(&manifest::get().tmux);
    command.arg("-S").arg(socket).arg("capture-pane");
    if args.ansi {
        command.arg("-e");
    }
    let output = command
        .args(["-p", "-J", "-S", "-", "-t", &pane])
        .output()?;
    if !output.status.success() {
        fail(String::from_utf8_lossy(&output.stderr).trim(), 1);
    }
    let captured = String::from_utf8_lossy(&output.stdout);
    let mut lines = captured.lines().collect::<Vec<_>>();
    if !args.ansi {
        lines.retain(|line| !line.starts_with("Pane is dead (status "));
        while lines.last().is_some_and(|line| line.trim().is_empty()) {
            lines.pop();
        }
    }
    if let Some(count) = args.tail {
        let keep_from = lines.len().saturating_sub(count);
        lines.drain(..keep_from);
    }
    let mut stdout = io::stdout().lock();
    if !lines.is_empty() {
        stdout.write_all(lines.join("\n").as_bytes())?;
        stdout.write_all(b"\n")?;
    }
    Ok(())
}

fn ps() -> Result<()> {
    let manifest = manifest::get();
    println!(
        "{:<width$} {:<8} STATUS",
        "PROCESS",
        "PID",
        width = manifest.cli.ps_width
    );
    let runtime = state_dir().join("runtime");
    for process in &manifest.processes {
        let pid_file = runtime.join(&process.name).join("pid");
        let (pid, status) = if pid_file.is_file() {
            let pid = fs::read_to_string(&pid_file)
                .unwrap_or_default()
                .trim()
                .to_owned();
            let running = crate::state::lock_is_held(&pid_file)?;
            (
                if pid.is_empty() { "-".to_owned() } else { pid },
                if running { "running" } else { "exited" },
            )
        } else {
            ("-".to_owned(), "stopped")
        };
        println!(
            "{:<width$} {:<8} {status}",
            process.name,
            pid,
            width = manifest.cli.ps_width
        );
    }
    Ok(())
}

fn completions(shell: CompletionShell) {
    let manifest = manifest::get();
    let mut command = DnvrArgs::command();
    for name in manifest.cli.scripts.keys() {
        command = command.subcommand(clap::Command::new(name.clone()));
    }
    let mut stdout = io::stdout().lock();
    match shell {
        CompletionShell::Bash => generate(Shell::Bash, &mut command, "dnvr", &mut stdout),
        CompletionShell::Zsh => generate(Shell::Zsh, &mut command, "dnvr", &mut stdout),
        CompletionShell::Fish => generate(Shell::Fish, &mut command, "dnvr", &mut stdout),
        CompletionShell::Nushell => generate(Nushell, &mut command, "dnvr", &mut stdout),
    }
}

pub(crate) fn run(args: impl Iterator<Item = OsString>) -> Result<()> {
    let manifest = manifest::get();
    let parsed = DnvrArgs::try_parse_from(std::iter::once(OsString::from("dnvr")).chain(args))
        .unwrap_or_else(|error| {
            let _ = error.print();
            process::exit(64);
        });
    let help_subcommand = matches!(
        parsed.command,
        Some(DnvrCommand::External(ref words))
            if words.first().is_some_and(|word| word == "help")
    );
    if parsed.help || help_subcommand {
        println!("{}", manifest.cli.help);
        return Ok(());
    }
    if parsed.list {
        print!("{}", manifest.cli.list);
        return Ok(());
    }
    match parsed.command {
        None => println!("{}", manifest.cli.help),
        Some(DnvrCommand::Up) => return crate::controller::up(),
        Some(DnvrCommand::Ps) => return ps(),
        Some(DnvrCommand::Logs(arguments)) => return logs(arguments),
        Some(DnvrCommand::State(arguments)) => return crate::state::run(arguments),
        Some(DnvrCommand::Completions { shell }) => completions(shell),
        Some(DnvrCommand::External(mut words)) => {
            let command = words.remove(0);
            let executable = manifest
                .cli
                .scripts
                .get(command.to_str().unwrap_or(""))
                .unwrap_or_else(|| {
                    fail(
                        format!(
                            "dnvr: unknown command '{}' (try 'dnvr --help')",
                            command.to_string_lossy()
                        ),
                        64,
                    )
                });
            return exec(executable, words);
        }
    }
    Ok(())
}
