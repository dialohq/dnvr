use std::{env, path::PathBuf};

fn main() {
    println!("cargo::rerun-if-env-changed=DNVR_MANIFEST_PATH");
    if env::var_os("DNVR_MANIFEST_PATH").is_none() {
        let fallback = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap())
            .join("src/test-manifest.json");
        println!("cargo::rustc-env=DNVR_MANIFEST_PATH={}", fallback.display());
    }
}
