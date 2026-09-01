//! Records where the ONNX Runtime and the bundled models landed, so the binary can
//! find them without any ambient shell state.
//!
//! This exists because macOS SIP strips `DYLD_*` from the environment whenever a
//! protected system binary is executed. Running `voicemic` through any shell
//! script therefore loses a `DYLD_LIBRARY_PATH` set by the user, which is what
//! made `bench_matrix.sh` fail on every configuration while the same binary
//! invoked directly worked. Baking the paths in at build time removes the
//! dependency on the environment entirely.
//!
//! `deepfilter-rt` declares `links = "deepfilter_rt"` and emits `cargo:ort_lib_dir`
//! and `cargo:models_dir`, which Cargo forwards to this script as
//! `DEP_DEEPFILTER_RT_*`. That is the authoritative location, so no searching is
//! needed here. Both hints are optional: absence must never fail the build,
//! because the `dfn` feature can be off entirely.

use std::path::{Path, PathBuf};

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=DEP_DEEPFILTER_RT_ORT_LIB_DIR");
    println!("cargo:rerun-if-env-changed=DEP_DEEPFILTER_RT_MODELS_DIR");

    if let Ok(dir) = std::env::var("DEP_DEEPFILTER_RT_ORT_LIB_DIR") {
        if let Some(lib) = find_runtime(Path::new(&dir)) {
            println!("cargo:rustc-env=VOICEMIC_ORT_HINT={}", lib.display());
        }
    }

    if let Ok(dir) = std::env::var("DEP_DEEPFILTER_RT_MODELS_DIR") {
        println!("cargo:rustc-env=VOICEMIC_MODELS_HINT={dir}");
    }
}

/// Pick the real ONNX Runtime image in `dir`.
///
/// Prefers a versioned file over the bare symlink so the recorded path stays valid
/// even if the unversioned link is removed: macOS ships
/// `libonnxruntime.1.23.2.dylib`, Linux `libonnxruntime.so.1.23.2`.
fn find_runtime(dir: &Path) -> Option<PathBuf> {
    let mut best: Option<PathBuf> = None;
    for entry in std::fs::read_dir(dir).ok()? {
        let path = entry.ok()?.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if !name.starts_with("libonnxruntime") && !name.starts_with("onnxruntime") {
            continue;
        }
        let is_lib = name.ends_with(".dylib") || name.contains(".so") || name.ends_with(".dll");
        if !is_lib || name.contains("providers") {
            continue;
        }
        // Longer names carry the version, e.g. libonnxruntime.so.1.23.2 over
        // libonnxruntime.so. Symlinks resolve fine either way, but the versioned
        // file is the one guaranteed to exist.
        if best
            .as_ref()
            .is_none_or(|b| b.file_name().map(|n| n.len()).unwrap_or(0) < name.len())
        {
            best = Some(path);
        }
    }
    best
}
