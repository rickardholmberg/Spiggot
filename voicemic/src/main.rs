//! voicemic - live DeepFilterNet enhancement into a macOS virtual microphone.
//!
//! `bench` is the gate for everything else: it reports the per-frame tail on this
//! machine. Mean cost is not the constraint for real-time audio; a frame that
//! occasionally overruns its 10 ms deadline forces a larger jitter buffer, and the
//! jitter buffer dominates end-to-end latency.

use std::path::PathBuf;
#[cfg(feature = "audio")]
use std::sync::atomic::{AtomicBool, Ordering};
#[cfg(feature = "audio")]
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand, ValueEnum};
use voicemic::stats::FrameTimes;
use voicemic::{FRAME_DEADLINE_US, HOP_SIZE, SAMPLE_RATE};

#[derive(Parser)]
#[command(
    name = "voicemic",
    about = "Live DeepFilterNet enhancement into a virtual microphone"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

/// ONNX session layout.
///
/// This choice matters more than the model choice. Upstream measures, on the same
/// audio: combined streaming RTF 0.11, split streaming RTF 0.34, stateless window
/// 0.5-4.0. `deepfilter-rt`'s own `Auto` prefers split whenever the split files
/// are present, which every bundled model directory has, so leaving it on Auto
/// silently costs about 3x. Combined is the default here.
#[derive(Copy, Clone, Debug, PartialEq, Eq, ValueEnum)]
enum Mode {
    Combined,
    Split,
    Stateless,
    Auto,
}

#[derive(Subcommand)]
enum Cmd {
    /// List CoreAudio devices and their supported sample rates.
    ListDevices,

    /// Measure per-frame cost on this machine. Run this before anything else.
    Bench {
        /// Model directory, e.g. deepfilter-rt/models/dfn3
        model: PathBuf,
        /// 48 kHz mono WAV to process. Without one, a synthetic signal is used.
        #[arg(long)]
        wav: Option<PathBuf>,
        /// Frames to measure when generating a synthetic signal.
        #[arg(long, default_value_t = 30_000)]
        frames: usize,
        #[arg(long, value_enum, default_value_t = Mode::Combined)]
        mode: Mode,
        /// ONNX intra-op threads. Upstream recommends 1-2 for real-time: more
        /// threads raise throughput but widen the tail that sizes the buffer.
        #[arg(long, default_value_t = 1)]
        threads: usize,
    },

    /// Enhance a WAV file, for fidelity comparison against upstream `deep-filter`.
    File {
        model: PathBuf,
        input: PathBuf,
        output: PathBuf,
        #[arg(long, value_enum, default_value_t = Mode::Combined)]
        mode: Mode,
        #[arg(long, default_value_t = 1)]
        threads: usize,
        /// Trim the model's algorithmic delay so output is time-aligned with input.
        #[arg(long)]
        align: bool,
    },

