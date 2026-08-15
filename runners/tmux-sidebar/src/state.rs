use std::{
    env, fs,
    fs::OpenOptions,
    io::{self, IsTerminal, Write},
    net::TcpListener,
    path::{Path, PathBuf},
    process, thread,
    time::{Duration, Instant},
};

use clap::{Args, Parser, Subcommand};
use rustix::fs::{FlockOperation, flock};

use crate::Result;

#[derive(Args)]
pub struct StateArgs {
    #[command(subcommand)]
    command: StateCommand,
}

#[derive(Subcommand)]
enum StateCommand {
    /// Publish a value in the calling process's scope.
    Set { key: String, value: String },
    /// Read a live process value.
    Get { reference: String },
    /// Wait until a process is alive and has published a value.
    Wait {
        reference: String,
        #[arg(long, default_value_t = 30)]
        timeout: u64,
    },
    /// Ask the kernel for an unused TCP port.
    PickPort,
    /// Remove cached ref-handler values.
    CacheClear,
    /// Print all raw runtime state.
    Dump,
}

#[derive(Parser)]
#[command(name = "dnvr-state")]
struct Standalone {
    #[command(flatten)]
    state: StateArgs,
}

fn fail(message: impl std::fmt::Display, code: i32) -> ! {
    eprintln!("{message}");
    process::exit(code);
}

fn state_dir() -> PathBuf {
    env::var_os("DNVR_STATE")
        .map(PathBuf::from)
        .unwrap_or_else(|| fail("DNVR_STATE must be set (run via nix develop)", 1))
}

fn split_reference(reference: &str) -> (&str, &str) {
    reference.split_once('.').unwrap_or_else(|| {
        fail(
            format!("dnvr-state: expected '<proc>.<key>', got '{reference}'"),
            2,
        )
    })
}

pub fn lock_is_held(path: &Path) -> io::Result<bool> {
    let file = match OpenOptions::new().read(true).write(true).open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
    };
    match flock(&file, FlockOperation::NonBlockingLockShared) {
        Ok(()) => {
            flock(&file, FlockOperation::Unlock)?;
            Ok(false)
        }
        Err(error) if error == rustix::io::Errno::WOULDBLOCK => Ok(true),
        Err(error) => Err(error.into()),
    }
}

fn live_value(runtime: &Path, reference: &str) -> Result<Option<String>> {
    let (service, key) = split_reference(reference);
    let service_dir = runtime.join(service);
    if !lock_is_held(&service_dir.join("pid"))? {
        return Ok(None);
    }
    match fs::read_to_string(service_dir.join(key)) {
        Ok(value) => Ok(Some(value)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

fn atomic_write(directory: &Path, key: &str, value: &str) -> Result<()> {
    fs::create_dir_all(directory)?;
    let mut counter = 0_u32;
    let (temporary, mut file) = loop {
        let path = directory.join(format!(".tmp.{key}.{}.{counter}", process::id()));
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(file) => break (path, file),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => counter += 1,
            Err(error) => return Err(error.into()),
        }
    };
    writeln!(file, "{value}")?;
    file.sync_all()?;
    fs::rename(temporary, directory.join(key))?;
    Ok(())
}

pub fn run(args: StateArgs) -> Result<()> {
    let state = state_dir();
    let runtime = state.join("runtime");
    match args.command {
        StateCommand::Set { key, value } => {
            let directory = env::var_os("DNVR_RUNTIME_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|| {
                    fail(
                        "dnvr-state set must run in a process-scoped wrapper (DNVR_RUNTIME_DIR unset)",
                        1,
                    )
                });
            atomic_write(&directory, &key, &value)?;
        }
        StateCommand::Get { reference } => match live_value(&runtime, &reference)? {
            Some(value) => print!("{value}"),
            None => fail(
                format!("dnvr-state: {reference} is missing or stale — its process is not running"),
                1,
            ),
        },
        StateCommand::Wait { reference, timeout } => {
            let started = Instant::now();
            let deadline = started + Duration::from_secs(timeout);
            let report = io::stderr().is_terminal();
            let mut next_report = Duration::from_secs(1);
            let mut reported = false;
            loop {
                if let Some(value) = live_value(&runtime, &reference)? {
                    if report && reported {
                        eprintln!(
                            "dnvr-state: {reference} ready ({}s)",
                            started.elapsed().as_secs()
                        );
                    }
                    print!("{value}");
                    break;
                }
                if Instant::now() >= deadline {
                    fail(
                        format!("dnvr-state: timeout waiting {timeout} s for {reference}"),
                        1,
                    );
                }
                if report && started.elapsed() >= next_report {
                    if reported {
                        eprintln!(
                            "dnvr-state: still waiting for {reference} ({}s elapsed) ...",
                            started.elapsed().as_secs()
                        );
                    } else {
                        eprintln!("dnvr-state: waiting for {reference} ...");
                        reported = true;
                    }
                    next_report += Duration::from_secs(5);
                }
                thread::sleep(Duration::from_millis(100));
            }
        }
        StateCommand::PickPort => {
            let listener = TcpListener::bind(("0.0.0.0", 0))?;
            println!("{}", listener.local_addr()?.port());
        }
        StateCommand::CacheClear => {
            let cache = state.join("ref-cache");
            match fs::remove_dir_all(cache) {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error.into()),
            }
        }
        StateCommand::Dump => {
            if !runtime.is_dir() {
                eprintln!(
                    "(no runtime state yet — {} does not exist)",
                    runtime.display()
                );
                return Ok(());
            }
            let mut rows = Vec::new();
            for service in fs::read_dir(runtime)? {
                let service = service?;
                if !service.file_type()?.is_dir() {
                    continue;
                }
                for key in fs::read_dir(service.path())? {
                    let key = key?;
                    if key.file_type()?.is_file() {
                        rows.push(format!(
                            "{}.{} = {}",
                            service.file_name().to_string_lossy(),
                            key.file_name().to_string_lossy(),
                            fs::read_to_string(key.path())?.trim_end()
                        ));
                    }
                }
            }
            rows.sort();
            for row in rows {
                println!("{row}");
            }
        }
    }
    Ok(())
}

pub fn run_standalone(args: impl Iterator<Item = std::ffi::OsString>) -> Result<()> {
    let parsed = Standalone::try_parse_from(std::iter::once("dnvr-state".into()).chain(args))
        .unwrap_or_else(|error| {
            let _ = error.print();
            process::exit(64);
        });
    run(parsed.state)
}
