//! Live DeepFilterNet enhancement bridged into a macOS virtual microphone.
//!
//! Layout is deliberate: everything that can be reasoned about without an audio
//! device or an ONNX runtime lives in the always-compiled modules below and is
//! unit-tested on any platform. Device I/O and inference sit behind the `audio`
//! and `dfn` features so the tricky parts (drift control, tail statistics, dry/wet
//! alignment) stay verifiable off a Mac.

pub mod delay;
pub mod drift;
pub mod stats;

/// DeepFilterNet operates at a fixed 48 kHz.
pub const SAMPLE_RATE: u32 = 48_000;
/// Frame size accepted by `DeepFilterProcessor::process_frame`.
pub const HOP_SIZE: usize = 480;
/// Wall-clock budget for one frame: 480 samples at 48 kHz.
pub const FRAME_DEADLINE_US: u64 = 10_000;

#[cfg(feature = "audio")]
pub mod bridge;

pub mod enhancer;
