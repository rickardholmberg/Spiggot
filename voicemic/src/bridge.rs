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
    /// Frames per input callback, as actually delivered by CoreAudio.
    pub in_block_frames: AtomicU64,
    /// Frames per output callback, as actually requested by CoreAudio.
    pub out_block_frames: AtomicU64,
    /// Enhancer algorithmic delay, in samples.
    pub model_delay_samples: AtomicU64,
}

impl SharedStats {
    pub fn drift_ratio(&self) -> f64 {
        self.drift_ratio_nano.load(Ordering::Relaxed) as f64 / 1e9
    }

    /// End-to-end latency built from what the devices actually negotiated.
    ///
    /// Returns `None` until both callbacks have run at least once, because the
    /// device block size is chosen by CoreAudio and is not known before then.
    /// Guessing it is how an earlier estimate in this repo came out roughly 20 ms
    /// optimistic.
    ///
    /// The frame-assembly term is a range, not a point: the worker consumes whole
    /// 480-sample frames, so a sample waits between 0 and one frame depending on
    /// where it lands relative to the boundary.
    pub fn latency_estimate(&self, jitter_frames: usize) -> Option<LatencyEstimate> {
        let inb = self.in_block_frames.load(Ordering::Relaxed);
        let outb = self.out_block_frames.load(Ordering::Relaxed);
        if inb == 0 || outb == 0 {
            return None;
        }
        let ms = |frames: u64| frames as f64 * 1000.0 / SAMPLE_RATE as f64;
        Some(LatencyEstimate {
            input_buffer_ms: ms(inb),
            framing_ms: ms(HOP_SIZE as u64),
            model_ms: ms(self.model_delay_samples.load(Ordering::Relaxed)),
            jitter_ms: ms((jitter_frames * HOP_SIZE) as u64),
            output_buffer_ms: ms(outb),
        })
    }
}

/// Latency broken into its terms, all in milliseconds.
#[derive(Debug, Clone, Copy)]
pub struct LatencyEstimate {
    pub input_buffer_ms: f64,
    /// Upper bound of the frame-assembly quantum; the lower bound is zero.
    pub framing_ms: f64,
    pub model_ms: f64,
    pub jitter_ms: f64,
    pub output_buffer_ms: f64,
}

impl LatencyEstimate {
    /// Best case: a sample arriving right on a frame boundary.
    pub fn min_ms(&self) -> f64 {
        self.input_buffer_ms + self.model_ms + self.jitter_ms + self.output_buffer_ms
    }

    /// Worst case: a sample arriving just after one.
    pub fn max_ms(&self) -> f64 {
        self.min_ms() + self.framing_ms
    }

