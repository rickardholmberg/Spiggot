//! voicemic - live DeepFilterNet enhancement into a macOS virtual microphone.
//!
//! `bench` is the gate for everything else: it reports the per-frame tail on this
//! machine. Mean cost is not the constraint for real-time audio; a frame that
//! occasionally overruns its 10 ms deadline forces a larger jitter buffer, and the
//! jitter buffer dominates end-to-end latency.
//!
//! `doctor` exists because the first failure on the target machine presented as
//! twelve identical `FAILED` rows with no diagnostic. Every environmental
//! precondition is now checkable with one command.

use std::path::{Path, PathBuf};
#[cfg(feature = "audio")]
use std::sync::atomic::{AtomicBool, Ordering};
#[cfg(feature = "audio")]
use std::sync::Arc;

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand, ValueEnum};
use voicemic::stats::FrameTimes;
use voicemic::{ort_setup, FRAME_DEADLINE_US, HOP_SIZE, SAMPLE_RATE};

#[derive(Parser)]
#[command(
    name = "voicemic",
    about = "Live DeepFilterNet enhancement into a virtual microphone"
)]
struct Cli {
    /// Path to the ONNX Runtime library.
    ///
    /// Rarely needed: the path is recorded at build time. It exists because
    /// `deepfilter-rt` ignores `ORT_DYLIB_PATH`, and because macOS SIP strips
    /// `DYLD_*` when a shell runs, so an exported search path cannot be relied on.
    #[arg(long, global = true, value_name = "PATH")]
    ort_lib: Option<PathBuf>,

    #[command(subcommand)]
    cmd: Cmd,
}

/// ONNX session layout.
///
/// This choice matters more than the model choice. Measured on the same audio:
/// combined streaming RTF 0.11, split streaming RTF 0.34, stateless window
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
    /// Check every precondition and report what is wrong.
    Doctor {
        /// Model directory to validate. Defaults to the bundled `dfn3_h0`.
        model: Option<PathBuf>,
    },

    /// List CoreAudio devices and their supported sample rates.
    ListDevices,

    /// Measure per-frame cost on this machine. Run this before anything else.
    Bench {
        /// Model directory. Defaults to the bundled `dfn3_h0`.
        model: Option<PathBuf>,
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
        /// Process one frame per 10 ms of wall clock, matching the live pipeline
        /// instead of running flat out.
        ///
        /// An unpaced benchmark keeps a core saturated, so it boosts and stays on a
        /// performance core. The real worker is busy roughly a quarter of the time
        /// and sleeps the rest, which lets the core clock down. Measured live
        /// frame times ran 6x the unpaced benchmark on identical work; this is the
        /// experiment that says whether duty cycle explains it.
        #[arg(long)]
        pace: bool,
    },

    /// Enhance a WAV file, for fidelity comparison against upstream `deep-filter`.
    File {
        input: PathBuf,
        output: PathBuf,
        #[arg(long)]
        model: Option<PathBuf>,
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
        /// Model directory. Defaults to the bundled `dfn3_h0`.
        model: Option<PathBuf>,
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
        ///
        /// Default 2, which is what `bench` recommends: the measured worst frame
        /// on an M1 Pro is 0.86 ms for dfn3_h0 combined, far inside the 10 ms
        /// deadline. Raise it if the stats line reports underruns.
        #[arg(long, default_value_t = 2)]
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
    let ort_lib = cli.ort_lib.clone();

    match cli.cmd {
        Cmd::Doctor { model } => doctor(model.as_deref(), ort_lib.as_deref()),
        Cmd::ListDevices => list_devices(),
        Cmd::Bench {
            model,
            wav,
            frames,
            mode,
            threads,
            pace,
        } => bench(
            &resolve_model(model.as_deref())?,
            wav,
            frames,
            mode,
            threads,
            pace,
            ort_lib.as_deref(),
        ),
        Cmd::File {
            input,
            output,
            model,
            mode,
            threads,
            align,
        } => file(
            &resolve_model(model.as_deref())?,
            input,
            output,
            mode,
            threads,
            align,
            ort_lib.as_deref(),
        ),
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
            resolve_model(model.as_deref())?,
            input,
            output,
            mode,
            threads,
            jitter_frames,
            buffer_frames,
            bypass,
            ort_lib,
        ),
    }
}