    /// Run the live bridge: microphone -> DeepFilterNet -> virtual output device.
    Run {
        model: PathBuf,
        /// Input device name substring. Defaults to the system default input.
        #[arg(long)]
        input: Option<String>,
        /// Output device name substring. Defaults to a device matching "BlackHole".
        #[arg(long)]
        output: Option<String>,
        #[arg(long, value_enum, default_value_t = Mode::Combined)]
        mode: Mode,
        #[arg(long, default_value_t = 1)]
        threads: usize,
        /// Jitter buffer depth in 480-sample frames. Each frame costs 10 ms of
        /// latency, so this is the number to minimise once the tail is known.
        #[arg(long, default_value_t = 3)]
        jitter_frames: usize,
        /// Device buffer size in frames.
        #[arg(long)]
        buffer_frames: Option<u32>,
        /// Bypass the model: measures the bridge's own cost and latency, and is
        /// the control case for every A/B.
        #[arg(long)]
        bypass: bool,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.cmd {
        Cmd::ListDevices => list_devices(),
        Cmd::Bench {
            model,
            wav,
            frames,
            mode,
            threads,
        } => bench(model, wav, frames, mode, threads),
        Cmd::File {
            model,
            input,
            output,
            mode,
            threads,
            align,
        } => file(model, input, output, mode, threads, align),
        Cmd::Run {
            model,
            input,
            output,
            mode,
            threads,
            jitter_frames,
            buffer_frames,
            bypass,
        } => run(
            model,
            input,
            output,
            mode,
            threads,
            jitter_frames,
            buffer_frames,
            bypass,
        ),
    }
}

#[cfg(feature = "audio")]
fn list_devices() -> Result<()> {
    voicemic::bridge::list_devices()
}

#[cfg(not(feature = "audio"))]
fn list_devices() -> Result<()> {
    bail!("built without the `audio` feature")
}

#[cfg(feature = "dfn")]
fn make_enhancer(
    model: &std::path::Path,
    mode: Mode,
    threads: usize,
) -> Result<Box<dyn voicemic::enhancer::Enhancer>> {
    use deepfilter_rt::SessionMode;
    let sm = match mode {
        Mode::Combined => SessionMode::CombinedStreaming,
        Mode::Split => SessionMode::SplitStreaming,
        Mode::Stateless => SessionMode::Stateless,
        Mode::Auto => SessionMode::Auto,
    };
    Ok(Box::new(voicemic::enhancer::DfnEnhancer::new(
        model, sm, threads,
    )?))
}

#[cfg(not(feature = "dfn"))]
fn make_enhancer(
    _model: &std::path::Path,
    _mode: Mode,
    _threads: usize,
) -> Result<Box<dyn voicemic::enhancer::Enhancer>> {
    bail!("built without the `dfn` feature")
}

/// Deterministic stand-in for speech: a few voiced-range harmonics plus noise.
/// Content does not change inference cost for this architecture, but keeping it
/// deterministic makes repeated benchmark runs comparable.
fn synthetic(n: usize) -> Vec<f32> {
    let mut seed = 0x2545_F491_4F6C_DD1Du64;
    (0..n)
        .map(|i| {
            let t = i as f32 / SAMPLE_RATE as f32;
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            let noise = (seed >> 40) as f32 / 8_388_608.0 - 1.0;
            0.25 * (2.0 * std::f32::consts::PI * 140.0 * t).sin()
                + 0.12 * (2.0 * std::f32::consts::PI * 430.0 * t).sin()
                + 0.06 * (2.0 * std::f32::consts::PI * 1900.0 * t).sin()
                + 0.02 * noise
        })
        .collect()
}

fn read_wav_mono_48k(path: &std::path::Path) -> Result<Vec<f32>> {
    let mut r =
        hound::WavReader::open(path).with_context(|| format!("opening {}", path.display()))?;
    let spec = r.spec();
    if spec.sample_rate != SAMPLE_RATE {
        bail!(
            "{} is {} Hz; DeepFilterNet needs {} Hz. Resample first \
             (e.g. `ffmpeg -i in.wav -ar 48000 -ac 1 out.wav`).",
            path.display(),
            spec.sample_rate,
            SAMPLE_RATE
        );
    }
    let ch = spec.channels as usize;
    let samples: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Float => r.samples::<f32>().collect::<Result<_, _>>()?,
        hound::SampleFormat::Int => {
            let scale = 1.0 / (1i64 << (spec.bits_per_sample - 1)) as f32;
            r.samples::<i32>()
                .map(|s| s.map(|v| v as f32 * scale))
                .collect::<Result<_, _>>()?
        }
    };
    Ok(if ch == 1 {
        samples
    } else {
        samples
            .chunks(ch)
            .map(|f| f.iter().sum::<f32>() / ch as f32)
            .collect()
    })
}