    pub fn report(&self) -> String {
        format!(
            "latency: input buffer {:.1} + framing 0-{:.1} + model {:.1} + jitter {:.1} \
             + output buffer {:.1} = {:.1}-{:.1} ms (measured device blocks; \
             confirm with a click test)",
            self.input_buffer_ms,
            self.framing_ms,
            self.model_ms,
            self.jitter_ms,
            self.output_buffer_ms,
            self.min_ms(),
            self.max_ms(),
        )
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
                s.in_block_frames
                    .store((data.len() / in_ch) as u64, Ordering::Relaxed);
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
                s.out_block_frames
                    .store((data.len() / out_ch) as u64, Ordering::Relaxed);
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
    stats
        .model_delay_samples
        .store(enhancer.delay_samples() as u64, Ordering::Relaxed);

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

/// Device and permission checks for `voicemic doctor`. Returns true if all passed.
///
/// Opening an input stream is the only reliable way to tell whether the process
/// actually holds a microphone grant: a binary run from a terminal inherits the
/// terminal's TCC decision, which silently misleads until it is wrapped in a
/// signed `.app` with `NSMicrophoneUsageDescription`.
pub fn doctor_devices() -> bool {
    fn line(label: &str, ok: bool, detail: impl std::fmt::Display) -> bool {
        println!("  [{}] {label}: {detail}", if ok { "ok" } else { "FAIL" });
        ok
    }

    let host = cpal::default_host();

    let inputs: Vec<String> = host
        .input_devices()
        .map(|ds| ds.filter_map(|d| d.name().ok()).collect())
        .unwrap_or_default();
    let outputs: Vec<String> = host
        .output_devices()
        .map(|ds| ds.filter_map(|d| d.name().ok()).collect())
        .unwrap_or_default();

    let mut ok = line("input devices", !inputs.is_empty(), inputs.len());
    ok &= line("output devices", !outputs.is_empty(), outputs.len());

    let blackhole = outputs
        .iter()
        .any(|n| n.to_lowercase().contains("blackhole"));
    // Not fatal: bench and file need no virtual device, only `run` does.
    line(
        "BlackHole",
        blackhole,
        if blackhole {
            "present"
        } else {
            "absent - `run` needs it (brew install --cask blackhole-2ch), bench does not"
        },
    );

    match host.default_input_device() {
        Some(dev) => {
            let name = dev.name().unwrap_or_else(|_| "<unknown>".into());
            match dev.default_input_config() {
                Ok(cfg) => {
                    ok &= line(
                        "default input",
                        true,
                        format!("{name} @ {} Hz, {} ch", cfg.sample_rate().0, cfg.channels()),
                    );
                    // Building the stream is what triggers the TCC prompt or denial.
                    let built = dev.build_input_stream(
                        &cfg.config(),
                        |_: &[f32], _: &cpal::InputCallbackInfo| {},
                        |_| {},
                        None,
                    );
                    ok &= match built {
                        Ok(s) => {
                            let played = s.play().is_ok();
                            line(
                                "microphone permission",
                                played,
                                if played {
                                    "input stream opened"
                                } else {
                                    "stream built but would not start"
                                },
                            )
                        }
                        Err(e) => line("microphone permission", false, format!("{e}")),
                    };
                }
                Err(e) => ok &= line("default input", false, format!("{name}: {e}")),
            }
        }
        None => ok &= line("default input", false, "none"),
    }

    ok
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stats_with(in_b: u64, out_b: u64, model_delay: u64) -> SharedStats {
        let s = SharedStats::default();
        s.in_block_frames.store(in_b, Ordering::Relaxed);
        s.out_block_frames.store(out_b, Ordering::Relaxed);
        s.model_delay_samples.store(model_delay, Ordering::Relaxed);
        s
    }

    #[test]
    fn no_estimate_before_the_devices_have_reported() {
        // Refusing to guess is the point: an earlier estimate in this repo assumed
        // 128- and 256-frame buffers and came out roughly 20 ms optimistic.
        let s = SharedStats::default();
        assert!(s.latency_estimate(2).is_none());

        let s = stats_with(512, 0, 480);
        assert!(
            s.latency_estimate(2).is_none(),
            "one callback is not enough"
        );
    }

    #[test]
    fn dfn3_ll_with_512_frame_buffers() {
        // 512 frames is a common CoreAudio default. dfn3_ll: 480 samples delay.
        let s = stats_with(512, 512, 480);
        let e = s.latency_estimate(2).unwrap();
        assert!((e.input_buffer_ms - 10.667).abs() < 0.01);
        assert!((e.model_ms - 10.0).abs() < 0.01);
        assert!((e.jitter_ms - 20.0).abs() < 0.01);
        assert!((e.framing_ms - 10.0).abs() < 0.01);
        // 10.67 + 10 + 20 + 10.67 = 51.3, plus up to one frame of assembly.
        assert!((e.min_ms() - 51.33).abs() < 0.05, "min was {}", e.min_ms());
        assert!((e.max_ms() - 61.33).abs() < 0.05, "max was {}", e.max_ms());
    }

    #[test]
    fn dfn3_ll_with_128_frame_buffers() {
        let s = stats_with(128, 128, 480);
        let e = s.latency_estimate(2).unwrap();
        // The optimistic case quoted earlier, and it still omits framing.
        assert!((e.min_ms() - 35.33).abs() < 0.05, "min was {}", e.min_ms());
        assert!((e.max_ms() - 45.33).abs() < 0.05, "max was {}", e.max_ms());
    }

    #[test]
    fn standard_model_costs_20ms_more_than_the_ll_variant() {
        // dfn3/dfn3_h0 carry 1440 samples of delay against dfn3_ll's 480.
        let ll = stats_with(256, 256, 480).latency_estimate(2).unwrap();
        let std_ = stats_with(256, 256, 1440).latency_estimate(2).unwrap();
        assert!((std_.min_ms() - ll.min_ms() - 20.0).abs() < 0.01);
    }

    #[test]
    fn each_jitter_frame_costs_ten_milliseconds() {
        let s = stats_with(256, 256, 480);
        let two = s.latency_estimate(2).unwrap().min_ms();
        let three = s.latency_estimate(3).unwrap().min_ms();
        assert!((three - two - 10.0).abs() < 0.01);
    }
}
