use std::{
    env, io,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::Duration,
};

use axum::{
    Json, Router,
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde::{Deserialize, Serialize};

use super::{Result, tmux, tmux_text};

const ADDRESS_ENV: &str = "DNVR_SIDEBAR_API_ADDRESS";
const URL_OPTION: &str = "@dnvr_sidebar_api_url";

#[derive(Clone)]
struct AppState {
    session_id: String,
    refresh: Arc<AtomicBool>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct Process {
    #[serde(skip_serializing)]
    _role: String,
    name: String,
    index: usize,
    pane: String,
    running: bool,
    pid: u32,
    exit_code: Option<i32>,
    command: String,
}

#[derive(Serialize)]
struct ProcessList {
    processes: Vec<Process>,
}

#[derive(Serialize)]
struct StatusResponse {
    status: &'static str,
}

struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn internal(error: impl ToString) -> Self {
        Self {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            message: error.to_string(),
        }
    }

    fn process_not_found(name: &str) -> Self {
        Self {
            status: StatusCode::NOT_FOUND,
            message: format!("process {name:?} not found"),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(serde_json::json!({ "error": self.message })),
        )
            .into_response()
    }
}

fn parse_processes(output: &str) -> Result<Vec<Process>> {
    let mut reader = csv::ReaderBuilder::new()
        .delimiter(b'\t')
        .has_headers(false)
        .from_reader(output.as_bytes());
    let mut processes = reader
        .records()
        .filter_map(|record| match record {
            Ok(record) if record.get(0) == Some("process") => Some(record.deserialize(None)),
            Ok(_) => None,
            Err(error) => Some(Err(error)),
        })
        .collect::<std::result::Result<Vec<Process>, _>>()?;
    processes.sort_by_key(|process| process.index);
    Ok(processes)
}

fn list_processes(session_id: &str) -> Result<Vec<Process>> {
    let output = tmux_text(&[
        "list-panes",
        "-s",
        "-t",
        session_id,
        "-F",
        "#{@dnvr_role}\t#{@dnvr_name}\t#{@dnvr_index}\t#{pane_id}\t#{?pane_dead,false,true}\t#{pane_pid}\t#{pane_dead_status}\t#{pane_current_command}",
    ])?;
    parse_processes(&output)
}

async fn health() -> Json<StatusResponse> {
    Json(StatusResponse { status: "ok" })
}

async fn processes(
    State(state): State<AppState>,
) -> std::result::Result<Json<ProcessList>, ApiError> {
    let processes = tokio::task::spawn_blocking(move || list_processes(&state.session_id))
        .await
        .map_err(ApiError::internal)?
        .map_err(ApiError::internal)?;
    Ok(Json(ProcessList { processes }))
}

fn process_pane(session_id: &str, name: &str) -> Result<Option<String>> {
    Ok(list_processes(session_id)?
        .into_iter()
        .find(|process| process.name == name)
        .map(|process| process.pane))
}

fn restart_process(pane: &str) -> Result<()> {
    tmux(&["respawn-pane", "-k", "-t", pane])?;
    Ok(())
}

fn interrupt_process(pane: &str) -> Result<()> {
    tmux(&["send-keys", "-t", pane, "C-c"])?;
    Ok(())
}

async fn process_action(
    state: AppState,
    name: String,
    action: fn(&str) -> Result<()>,
) -> std::result::Result<Json<StatusResponse>, ApiError> {
    let refresh = Arc::clone(&state.refresh);
    let process_found = tokio::task::spawn_blocking({
        let name = name.clone();
        move || -> Result<bool> {
            let Some(pane) = process_pane(&state.session_id, &name)? else {
                return Ok(false);
            };
            action(&pane)?;
            Ok(true)
        }
    })
    .await
    .map_err(ApiError::internal)?
    .map_err(ApiError::internal)?;

    if !process_found {
        return Err(ApiError::process_not_found(&name));
    }
    refresh.store(true, Ordering::Relaxed);
    Ok(Json(StatusResponse { status: "ok" }))
}

async fn restart(
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> std::result::Result<Json<StatusResponse>, ApiError> {
    process_action(state, name, restart_process).await
}

async fn interrupt(
    State(state): State<AppState>,
    Path(name): Path<String>,
) -> std::result::Result<Json<StatusResponse>, ApiError> {
    process_action(state, name, interrupt_process).await
}

async fn stop(State(state): State<AppState>) -> (StatusCode, Json<StatusResponse>) {
    thread::spawn(move || {
        thread::sleep(Duration::from_millis(100));
        if let Err(error) = tmux(&["kill-session", "-t", &state.session_id]) {
            eprintln!("dnvr sidebar API failed to stop session: {error}");
        }
    });
    (
        StatusCode::ACCEPTED,
        Json(StatusResponse { status: "stopping" }),
    )
}

async fn not_found() -> impl IntoResponse {
    (
        StatusCode::NOT_FOUND,
        Json(serde_json::json!({ "error": "not found" })),
    )
}

async fn serve(listener: tokio::net::TcpListener, state: AppState) -> io::Result<()> {
    let app = Router::new()
        .route("/v1/health", get(health))
        .route("/v1/processes", get(processes))
        .route("/v1/processes/{name}/restart", post(restart))
        .route("/v1/processes/{name}/interrupt", post(interrupt))
        .route("/v1/stop", post(stop))
        .fallback(not_found)
        .with_state(state);
    axum::serve(listener, app).await
}

fn run(
    runtime: tokio::runtime::Runtime,
    listener: tokio::net::TcpListener,
    state: AppState,
) -> Result<()> {
    runtime.block_on(serve(listener, state))?;
    Ok(())
}

pub fn start(session_id: &str, refresh: Arc<AtomicBool>) -> Result<()> {
    let address = env::var(ADDRESS_ENV).unwrap_or_else(|_| "127.0.0.1:0".to_owned());
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    let listener = runtime
        .block_on(tokio::net::TcpListener::bind(&address))
        .map_err(|error| format!("bind sidebar API at {address}: {error}"))?;
    let url = format!("http://{}", listener.local_addr()?);
    tmux(&["set-option", "-g", "-t", session_id, URL_OPTION, &url])?;

    let state = AppState {
        session_id: session_id.to_owned(),
        refresh,
    };
    thread::Builder::new()
        .name("dnvr-sidebar-api".to_owned())
        .spawn(move || {
            if let Err(error) = run(runtime, listener, state) {
                eprintln!("dnvr sidebar API failed: {error}");
            }
        })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_process_metadata() {
        let output = concat!(
            "sidebar\t\t\t%0\ttrue\t100\t\tdnvr-tmux-sidebar\n",
            "process\tclickhouse\t0\t%1\ttrue\t101\t\tclickhouse-server\n",
            "process\tmigrate\t1\t%2\tfalse\t102\t42\tbash",
        );
        let processes = parse_processes(output).unwrap();
        assert_eq!(processes.len(), 2);
        assert_eq!(processes[0].name, "clickhouse");
        assert!(processes[0].running);
        assert_eq!(processes[0].exit_code, None);
        assert_eq!(processes[1].name, "migrate");
        assert!(!processes[1].running);
        assert_eq!(processes[1].exit_code, Some(42));
    }
}
