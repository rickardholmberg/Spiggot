# voicemic

Live DeepFilterNet speech enhancement bridged into a macOS virtual microphone.

This is the first test in a larger project (see `/root/.claude/plans/` or the
project notes): before training anything, find out whether a neural enhancer can
sit in the live microphone path on an M1 Pro inside a ~50%-of-one-core budget and
a call-latency budget, without glitching over a 45-minute call.

DeepFilterNet is noise suppression plus mild dereverberation. It does not add
bandwidth and does not change tone, so it will not sound like a studio. What it
produces here is a working virtual mic, a measured latency/CPU/stability envelope,
and the open-source baseline row for later evaluation.

## Measured results

M1 Pro, 3000 frames (30 s) per configuration, 1 ONNX intra-op thread, plugged in.

| Model | Mode | mean | p99 | p99.9 | max | RTF | worst frame vs deadline |
|---|---|---|---|---|---|---|---|
| **dfn3_h0** | **combined** | **0.40** | **0.54** | **0.62** | **0.86** | **0.040** | **8.6%** |
| dfn2_h0 | combined | 0.46 | 0.62 | 0.74 | 0.83 | 0.046 | 8.3% |
| dfn3 | combined | 0.41 | 0.56 | 0.85 | 1.01 | 0.041 | 10.1% |
| dfn2 | combined | 0.46 | 0.64 | 0.78 | 1.46 | 0.046 | 14.6% |
| dfn2_ll | combined | 0.46 | 0.67 | 0.91 | 1.15 | 0.046 | 11.5% |
| **dfn3_ll** | **combined** | **1.15** | **1.55** | **2.45** | **2.79** | **0.115** | **27.9%** |
| dfn3_h0 | split | 1.69 | 2.16 | 2.61 | 3.71 | 0.169 | 37.1% |
| dfn3 | split | 1.78 | 2.26 | 3.57 | 9.45 | 0.178 | 94.5% |
| dfn2_h0 | split | 1.95 | 2.40 | 2.54 | 3.32 | 0.195 | 33.2% |
| dfn3_ll | split | 2.78 | 3.30 | 3.74 | 4.11 | 0.278 | 41.1% |
| dfn2_ll | split | 1.97 | 2.43 | 4.91 | 28.42 | 0.197 | 284% |
| dfn2 | split | 2.00 | 2.51 | 10.18 | 29.83 | 0.200 | 298% |

All times in milliseconds against a 10 ms deadline.

### Compute is not the constraint

`dfn3_h0` in combined mode uses 4% of one core, with its worst frame at 8.6% of the
deadline. Against a 50%-of-a-core budget that is roughly 12x headroom, which leaves
around 0.46 RTF for a generative second stage. The front-end is close to free.

### Session mode costs 4.2x, and the library default picks the slow one

`deepfilter-rt`'s `SessionMode::Auto` prefers split streaming whenever the split
ONNX files are present, which every bundled model directory has. Split costs
4.2-4.3x the mean of combined on every model measured. `voicemic` defaults to
`--mode combined`.

Split also has far worse tails. Combined keeps max within 1.3-2.3x of p99; split
reaches 11.9x on `dfn2`, with a p99.9 of 10.18 ms that is already over deadline.
The two ~29 ms outliers landed on consecutive runs and may be an extrinsic
scheduling event rather than the model, but split loses on the mean anyway.

### Model choice is a quality decision, not a cost one

Both candidates fit the CPU budget with room to spare, so pick on latency and
quality:

| | `dfn3_h0` combined | `dfn3_ll` combined |
|---|---|---|
| worst frame | 0.86 ms (8.6%) | 2.79 ms (27.9%) |
| jitter buffer needed | 2 frames | 2 frames |
| model algorithmic delay | 30 ms | 10 ms |
| model delay contribution | 30 ms | 10 ms |
| quality (upstream, vs Tract) | corr 0.999991, SNR 47.6 dB | corr 0.999605, SNR 31.0 dB |

`dfn3_ll` costs 2.9x more per frame, but 2.79 ms is still far inside the 10 ms
deadline, so it needs the same 2-frame jitter buffer as `dfn3_h0`. Its 20 ms
latency saving is therefore real rather than clawed back by a deeper buffer.

