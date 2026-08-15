use std::{collections::BTreeMap, sync::OnceLock};

use serde::Deserialize;

#[derive(Debug, Deserialize)]
pub(crate) struct Manifest {
    pub(crate) name: String,
    pub(crate) tmux: String,
    pub(crate) shell: String,
    pub(crate) tmux_config: String,
    pub(crate) rotatelogs: String,
    pub(crate) ansifilter: String,
    pub(crate) prerun: String,
    pub(crate) env: BTreeMap<String, String>,
    pub(crate) processes: Vec<Process>,
    pub(crate) cli: Cli,
}

#[derive(Debug, Deserialize)]
pub(crate) struct Process {
    pub(crate) index: usize,
    pub(crate) name: String,
    pub(crate) log_name: String,
    pub(crate) command: String,
}

#[derive(Debug, Deserialize)]
pub(crate) struct Cli {
    pub(crate) tail: String,
    pub(crate) help: String,
    pub(crate) list: String,
    pub(crate) ps_width: usize,
    pub(crate) scripts: BTreeMap<String, String>,
}

pub(crate) fn get() -> &'static Manifest {
    static MANIFEST: OnceLock<Manifest> = OnceLock::new();
    MANIFEST.get_or_init(|| {
        serde_json::from_str(include_str!(env!("DNVR_MANIFEST_PATH")))
            .expect("embedded dnvr tmux manifest must be valid")
    })
}
