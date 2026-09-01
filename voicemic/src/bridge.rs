//! CoreAudio capture -> enhancement -> virtual output device.
//!
//! Threading follows the rule that decides whether this works at all: the audio
//! callbacks only copy samples between lock-free rings, and every millisecond of
//! inference happens on a dedicated worker. Upstream measures DeepFilterNet's
//! worst-case frame at 5.21 ms against a 10 ms deadline, so running inference
//! inside a callback whose period may be 2.67 ms (128 frames at 48 kHz) would
//! drop audio continuously.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

use anyhow::{anyhow, bail, Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{BufferSize, Device, SampleRate, StreamConfig};
use rubato::{FastFixedIn, PolynomialDegree, Resampler};

use crate::drift::{DriftController, MAX_DEVIATION};
use crate::enhancer::Enhancer;
use crate::stats::FrameTimes;
use crate::{FRAME_DEADLINE_US, HOP_SIZE, SAMPLE_RATE};

/// Resampler chunk size. One DeepFilterNet frame keeps the pipeline in step.
const RESAMPLER_CHUNK: usize = HOP_SIZE;

/// Ring capacity in frames. Generous: the rings absorb scheduling jitter, and
/// occupancy is held at `target_fill_frames` by the drift controller, so extra
/// capacity costs no latency.
const RING_FRAMES: usize = 128;

pub struct BridgeConfig {
    /// Substring matched against input device names. `None` uses the default input.
    pub input: Option<String>,
    /// Substring matched against output device names. `None` looks for BlackHole.
    pub output: Option<String>,
    /// Steady-state occupancy of the output ring, in 480-sample frames. This is
    /// the jitter buffer, and it is the dominant tunable term in total latency.
    pub target_fill_frames: usize,
    /// Device buffer size in frames. `None` leaves it to CoreAudio.
    pub buffer_frames: Option<u32>,
}

/// Lock-free counters shared with the audio callbacks.
#[derive(Default)]
pub struct SharedStats {
    pub output_underruns: AtomicU64,
    pub input_overruns: AtomicU64,
    pub deadline_misses: AtomicU64,
    pub frames_done: AtomicU64,
    pub mean_us: AtomicU64,
    pub p50_us: AtomicU64,
    pub p99_us: AtomicU64,
    pub max_us: AtomicU64,
    pub ring_fill: AtomicU64,
    /// Drift ratio scaled by 1e9, since atomics cannot hold floats.
    pub drift_ratio_nano: AtomicU64,
}

impl SharedStats {
    pub fn drift_ratio(&self) -> f64 {
        self.drift_ratio_nano.load(Ordering::Relaxed) as f64 / 1e9
    }
}

pub fn list_devices() -> Result<()> {
    let host = cpal::default_host();
    println!("Input devices:");
    for d in host.input_devices()? {
        let name = d.name().unwrap_or_else(|_| "<unknown>".into());
        let rates = supported_input_rates(&d);
        println!("  {name}  rates: {rates:?}");
    }
    println!("\nOutput devices:");
    for d in host.output_devices()? {
        let name = d.name().unwrap_or_else(|_| "<unknown>".into());
        let rates = supported_output_rates(&d);
        println!("  {name}  rates: {rates:?}");
    }
    Ok(())
}

fn supported_input_rates(d: &Device) -> Vec<u32> {
    d.supported_input_configs()
        .map(|cs| {
            let mut v: Vec<u32> = cs
                .flat_map(|c| [c.min_sample_rate().0, c.max_sample_rate().0])
                .collect();
            v.sort_unstable();
            v.dedup();
            v
        })
        .unwrap_or_default()
}

fn supported_output_rates(d: &Device) -> Vec<u32> {
    d.supported_output_configs()
        .map(|cs| {
            let mut v: Vec<u32> = cs
                .flat_map(|c| [c.min_sample_rate().0, c.max_sample_rate().0])
                .collect();
            v.sort_unstable();
            v.dedup();
            v
        })
        .unwrap_or_default()
}

fn find_input(host: &cpal::Host, want: &Option<String>) -> Result<Device> {
    match want {
        Some(sub) => host
            .input_devices()?
            .find(|d| {
                d.name()
                    .map(|n| n.to_lowercase().contains(&sub.to_lowercase()))
                    .unwrap_or(false)
            })
            .ok_or_else(|| anyhow!("no input device matching {sub:?} (try --list-devices)")),
        None => host
            .default_input_device()
            .ok_or_else(|| anyhow!("no default input device")),
    }
}

fn find_output(host: &cpal::Host, want: &Option<String>) -> Result<Device> {
    let sub = want.clone().unwrap_or_else(|| "blackhole".to_string());
    host.output_devices()?
        .find(|d| {
            d.name()
                .map(|n| n.to_lowercase().contains(&sub.to_lowercase()))
                .unwrap_or(false)
        })
        .ok_or_else(|| {
            anyhow!(
                "no output device matching {sub:?}. Install BlackHole \
                 (https://existential.audio/blackhole/) or pass --output (try --list-devices)"
            )
        })
}

/// Pick a stream rate, preferring 48 kHz so no resampling is needed at all.
fn choose_rate(supported: &[u32], default: u32) -> u32 {
    if supported.contains(&SAMPLE_RATE) {
        SAMPLE_RATE
    } else {
        default
    }
}

/// Run until `stop` is set. `make_enhancer` is called on the worker thread so the
/// model is constructed and warmed up where it will run.
pub fn run<F>(
    cfg: BridgeConfig,
    stats: Arc<SharedStats>,
    stop: Arc<AtomicBool>,
    make_enhancer: F,
) -> Result<()>
where
    F: FnOnce() -> Result<Box<dyn Enhancer>> + Send + 'static,
{
    let host = cpal::default_host();
    let in_dev = find_input(&host, &cfg.input)?;
    let out_dev = find_output(&host, &cfg.output)?;

    let in_default = in_dev.default_input_config().context("input config")?;
    let out_default = out_dev.default_output_config().context("output config")?;

    let in_rate = choose_rate(&supported_input_rates(&in_dev), in_default.sample_rate().0);
    let out_rate = choose_rate(
        &supported_output_rates(&out_dev),
        out_default.sample_rate().0,
    );
    let in_ch = in_default.channels() as usize;
    let out_ch = out_default.channels() as usize;

    println!(
        "Input : {} @ {} Hz, {} ch",
        in_dev.name().unwrap_or_default(),
        in_rate,
        in_ch
    );
    println!(
        "Output: {} @ {} Hz, {} ch",
        out_dev.name().unwrap_or_default(),
        out_rate,
        out_ch
    );
    if in_rate != SAMPLE_RATE {
        println!(
            "note: input runs at {in_rate} Hz and is resampled to 48 kHz. Upsampling \
             adds no bandwidth; content above {} Hz is absent from the source.",
            in_rate / 2
        );
    }

    let buf = match cfg.buffer_frames {
        Some(n) => BufferSize::Fixed(n),
        None => BufferSize::Default,
    };
    let in_cfg = StreamConfig {
        channels: in_ch as u16,
        sample_rate: SampleRate(in_rate),
        buffer_size: buf,
    };
    let out_cfg = StreamConfig {
        channels: out_ch as u16,
        sample_rate: SampleRate(out_rate),
        buffer_size: buf,
    };

    let (mut in_tx, mut in_rx) = rtrb::RingBuffer::<f32>::new(RING_FRAMES * HOP_SIZE);
    let (mut out_tx, mut out_rx) = rtrb::RingBuffer::<f32>::new(RING_FRAMES * HOP_SIZE);

    // Pre-fill the output ring with silence so the first output callbacks have
    // something to read while the worker spins up. Without this the run always
    // opens with a burst of underruns.
    let prefill = cfg.target_fill_frames * HOP_SIZE;
    for _ in 0..prefill {
        let _ = out_tx.push(0.0);
    }

    let s = stats.clone();
    let in_stream = in_dev
        .build_input_stream(
            &in_cfg,
            move |data: &[f32], _: &cpal::InputCallbackInfo| {
                // Downmix to mono. The MacBook array already beamforms upstream of us.
                let mut dropped = 0u64;
                for frame in data.chunks(in_ch) {
                    let mono = frame.iter().sum::<f32>() / in_ch as f32;
                    if in_tx.push(mono).is_err() {
                        dropped += 1;
                    }
                }
                if dropped > 0 {
                    s.input_overruns.fetch_add(dropped, Ordering::Relaxed);
                }
            },
            move |e| eprintln!("input stream error: {e}"),
            None,
        )
        .context("building input stream")?;

    let s = stats.clone();
    let out_stream = out_dev
        .build_output_stream(
            &out_cfg,
            move |data: &mut [f32], _: &cpal::OutputCallbackInfo| {
                let mut starved = 0u64;
                for frame in data.chunks_mut(out_ch) {
                    let v = match out_rx.pop() {
                        Ok(v) => v,
                        Err(_) => {
                            starved += 1;
                            0.0
                        }
                    };
                    for ch in frame.iter_mut() {
                        *ch = v;
                    }
                }
                if starved > 0 {
                    s.output_underruns.fetch_add(starved, Ordering::Relaxed);
                }
                s.ring_fill.store(out_rx.slots() as u64, Ordering::Relaxed);
            },
            move |e| eprintln!("output stream error: {e}"),
            None,
        )
        .context("building output stream")?;

    let worker_stats = stats.clone();
    let worker_stop = stop.clone();
    let target_fill = cfg.target_fill_frames * HOP_SIZE;
    let worker = std::thread::Builder::new()
        .name("voicemic-dsp".into())
        .spawn(move || {
            if let Err(e) = worker_loop(
                make_enhancer,
                &mut in_rx,
                &mut out_tx,
                in_rate,
                out_rate,
                target_fill,
                worker_stats,
                worker_stop,
            ) {
                eprintln!("worker failed: {e:#}");
            }
        })
        .context("spawning worker")?;

    in_stream.play().context("starting input stream")?;
    out_stream.play().context("starting output stream")?;

    while !stop.load(Ordering::Relaxed) {
        std::thread::sleep(std::time::Duration::from_millis(50));
    }

    drop(in_stream);
    drop(out_stream);
    worker.join().map_err(|_| anyhow!("worker panicked"))?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn worker_loop<F>(
    make_enhancer: F,
    in_rx: &mut rtrb::Consumer<f32>,
    out_tx: &mut rtrb::Producer<f32>,
    in_rate: u32,
    out_rate: u32,
    target_fill: usize,
    stats: Arc<SharedStats>,
    stop: Arc<AtomicBool>,
) -> Result<()>
where
    F: FnOnce() -> Result<Box<dyn Enhancer>>,
{
    let mut enhancer = make_enhancer()?;
    println!("Enhancer: {}", enhancer.describe());

    // Input rate conversion to the model's fixed 48 kHz. Ratio is constant.
    let mut up = (in_rate != SAMPLE_RATE)
        .then(|| {
            FastFixedIn::<f32>::new(
                SAMPLE_RATE as f64 / in_rate as f64,
                1.1,
                PolynomialDegree::Cubic,
                RESAMPLER_CHUNK,
                1,
            )
        })
        .transpose()
        .map_err(|e| anyhow!("input resampler: {e}"))?;

    // Output side. This carries the drift trim even when the rates already match,
    // so it is always present.
    let mut down = FastFixedIn::<f32>::new(
        out_rate as f64 / SAMPLE_RATE as f64,
        1.0 + 2.0 * MAX_DEVIATION,
        PolynomialDegree::Cubic,
        RESAMPLER_CHUNK,
        1,
    )
    .map_err(|e| anyhow!("output resampler: {e}"))?;

    let mut drift = DriftController::new(target_fill);
    let mut times = FrameTimes::new();

    let mut dev_in: Vec<f32> = Vec::with_capacity(RESAMPLER_CHUNK * 4);
    let mut at48: Vec<f32> = Vec::with_capacity(RESAMPLER_CHUNK * 8);
    let mut frame_in = vec![0.0f32; HOP_SIZE];
    let mut frame_out = vec![0.0f32; HOP_SIZE];
    let up_cap = up.as_ref().map_or(HOP_SIZE * 4, |r| r.output_frames_max());
    let mut up_out = vec![vec![0.0f32; up_cap]];
    let mut down_out = vec![vec![0.0f32; down.output_frames_max()]];

    let mut since_report = Instant::now();

    while !stop.load(Ordering::Relaxed) {
        // Pull whatever the input callback has produced.
        let want = up.as_ref().map_or(HOP_SIZE, |r| r.input_frames_next());
        if in_rx.slots() < want {
            std::thread::sleep(std::time::Duration::from_micros(500));
            continue;
        }
        dev_in.clear();
        for _ in 0..want {
            match in_rx.pop() {
                Ok(v) => dev_in.push(v),
                Err(_) => break,
            }
        }

        match up.as_mut() {
            Some(r) => {
                let (_, produced) = r
                    .process_into_buffer(&[&dev_in[..]], &mut up_out, None)
                    .map_err(|e| anyhow!("input resample: {e}"))?;
                at48.extend_from_slice(&up_out[0][..produced]);
            }
            None => at48.extend_from_slice(&dev_in),
        }

        while at48.len() >= HOP_SIZE {
            frame_in.copy_from_slice(&at48[..HOP_SIZE]);
            at48.drain(..HOP_SIZE);

            let t0 = Instant::now();
            enhancer.process_frame(&frame_in, &mut frame_out)?;
            let us = t0.elapsed().as_micros() as u64;
            times.record_us(us);
            if us > FRAME_DEADLINE_US {
                stats.deadline_misses.fetch_add(1, Ordering::Relaxed);
            }

            // Trim the output rate to hold the ring's occupancy steady. Fill is
            // the integral of the clock error, so this is what stops two devices
            // on independent crystals from drifting apart over a long call.
            let fill = stats.ring_fill.load(Ordering::Relaxed) as usize;
            let ratio = drift.update(fill);
            stats
                .drift_ratio_nano
                .store((ratio * 1e9) as u64, Ordering::Relaxed);
            down.set_resample_ratio_relative(ratio, true)
                .map_err(|e| anyhow!("drift ratio {ratio}: {e}"))?;

            let (_, produced) = down
                .process_into_buffer(&[&frame_out[..]], &mut down_out, None)
                .map_err(|e| anyhow!("output resample: {e}"))?;
            for &v in &down_out[0][..produced] {
                let _ = out_tx.push(v);
            }

            stats.frames_done.fetch_add(1, Ordering::Relaxed);
        }

        if since_report.elapsed().as_millis() >= 500 {
            stats
                .mean_us
                .store(times.mean_us() as u64, Ordering::Relaxed);
            stats
                .p50_us
                .store(times.percentile_us(0.50), Ordering::Relaxed);
            stats
                .p99_us
                .store(times.percentile_us(0.99), Ordering::Relaxed);
            stats.max_us.store(times.max_us(), Ordering::Relaxed);
            since_report = Instant::now();
        }
    }

    if times.count() == 0 {
        bail!("worker processed no frames; check that the input device is delivering audio");
    }
    Ok(())
}