/// Fall back to the model directory that ships inside the `deepfilter-rt`
/// checkout, recorded at build time, so a bare `voicemic bench` works.
fn resolve_model(arg: Option<&Path>) -> Result<PathBuf> {
    if let Some(p) = arg {
        return Ok(p.to_path_buf());
    }
    if let Some(dir) = ort_setup::models_hint() {
        let d = dir.join("dfn3_h0");
        if d.is_dir() {
            return Ok(d);
        }
    }
    bail!(
        "no model directory given and no bundled models were recorded at build time.\n\
         Pass one explicitly, e.g. `voicemic bench /path/to/deepfilter-rt/models/dfn3_h0`."
    )
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
    model: &Path,
    mode: Mode,
    threads: usize,
    ort_lib: Option<&Path>,
) -> Result<Box<dyn voicemic::enhancer::Enhancer>> {
    use deepfilter_rt::SessionMode;

    // Load ONNX Runtime by absolute path before deepfilter-rt gets a chance to try
    // its hardcoded leaf name. ort caches the handle in a OnceLock, so its later
    // lookup finds the library already loaded and succeeds without a search path.
    ort_setup::init(ort_lib)?;

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
    _model: &Path,
    _mode: Mode,
    _threads: usize,
    _ort_lib: Option<&Path>,
) -> Result<Box<dyn voicemic::enhancer::Enhancer>> {
    bail!("built without the `dfn` feature")
}

// ---------------------------------------------------------------- doctor

fn check(label: &str, ok: bool, detail: impl std::fmt::Display) -> bool {
    println!("  [{}] {label}: {detail}", if ok { "ok" } else { "FAIL" });
    ok
}

fn doctor(model: Option<&Path>, ort_lib: Option<&Path>) -> Result<()> {
    println!("voicemic doctor");
    println!(
        "\nBuild\n  target: {} {}\n  features: audio={} dfn={}",
        std::env::consts::OS,
        std::env::consts::ARCH,
        cfg!(feature = "audio"),
        cfg!(feature = "dfn"),
    );

    let mut all_ok = true;

    println!("\nONNX Runtime");
    match ort_setup::find_library(ort_lib) {
        Some((path, source)) => {
            // Reported, not asserted: existence is the check below.
            check(
                "candidate",
                true,
                format!("{} ({})", path.display(), source.describe()),
            );
            all_ok &= check(
                "file exists",
                path.exists(),
                if path.exists() {
                    "yes"
                } else {
                    "no - path is stale"
                },
            );
            #[cfg(feature = "dfn")]
            {
                match ort_setup::init(ort_lib) {
                    Ok((p, _)) => {
                        all_ok &= check("loads", true, p.display());
                    }
                    Err(e) => {
                        all_ok &= check("loads", false, format!("{e:#}"));
                    }
                }
            }
        }
        None => {
            all_ok &= check(
                "candidate",
                false,
                "not found. Build once with `cargo build --release`, or pass --ort-lib",
            );
        }
    }

    println!("\nModels");
    match model
        .map(|m| m.to_path_buf())
        .or_else(|| resolve_model(None).ok())
    {
        Some(dir) => {
            let exists = dir.is_dir();
            all_ok &= check("directory", exists, dir.display());
            if exists {
                let cfg = dir.join("config.ini");
                all_ok &= check(
                    "config.ini",
                    cfg.is_file(),
                    if cfg.is_file() { "present" } else { "missing" },
                );
                if let Ok(text) = std::fs::read_to_string(&cfg) {
                    let la: Vec<&str> = text
                        .lines()
                        .map(str::trim)
                        .filter(|l| {
                            l.starts_with("conv_lookahead") || l.starts_with("df_lookahead")
                        })
                        .collect();
                    check("lookahead", true, la.join(", "));
                }
                let combined = dir.join("combined_streaming.onnx").is_file();
                check(
                    "combined_streaming.onnx",
                    combined,
                    if combined {
                        "present (--mode combined available)"
                    } else {
                        "absent - --mode combined will fall back"
                    },
                );
            }
        }
        None => {
            all_ok &= check("directory", false, "no model directory given or recorded");
        }
    }

    #[cfg(feature = "dfn")]
    if let Some(dir) = model
        .map(|m| m.to_path_buf())
        .or_else(|| resolve_model(None).ok())
    {
        if dir.is_dir() {
            println!("\nInference");
            match make_enhancer(&dir, Mode::Combined, 1, ort_lib) {
                Ok(mut e) => {
                    all_ok &= check("model loads", true, e.describe());
                    let input = vec![0.0f32; HOP_SIZE];
                    let mut out = vec![0.0f32; HOP_SIZE];
                    match e.process_frame(&input, &mut out) {
                        Ok(()) => all_ok &= check("one frame", true, "processed"),
                        Err(err) => all_ok &= check("one frame", false, format!("{err:#}")),
                    }
                }
                Err(e) => all_ok &= check("model loads", false, format!("{e:#}")),
            }
        }
    }

    #[cfg(feature = "audio")]
    {
        println!("\nCoreAudio");
        all_ok &= voicemic::bridge::doctor_devices();
    }

    println!();
    if all_ok {
        println!("All checks passed.");
        Ok(())
    } else {
        bail!("one or more checks failed (see FAIL lines above)")
    }
}

// ---------------------------------------------------------------- bench / file

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

