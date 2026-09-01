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

Full numbers and caveats in `../docs/first-test-results.md`. Two findings drive
the defaults:

**Session mode costs ~2.3x, and the library's default picks the slow one.**
`deepfilter-rt`'s `SessionMode::Auto` prefers split streaming whenever the split
ONNX files are present, which every bundled model directory has. Combined
streaming is the default here instead.

**The low-latency variant is the expensive one.** `dfn3_ll` trades 20 ms of
algorithmic delay for 2.3x the per-frame cost. `dfn3_h0` was both the cheapest
and, per upstream, the best quality — at 30 ms delay.

| Model | Mode | mean | p99 | max | RTF |
|---|---|---|---|---|---|
| dfn3_h0 | combined | 0.93 ms | 1.17 ms | 1.26 ms | 0.093 |
| dfn3 | combined | 1.06 ms | 1.41 ms | 1.47 ms | 0.106 |
| dfn3_h0 | split | 2.32 ms | 3.10 ms | 3.48 ms | 0.232 |
| dfn3 | split | 2.44 ms | 3.36 ms | 3.43 ms | 0.244 |
| dfn3_ll | combined | 2.48 ms | 3.04 ms | 3.22 ms | 0.248 |
| dfn3_ll | split | 3.76 ms | 5.01 ms | 5.23 ms | 0.376 |

Measured on x86_64 Linux, 1 ONNX thread, 800 frames of synthetic input. **These
are not M1 Pro numbers.** The ordering should carry across architectures; the
absolute values will not. Re-run `scripts/bench_matrix.sh` on the target machine
before drawing conclusions.

## Setup

### 1. Build

```sh
cargo build --release
```

The `ort` build script downloads ONNX Runtime on first build.

### 2. Make ONNX Runtime loadable

`deepfilter-rt` calls `ort::init_from("libonnxruntime")` with a hardcoded leaf
name and ignores `ORT_DYLIB_PATH`. The shipped file is `libonnxruntime.dylib`,
which `dlopen` will not resolve from that name, so an otherwise correct build
fails at first use. Run:

```sh
./scripts/ort_env.sh
```

and add the `export DYLD_LIBRARY_PATH=...` line it prints to your shell. It must
be set before launching `voicemic`: the dynamic loader reads it at process start.

### 3. Get the models

The model directories ship in the `deepfilter-rt` repository, not in the crate:

```sh
git clone --depth 1 https://github.com/shimondoodkin/deepfilter-rt /tmp/dfrt
```

Use `/tmp/dfrt/models/dfn3_h0` and friends as the `<model>` argument.

### 4. Install BlackHole

```sh
brew install --cask blackhole-2ch
```

Only needed for `run`. `bench` and `file` work without it. BlackHole is a
loopback device: `voicemic` writes to its output side, and Zoom selects it as a
microphone. This is Phase 2 of the plan; Phase 3 replaces it with a real virtual
input device built on libASPL, which removes the dependency.

## Usage

```sh
# Phase 1 gate: what does a frame cost on this machine?
voicemic bench /tmp/dfrt/models/dfn3_h0 --mode combined --threads 1

# All variants and modes.
./scripts/bench_matrix.sh /tmp/dfrt/models

# Fidelity check against upstream `deep-filter -D`.
voicemic file /tmp/dfrt/models/dfn3_h0 in48k.wav out.wav --align

# Live: microphone -> DeepFilterNet -> BlackHole.
voicemic run /tmp/dfrt/models/dfn3_h0 --jitter-frames 2

# Control case: same bridge, no model. Isolates bridge cost from model cost.
voicemic run /tmp/dfrt/models/dfn3_h0 --bypass
```

Then set BlackHole 2ch as the microphone in Zoom/Teams/OBS.

`run` prints once a second:

```
frames    4800 | mean  0.93 p50  0.90 p99  1.17 max  1.26 ms | ring  1440 | drift +0.0021% | under 0 over 0 late 0
```

`under`/`over`/`late` are the numbers that decide whether this is usable. A clean
45-minute run at zero is the pass criterion.

## Latency

Total is the sum of device buffer, model delay, jitter buffer, and output buffer.
The jitter buffer is the tunable term, and `bench` sizes it: it must cover the
worst frame, not the mean.

| Term | dfn3_h0 / dfn3 | dfn3_ll |
|---|---|---|
| Model algorithmic delay | 30 ms (1440 samples) | 10 ms (480 samples) |
| Jitter buffer (`--jitter-frames`) | 10 ms per frame | 10 ms per frame |
| Device buffers | set by `--buffer-frames` | same |

`dfn3_ll` buys 20 ms of model delay at 2.3x the per-frame cost, which may push the
jitter buffer back up and give the 20 ms straight back. Measure both.

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
  judging results.
- The `coreml` feature routes ONNX Runtime through CoreML. Measure before
  enabling: at 100 frames/s, per-call dispatch overhead can lose to plain CPU for
  a model this small.