fn bench(
    model: PathBuf,
    wav: Option<PathBuf>,
    frames: usize,
    mode: Mode,
    threads: usize,
) -> Result<()> {
    let mut enh = make_enhancer(&model, mode, threads)?;
    println!("Model: {}", enh.describe());

    let signal = match &wav {
        Some(p) => read_wav_mono_48k(p)?,
        None => synthetic(frames * HOP_SIZE),
    };
    let n_frames = signal.len() / HOP_SIZE;
    if n_frames == 0 {
        bail!("input shorter than one {HOP_SIZE}-sample frame");
    }

    let mut out = vec![0.0f32; HOP_SIZE];
    let mut times = FrameTimes::new();
    for f in 0..n_frames {
        let inp = &signal[f * HOP_SIZE..(f + 1) * HOP_SIZE];
        let t0 = std::time::Instant::now();
        enh.process_frame(inp, &mut out)?;
        times.record_us(t0.elapsed().as_micros() as u64);
    }

    let audio_s = (n_frames * HOP_SIZE) as f64 / SAMPLE_RATE as f64;
    println!("\n{} frames ({audio_s:.1}s of audio)", times.count());
    println!("  mean   {:>8.2} ms", times.mean_us() / 1000.0);
    println!(
        "  p50    {:>8.2} ms",
        times.percentile_us(0.50) as f64 / 1000.0
    );
    println!(
        "  p99    {:>8.2} ms",
        times.percentile_us(0.99) as f64 / 1000.0
    );
    println!(
        "  p99.9  {:>8.2} ms",
        times.percentile_us(0.999) as f64 / 1000.0
    );
    println!("  max    {:>8.2} ms", times.max_us() as f64 / 1000.0);
    println!(
        "  RTF    {:>8.3}  (deadline {} ms)",
        times.rtf(FRAME_DEADLINE_US),
        FRAME_DEADLINE_US / 1000
    );

    let over = times.max_us() > FRAME_DEADLINE_US;
    println!(
        "\nWorst frame used {:.0}% of the deadline.",
        100.0 * times.max_us() as f64 / FRAME_DEADLINE_US as f64
    );
    if over {
        println!("Worst frame EXCEEDED the deadline: a jitter buffer of >=2 frames is required.");
    }
    println!(
        "Suggested --jitter-frames: {}",
        (times.max_us().div_ceil(FRAME_DEADLINE_US) + 1).max(2)
    );
    Ok(())
}

fn file(
    model: PathBuf,
    input: PathBuf,
    output: PathBuf,
    mode: Mode,
    threads: usize,
    align: bool,
) -> Result<()> {
    let mut enh = make_enhancer(&model, mode, threads)?;
    println!("Model: {}", enh.describe());

    let signal = read_wav_mono_48k(&input)?;
    let n_frames = signal.len() / HOP_SIZE;
    let mut enhanced = Vec::with_capacity(n_frames * HOP_SIZE);
    let mut out = vec![0.0f32; HOP_SIZE];
    for f in 0..n_frames {
        enh.process_frame(&signal[f * HOP_SIZE..(f + 1) * HOP_SIZE], &mut out)?;
        enhanced.extend_from_slice(&out);
    }

    // Upstream's `deep-filter -D` trims the algorithmic delay so the result lines
    // up with the input. Match that, otherwise a correlation check against the
    // reference compares two different moments in time.
    let body = if align {
        let d = enh.delay_samples().min(enhanced.len());
        &enhanced[d..]
    } else {
        &enhanced[..]
    };

    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: SAMPLE_RATE,
        bits_per_sample: 32,
        sample_format: hound::SampleFormat::Float,
    };
    let mut w = hound::WavWriter::create(&output, spec)
        .with_context(|| format!("creating {}", output.display()))?;
    for &s in body {
        w.write_sample(s)?;
    }
    w.finalize()?;
    println!(
        "Wrote {} ({} samples, delay {}{})",
        output.display(),
        body.len(),
        enh.delay_samples(),
        if align { " trimmed" } else { " retained" }
    );
    Ok(())
}

