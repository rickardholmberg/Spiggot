//! The enhancement stage, behind a trait so the bridge can be exercised without
//! an ONNX runtime and so later models drop in without touching the audio path.

#[cfg_attr(not(feature = "dfn"), allow(unused_imports))]
use crate::HOP_SIZE;

/// Processes exactly one 480-sample frame in place of the audio thread.
///
/// Implementations must not allocate in `process_frame`; the whole point of the
/// worker-thread design is that the cost here is bounded and measurable.
pub trait Enhancer: Send {
    /// Enhance one frame. `input` and `output` are both exactly `HOP_SIZE`.
    fn process_frame(&mut self, input: &[f32], output: &mut [f32]) -> anyhow::Result<()>;

    /// Algorithmic delay in samples, for dry/wet alignment and latency accounting.
    fn delay_samples(&self) -> usize;

    /// Human-readable description for the stats line.
    fn describe(&self) -> String;
}

/// Copies input to output. The `--bypass` reference and the control case for
/// every measurement: it isolates bridge cost from model cost.
pub struct Passthrough;

impl Enhancer for Passthrough {
    fn process_frame(&mut self, input: &[f32], output: &mut [f32]) -> anyhow::Result<()> {
        output.copy_from_slice(input);
        Ok(())
    }

    fn delay_samples(&self) -> usize {
        0
    }

    fn describe(&self) -> String {
        "passthrough (bypass)".to_string()
    }
}

#[cfg(feature = "dfn")]
mod dfn_impl {
    use super::*;
    use anyhow::Context;
    use deepfilter_rt::{DeepFilterProcessor, SessionMode};
    use std::path::Path;

    /// DeepFilterNet via deepfilter-rt / ONNX Runtime.
    pub struct DfnEnhancer {
        proc: DeepFilterProcessor,
        label: String,
    }

    impl DfnEnhancer {
        /// Load a model directory (e.g. `models/dfn3`).
        ///
        /// Session mode and thread count are explicit rather than left to
        /// `SessionMode::Auto`, and that matters: `Auto` prefers split streaming
        /// whenever the split ONNX files are present, which upstream measures at
        /// RTF 0.34 against 0.11 for combined streaming on identical audio. The
        /// default here is therefore combined streaming.
        ///
        /// Upstream also recommends 1-2 intra-op threads for real-time use; more
        /// threads raise throughput but widen the jitter that sizes our buffer.
        pub fn new(model_dir: &Path, mode: SessionMode, threads: usize) -> anyhow::Result<Self> {
            let mut proc = DeepFilterProcessor::with_mode(model_dir, mode, Some(threads))
                .map_err(|e| annotate_ort_error(e, model_dir))
                .with_context(|| {
                    format!("loading DeepFilterNet model from {}", model_dir.display())
                })?;
            // Warm up off the audio path: the first inferences allocate and page in
            // weights, and would otherwise show up as a startup deadline miss.
            proc.warmup().context("warming up DeepFilterNet")?;

            let label = format!(
                "{} [{}] {} threads, delay {} samples",
                proc.variant().name(),
                proc.inference_mode_name(),
                threads,
                proc.delay_samples(),
            );
            Ok(Self { proc, label })
        }
    }

    /// `deepfilter-rt` calls `ort::init_from("libonnxruntime")` with a hardcoded leaf
    /// name and ignores `ORT_DYLIB_PATH`. On macOS and Linux the shipped file is
    /// `libonnxruntime.dylib` / `libonnxruntime.so.N`, neither of which `dlopen`
    /// resolves from that name, so a correct build fails at first use with an opaque
    /// message. Point at the fix rather than making the user find it.
    fn annotate_ort_error(e: deepfilter_rt::DfError, model_dir: &Path) -> anyhow::Error {
        let msg = e.to_string();
        if msg.contains("Failed to load ONNX Runtime") || msg.contains("dlopen") {
            anyhow::anyhow!(
            "{msg}\n\n\
             ONNX Runtime could not be dlopen'd. deepfilter-rt asks the loader for a file \n\
             named exactly `libonnxruntime`, with no extension, so the shipped \n\
             `libonnxruntime.dylib` (macOS) or `libonnxruntime.so.N` (Linux) is not found.\n\n\
             Fix: run `scripts/ort_env.sh` and follow the two lines it prints, or do it by hand:\n\
               mkdir -p ~/.voicemic/ort\n\
               ln -sf /path/to/libonnxruntime.dylib ~/.voicemic/ort/libonnxruntime\n\
               export DYLD_LIBRARY_PATH=~/.voicemic/ort:$DYLD_LIBRARY_PATH   # Linux: LD_LIBRARY_PATH\n\n\
             The variable is read by the dynamic loader at process start, so it must be set \n\
             before launching voicemic, not from inside it.\n\
             (model dir: {})",
            model_dir.display()
        )
        } else {
            anyhow::anyhow!(msg)
        }
    }

    impl Enhancer for DfnEnhancer {
        fn process_frame(&mut self, input: &[f32], output: &mut [f32]) -> anyhow::Result<()> {
            debug_assert_eq!(input.len(), HOP_SIZE);
            debug_assert_eq!(output.len(), HOP_SIZE);
            self.proc
                .process_frame(input, output)
                .map_err(|e| anyhow::anyhow!("DeepFilterNet frame failed: {e}"))
        }

        fn delay_samples(&self) -> usize {
            self.proc.delay_samples()
        }

        fn describe(&self) -> String {
            self.label.clone()
        }
    }
}

#[cfg(feature = "dfn")]
pub use dfn_impl::DfnEnhancer;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn passthrough_is_bit_exact() {
        let mut e = Passthrough;
        let input: Vec<f32> = (0..HOP_SIZE).map(|i| i as f32 / HOP_SIZE as f32).collect();
        let mut output = vec![0.0f32; HOP_SIZE];
        e.process_frame(&input, &mut output).unwrap();
        assert_eq!(input, output);
        assert_eq!(e.delay_samples(), 0);
    }
}
