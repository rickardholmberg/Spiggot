//! Locate and load ONNX Runtime without depending on the shell environment.
//!
//! `deepfilter-rt` calls `ort::init_from("libonnxruntime")` with a hardcoded leaf
//! name and ignores `ORT_DYLIB_PATH`, so it relies on the dynamic loader finding a
//! file under that exact name. That only works if a search path is exported, and on
//! macOS SIP strips `DYLD_*` whenever a protected system binary runs — which
//! includes the shell. The result was that `voicemic` worked when invoked directly
//! and failed on every configuration when invoked from a script.
//!
//! The fix relies on `ort` caching the loaded library in a `OnceLock`
//! (`G_ORT_LIB`, populated through `get_or_try_init`). Loading it here by absolute
//! path first means `deepfilter-rt`'s later `init_from` finds it already
//! initialised, skips its own load, and returns `Ok`. No environment variable is
//! involved, so this also survives the hardened runtime that the signed `.app`
//! will need for microphone access.

use std::path::{Path, PathBuf};

#[cfg(feature = "dfn")]
use anyhow::{bail, Context, Result};

/// How a runtime was located, for `doctor` to report.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// `--ort-lib` on the command line.
    Flag,
    /// `ORT_DYLIB_PATH`, which `voicemic` honours even though `deepfilter-rt` does not.
    EnvVar,
    /// Recorded at build time from `deepfilter-rt`'s `cargo:ort_lib_dir`.
    BuildHint,
    /// Found by searching the usual install locations.
    Search,
}

impl Source {
    pub fn describe(self) -> &'static str {
        match self {
            Source::Flag => "--ort-lib",
            Source::EnvVar => "ORT_DYLIB_PATH",
            Source::BuildHint => "recorded at build time",
            Source::Search => "found by search",
        }
    }
}

/// Path recorded by `build.rs`, if the `dfn` feature was enabled at build time.
pub fn build_hint() -> Option<PathBuf> {
    option_env!("VOICEMIC_ORT_HINT").map(PathBuf::from)
}

/// Bundled model directory recorded by `build.rs`.
pub fn models_hint() -> Option<PathBuf> {
    option_env!("VOICEMIC_MODELS_HINT").map(PathBuf::from)
}

/// Directories worth searching when the build hint is absent or stale.
fn search_roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            roots.push(dir.to_path_buf());
        }
    }
    // Homebrew: Apple Silicon and Intel prefixes respectively.
    roots.push(PathBuf::from("/opt/homebrew/lib"));
    roots.push(PathBuf::from("/usr/local/lib"));
    roots
}

fn is_runtime(name: &str) -> bool {
    if !name.starts_with("libonnxruntime") && !name.starts_with("onnxruntime") {
        return false;
    }
    if name.contains("providers") {
        return false;
    }
    name.ends_with(".dylib") || name.contains(".so") || name.ends_with(".dll")
}

/// Search `dir` (non-recursively) for an ONNX Runtime image.
pub fn find_in_dir(dir: &Path) -> Option<PathBuf> {
    let mut best: Option<PathBuf> = None;
    for entry in std::fs::read_dir(dir).ok()?.flatten() {
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if !is_runtime(name) {
            continue;
        }
        // Prefer the versioned file: it is the real image, not a symlink that may
        // not have been created.
        if best
            .as_ref()
            .is_none_or(|b| b.file_name().map(|n| n.len()).unwrap_or(0) < name.len())
        {
            best = Some(path);
        }
    }
    best
}

/// Resolve the runtime, first hit wins. `explicit` comes from `--ort-lib`.
pub fn find_library(explicit: Option<&Path>) -> Option<(PathBuf, Source)> {
    if let Some(p) = explicit {
        return Some((p.to_path_buf(), Source::Flag));
    }
    if let Ok(s) = std::env::var("ORT_DYLIB_PATH") {
        if !s.is_empty() {
            return Some((PathBuf::from(s), Source::EnvVar));
        }
    }
    if let Some(p) = build_hint() {
        if p.exists() {
            return Some((p, Source::BuildHint));
        }
    }
    for root in search_roots() {
        if let Some(p) = find_in_dir(&root) {
            return Some((p, Source::Search));
        }
    }
    None
}

/// Load ONNX Runtime and commit the global `ort` environment.
///
/// Must run before any `DfnEnhancer` is constructed. Returns the path actually
/// loaded so `doctor` and the startup banner can report it.
#[cfg(feature = "dfn")]
pub fn init(explicit: Option<&Path>) -> Result<(PathBuf, Source)> {
    let Some((path, source)) = find_library(explicit) else {
        bail!(
            "could not locate an ONNX Runtime library.\n\
             Tried, in order: --ort-lib, ORT_DYLIB_PATH, the path recorded at build \
             time, and {}.\n\
             Build once with `cargo build --release` so the runtime is downloaded, \
             or pass --ort-lib /path/to/libonnxruntime.dylib.",
            search_roots()
                .iter()
                .map(|p| p.display().to_string())
                .collect::<Vec<_>>()
                .join(", ")
        );
    };

    if !path.exists() {
        bail!(
            "ONNX Runtime path from {} does not exist: {}",
            source.describe(),
            path.display()
        );
    }

    // Loads the dylib and populates ort's global OnceLock. deepfilter-rt's own
    // init_from then finds it already loaded and skips its hardcoded lookup.
    let committed = ort::init_from(&path)
        .with_context(|| format!("loading ONNX Runtime from {}", path.display()))?
        .with_name("voicemic")
        .commit();

    // `commit` returns false when an environment was already configured. That is
    // not an error: the library is loaded either way, which is the part that
    // matters here.
    let _ = committed;

    Ok((path, source))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmpdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("voicemic-ort-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn recognises_platform_library_names() {
        assert!(is_runtime("libonnxruntime.dylib"));
        assert!(is_runtime("libonnxruntime.1.23.2.dylib"));
        assert!(is_runtime("libonnxruntime.so"));
        assert!(is_runtime("libonnxruntime.so.1.23.2"));
        assert!(is_runtime("onnxruntime.dll"));
    }

    #[test]
    fn rejects_provider_shims_and_unrelated_files() {
        // These sit next to the real library and must not be picked up.
        assert!(!is_runtime("libonnxruntime_providers_shared.so"));
        assert!(!is_runtime("libonnxruntime_providers_cuda.dylib"));
        assert!(!is_runtime("README.md"));
        assert!(!is_runtime("libsomethingelse.so"));
    }

    #[test]
    fn prefers_the_versioned_image_over_the_bare_symlink() {
        let d = tmpdir("versioned");
        std::fs::write(d.join("libonnxruntime.so"), b"").unwrap();
        std::fs::write(d.join("libonnxruntime.so.1.23.2"), b"").unwrap();
        std::fs::write(d.join("libonnxruntime_providers_shared.so"), b"").unwrap();

        let found = find_in_dir(&d).expect("should find a runtime");
        assert_eq!(
            found.file_name().unwrap().to_str().unwrap(),
            "libonnxruntime.so.1.23.2"
        );
        std::fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn empty_directory_yields_nothing() {
        let d = tmpdir("empty");
        assert!(find_in_dir(&d).is_none());
        std::fs::remove_dir_all(&d).ok();
    }

    #[test]
    fn explicit_flag_wins_over_everything() {
        let p = PathBuf::from("/nonexistent/libonnxruntime.dylib");
        let (found, source) = find_library(Some(&p)).expect("flag should always resolve");
        assert_eq!(found, p);
        assert_eq!(source, Source::Flag);
    }
}