Whether that 20 ms is enough to hit a call target depends on the device buffer,
which CoreAudio chooses; see [Latency](#latency). Use `dfn3_h0` when latency does
not matter (recording, DAW monitoring) and `dfn3_ll` for calls. Decide between them
by listening, not by CPU.

## Setup

### 1. Build

```sh
cargo build --release
```

The `ort` build script downloads ONNX Runtime on first build, and `build.rs`
records where it landed along with the model directory that ships inside the
`deepfilter-rt` checkout. Nothing else is needed for `bench`, `file` or `doctor` --
no separate model clone, and no environment variables.

### 2. Check

```sh
./target/release/voicemic doctor
```

Reports the runtime it found and how, the model directory and its lookahead
settings, whether one frame actually processes, and on macOS the CoreAudio devices
and microphone permission. Every FAIL line says what to do.

### 3. Install BlackHole (only for `run`)

```sh
brew install --cask blackhole-2ch
```

BlackHole is a loopback device: `voicemic` writes to its output side and Zoom
selects it as a microphone. This is Phase 2 of the plan; Phase 3 replaces it with a
real virtual input device built on libASPL, which removes the dependency.

### On finding ONNX Runtime

`deepfilter-rt` calls `ort::init_from("libonnxruntime")` with a hardcoded leaf name
and ignores `ORT_DYLIB_PATH`, so it depends on the dynamic loader finding a file
under that exact name. That cannot be made reliable on macOS: SIP strips `DYLD_*`
from the environment whenever a protected system binary runs, and that includes the
shell, so a search path exported by the user never reaches a binary launched from a
script. It also breaks under the hardened runtime the signed `.app` will need for
microphone access.

`voicemic` sidesteps this by loading the library itself, by absolute path, before
`deepfilter-rt` gets a chance to look. `ort` caches the handle in a `OnceLock`, so
its later lookup finds the library already loaded and succeeds. Resolution order:
`--ort-lib`, then `ORT_DYLIB_PATH` (which `voicemic` honours even though
`deepfilter-rt` does not), then the path recorded at build time, then a search of
the executable directory and the Homebrew prefixes.

If discovery ever fails, pass the path explicitly:

```sh
voicemic --ort-lib /path/to/libonnxruntime.dylib doctor
```

## Usage

Model defaults to the bundled `dfn3_h0`; pass a directory to override.

```sh
# Check every precondition first.
voicemic doctor

# Phase 1 gate: what does a frame cost on this machine?
voicemic bench --mode combined --threads 1

# All variants and modes. Takes a models directory, or none for the bundled one.
./scripts/bench_matrix.sh /path/to/deepfilter-rt/models

# Fidelity check against upstream `deep-filter -D`.
voicemic file in48k.wav out.wav --align

# Live: microphone -> DeepFilterNet -> BlackHole.
voicemic run --jitter-frames 2

# Control case: same bridge, no model. Isolates bridge cost from model cost.
voicemic run --bypass
```

Then set BlackHole 2ch as the microphone in Zoom/Teams/OBS.

`run` prints once a second:

```
frames    4800 | mean  0.40 p50  0.39 p99  0.54 max  0.86 ms | ring   960 | drift +0.0021% | under 0 over 0 late 0
```

`under`/`over`/`late` are the numbers that decide whether this is usable. A clean
45-minute run at zero is the pass criterion.

## Latency

Only two terms are known ahead of time:

| Term | Value | Basis |
|---|---|---|
| Model algorithmic delay | 10 ms (`_ll`) / 30 ms (others) | `delay_samples()` = `(960 - 480) + lookahead x 480` |
| Jitter buffer | 10 ms per `--jitter-frames` | by construction: ring held at `frames x 480` samples |

The device buffers are chosen by CoreAudio unless `--buffer-frames` is passed, and
they land on both sides of the chain, so they dominate the uncertainty. A
480-sample frame-assembly quantum adds a further 0-10 ms depending on where a
sample falls relative to the boundary.

`voicemic run` prints the breakdown once both callbacks have reported the block
size actually negotiated:

```
latency: input buffer 10.7 + framing 0-10.0 + model 10.0 + jitter 20.0 + output buffer 10.7 = 51.3-61.3 ms
```

Sensitivity to the device buffer, for `dfn3_ll` with 2 jitter frames:

| Device block | Total (min-max) |
|---|---|
| 128 frames | 35-45 ms |
| 256 frames | 41-51 ms |
| 512 frames | 51-61 ms |

So the model choice is worth a fixed 20 ms (`dfn3_ll` against `dfn3_h0`) and the
buffer size is worth up to 16 ms on top. Reaching ~40 ms needs `dfn3_ll` **and**
small device buffers; `--buffer-frames 128` is the lever.

None of this is measured end to end. The click test is what settles it.

## Architecture

```
mic ──► input callback ──[rtrb ring]──► worker thread ──[rtrb ring]──► output callback ──► BlackHole
        (copy only)                     resample → 480-frame → DFN                (copy only)
                                        → drift-trimmed resample
```

The audio callbacks only copy. Inference runs on a worker thread, because a
worst-case frame can exceed a small callback's period and would otherwise drop
audio continuously.

Two devices means two clocks. The output ring's fill level is the integral of the
rate error, so `drift.rs` holds it at a target by trimming the output resampler
ratio within ±0.5% (inaudible on speech). Without this the bridge glitches after
minutes rather than seconds.

## Layout

Everything that can be reasoned about without an audio device or an ONNX runtime
is in the always-compiled modules and is unit-tested on any platform:

- `stats.rs` — allocation-free frame-time histogram, percentiles, XRun counters
- `drift.rs` — clock-drift controller, with a closed-loop convergence test
- `delay.rs` — dry/wet alignment delay line
- `enhancer.rs` — `Enhancer` trait, `Passthrough`, and the DeepFilterNet impl

Device I/O (`bridge.rs`) sits behind the `audio` feature and inference behind
`dfn`, so `cargo test --no-default-features` verifies the tricky parts off a Mac.

## Notes

- `ort` is pinned to `=2.0.0-rc.11`. `deepfilter-rt` requests `2.0.0-rc.11`, a
  prerelease range that also matches rc.12+, and rc.13 made `ort::Error` generic.
  Without the exact pin the build fails inside `deepfilter-rt`.
- `deepfilter-rt` is pinned by revision; it is not published to crates.io.
- Microphone permission: a bare binary run from Terminal inherits Terminal's TCC
  grant. Wrap it in a signed `.app` with `NSMicrophoneUsageDescription` before
  judging results. `voicemic doctor` opens an input stream to check this for real.
- The `coreml` feature routes ONNX Runtime through CoreML. Measure before
  enabling: at 100 frames/s, per-call dispatch overhead can lose to plain CPU for
  a model this small.