#[cfg(feature = "audio")]
#[allow(clippy::too_many_arguments)]
fn run(
    model: PathBuf,
    input: Option<String>,
    output: Option<String>,
    mode: Mode,
    threads: usize,
    jitter_frames: usize,
    buffer_frames: Option<u32>,
    bypass: bool,
) -> Result<()> {
    use voicemic::bridge::{self, BridgeConfig, SharedStats};

    let stats = Arc::new(SharedStats::default());
    let stop = Arc::new(AtomicBool::new(false));

    {
        let stop = stop.clone();
        ctrlc_shim(move || stop.store(true, Ordering::Relaxed));
    }

    let cfg = BridgeConfig {
        input,
        output,
        target_fill_frames: jitter_frames.max(1),
        buffer_frames,
    };

    let reporter = {
        let stats = stats.clone();
        let stop = stop.clone();
        std::thread::spawn(move || {
            while !stop.load(Ordering::Relaxed) {
                std::thread::sleep(std::time::Duration::from_secs(1));
                println!(
                    "frames {:>7} | mean {:>5.2} p50 {:>5.2} p99 {:>5.2} max {:>5.2} ms | \
                     ring {:>5} | drift {:+.4}% | under {} over {} late {}",
                    stats.frames_done.load(Ordering::Relaxed),
                    stats.mean_us.load(Ordering::Relaxed) as f64 / 1000.0,
                    stats.p50_us.load(Ordering::Relaxed) as f64 / 1000.0,
                    stats.p99_us.load(Ordering::Relaxed) as f64 / 1000.0,
                    stats.max_us.load(Ordering::Relaxed) as f64 / 1000.0,
                    stats.ring_fill.load(Ordering::Relaxed),
                    (stats.drift_ratio() - 1.0) * 100.0,
                    stats.output_underruns.load(Ordering::Relaxed),
                    stats.input_overruns.load(Ordering::Relaxed),
                    stats.deadline_misses.load(Ordering::Relaxed),
                );
            }
        })
    };

    let factory = move || -> Result<Box<dyn voicemic::enhancer::Enhancer>> {
        if bypass {
            Ok(Box::new(voicemic::enhancer::Passthrough))
        } else {
            make_enhancer(&model, mode, threads)
        }
    };

    println!(
        "Jitter buffer {} frames ({} ms). Ctrl-C to stop.",
        jitter_frames,
        jitter_frames * 10
    );
    let r = bridge::run(cfg, stats.clone(), stop.clone(), factory);
    stop.store(true, Ordering::Relaxed);
    let _ = reporter.join();

    println!(
        "\nFinal: {} frames, underruns {}, overruns {}, deadline misses {}",
        stats.frames_done.load(Ordering::Relaxed),
        stats.output_underruns.load(Ordering::Relaxed),
        stats.input_overruns.load(Ordering::Relaxed),
        stats.deadline_misses.load(Ordering::Relaxed),
    );
    r
}

#[cfg(not(feature = "audio"))]
#[allow(clippy::too_many_arguments)]
fn run(
    _model: PathBuf,
    _input: Option<String>,
    _output: Option<String>,
    _mode: Mode,
    _threads: usize,
    _jitter_frames: usize,
    _buffer_frames: Option<u32>,
    _bypass: bool,
) -> Result<()> {
    bail!("built without the `audio` feature")
}

/// Minimal Ctrl-C handling without pulling in a signal crate.
#[cfg(feature = "audio")]
fn ctrlc_shim<F: Fn() + Send + 'static>(f: F) {
    std::thread::spawn(move || {
        let mut line = String::new();
        // Reading stdin to EOF covers Ctrl-D and a closed pipe; Ctrl-C still
        // terminates the process directly, which is fine for a measurement tool.
        let _ = std::io::stdin().read_line(&mut line);
        f();
    });
}