fn read_wav_mono_48k(path: &Path) -> Result<Vec<f32>> {
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

#[allow(clippy::too_many_arguments)]
fn bench(
    model: &Path,
    wav: Option<PathBuf>,
    frames: usize,
    mode: Mode,
    threads: usize,
    pace: bool,
    ort_lib: Option<&Path>,
) -> Result<()> {
    let mut enh = make_enhancer(model, mode, threads, ort_lib)?;
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
    let period = std::time::Duration::from_micros(FRAME_DEADLINE_US);
    let started = std::time::Instant::now();
    if pace {
        println!(
            "paced: one frame per {} ms, {:.0}s wall clock",
            FRAME_DEADLINE_US / 1000,
            n_frames as f64 * FRAME_DEADLINE_US as f64 / 1e6
        );
    }
    for f in 0..n_frames {
        if pace {
            // Sleep until this frame's slot, so the core sees the same idle
            // fraction it sees in the live pipeline.
            let slot = started + period * f as u32;
            if let Some(wait) = slot.checked_duration_since(std::time::Instant::now()) {
                std::thread::sleep(wait);
            }
        }
        let inp = &signal[f * HOP_SIZE..(f + 1) * HOP_SIZE];
        let t0 = std::time::Instant::now();
        enh.process_frame(inp, &mut out)?;
        times.record_us(t0.elapsed().as_micros() as u64);
    }

    let audio_s = (n_frames * HOP_SIZE) as f64 / SAMPLE_RATE as f64;
    println!(
        "\n{} frames ({audio_s:.1}s of audio, {})",
        times.count(),
        if pace { "paced" } else { "unpaced" }
    );
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

    println!(
        "\nWorst frame used {:.0}% of the deadline.",
        100.0 * times.max_us() as f64 / FRAME_DEADLINE_US as f64
    );
    if times.max_us() > FRAME_DEADLINE_US {
        println!("Worst frame EXCEEDED the deadline: a jitter buffer of >=2 frames is required.");
    }
    println!(
        "Suggested --jitter-frames: {}",
        (times.max_us().div_ceil(FRAME_DEADLINE_US) + 1).max(2)
    );
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn file(
    model: &Path,
    input: PathBuf,
    output: PathBuf,
    mode: Mode,
    threads: usize,
    align: bool,
    ort_lib: Option<&Path>,
) -> Result<()> {
    let mut enh = make_enhancer(model, mode, threads, ort_lib)?;
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

// ---------------------------------------------------------------- run

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
    ort_lib: Option<PathBuf>,
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
        let jitter = jitter_frames.max(1);
        std::thread::spawn(move || {
            let mut latency_printed = false;
            let mut last_busy_us = 0u64;
            let mut last_report = std::time::Instant::now();
            while !stop.load(Ordering::Relaxed) {
                std::thread::sleep(std::time::Duration::from_secs(1));
                // Printed once, as soon as both callbacks have reported the block
                // size CoreAudio actually chose. Everything before this point is
                // arithmetic over assumed buffer sizes and is not worth quoting.
                if !latency_printed {
                    if let Some(est) = stats.latency_estimate(jitter) {
                        println!("{}", est.report());
                        latency_printed = true;
                    }
                }
                // Busy fraction over this interval is the honest statement of CPU
                // cost; the mean frame time alone does not say how much of each
                // 10 ms slot was consumed.
                let busy_now = stats.busy_us_total.load(Ordering::Relaxed);
                let elapsed_us = last_report.elapsed().as_micros() as f64;
                let busy_pct = if elapsed_us > 0.0 {
                    100.0 * (busy_now - last_busy_us) as f64 / elapsed_us
                } else {
                    0.0
                };
                last_busy_us = busy_now;
                last_report = std::time::Instant::now();

                let fill = stats
                    .take_fill_window()
                    .map(|(lo, hi, mean)| format!("{lo}/{mean:.0}/{hi}"))
                    .unwrap_or_else(|| "-".to_string());

                println!(
                    "frames {:>7} | mean {:>5.2} p50 {:>5.2} p99 {:>5.2} max {:>5.2} ms | \
                     busy {:>4.1}% | ring lo/avg/hi {:>16} | drift {:+.4}% | \
                     under {} over {} late {}",
                    stats.frames_done.load(Ordering::Relaxed),
                    stats.mean_us.load(Ordering::Relaxed) as f64 / 1000.0,
                    stats.p50_us.load(Ordering::Relaxed) as f64 / 1000.0,
                    stats.p99_us.load(Ordering::Relaxed) as f64 / 1000.0,
                    stats.max_us.load(Ordering::Relaxed) as f64 / 1000.0,
                    busy_pct,
                    fill,
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
            make_enhancer(&model, mode, threads, ort_lib.as_deref())
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
    _ort_lib: Option<PathBuf>,
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
