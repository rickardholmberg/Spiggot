# First test: DeepFilterNet as a virtual microphone — results

Status: **Phase 1 complete off-target. First M1 Pro measurement taken. Phases 2 and 3 not yet run.**

## What has been verified

| Claim | Method | Result |
|---|---|---|
| `deepfilter-rt` builds and runs | `cargo build`, `voicemic bench` | Yes, after two fixes below |
| Per-frame cost and tail | 800-frame benchmark, 6 configs | Table below |
| Session mode dominates cost | benchmark matrix | ~2.3x, and the library default picks the slow mode |
| `dfn3_ll` is cheaper than `dfn3` | benchmark matrix | **False** — it costs 2.3x more |
| Drift controller converges | closed-loop unit test | Converges under 0.1% clock mismatch |
| All feature combinations compile | `cargo check` × 3 | Clean, no warnings |

## What has NOT been verified

- **Nothing has run on an M1 Pro.** All numbers below are x86_64 Linux. The
  relative ordering should carry; absolute values will not.
- **`bridge.rs` has never executed.** It typechecks against cpal 0.15, rubato
  0.16 and rtrb 0.3, and no audio has passed through it. Every runtime property
  — XRun behaviour, drift correction against real hardware clocks, device
  reconnect, end-to-end latency — is untested.
- **No fidelity comparison against upstream `deep-filter`.** The `file`
  subcommand exists for it; it has not been run.
- **No real speech.** The benchmark uses a deterministic synthetic signal.
  Inference cost is input-independent for this architecture, but nobody has
  listened to the output.

## The macOS failure, and what caused it

The first run of `scripts/bench_matrix.sh` on the M1 Pro reported `FAILED` for all
twelve configurations. The same binary invoked directly worked:

```
$ ./target/release/voicemic bench /tmp/dfrt/models/dfn3_h0 --frames 100
Model: DeepFilterNet3-H0 [combined streaming] 1 threads, delay 1440 samples
  mean 0.47 ms   p99 0.62 ms   max 0.74 ms   RTF 0.047
```

**Cause: macOS SIP strips `DYLD_*` when a protected system binary is executed.**
Running the script executes `/usr/bin/env` and then `bash`, both protected, so the
`DYLD_LIBRARY_PATH` that made the direct invocation work was gone before `voicemic`
started. Reproduced in the Linux container, which shows the identical split: with
`LD_LIBRARY_PATH` set the script produces the full matrix, without it all twelve
rows fail.

Two separate defects:

- **Design.** `voicemic` depended on ambient shell state to find its own runtime.
  The original workaround, `scripts/ort_env.sh`, printed a `DYLD_LIBRARY_PATH`
  export line for the user to copy; given SIP that could only ever work for direct
  invocation from an interactive shell.
- **Reporting.** `bench_matrix.sh` captured stdout and stderr and discarded them on
  failure, so a one-line environment problem presented as twelve identical `FAILED`
  rows with no diagnostic. This is what turned it into a round-trip.

### Fix

`voicemic` now loads ONNX Runtime itself, by absolute path, before `deepfilter-rt`
attempts its hardcoded leaf-name lookup. `ort` caches the handle in a `OnceLock`
populated through `get_or_try_init` (`ort/src/lib.rs:131`), so the later lookup
finds the library already loaded and returns `Ok` without searching. No environment
variable is involved, and it survives the hardened runtime the signed `.app` will
need.

`build.rs` records the path at build time from `deepfilter-rt`'s
`cargo:ort_lib_dir` metadata (it declares `links = "deepfilter_rt"`, so Cargo
forwards it as `DEP_DEEPFILTER_RT_ORT_LIB_DIR`). The same mechanism supplies
`cargo:models_dir`, so the bundled models resolve automatically and no separate
clone is needed.

Verified on Linux, which takes the identical `not(android), not(windows)` code
path: `env -u LD_LIBRARY_PATH -u ORT_DYLIB_PATH voicemic bench` succeeds, and the
full twelve-configuration matrix runs with a bare environment.

`scripts/ort_env.sh` was deleted rather than demoted. Its premise -- exporting a
loader search path -- is the thing that does not work, and `--ort-lib` covers the
case where discovery fails.

## First M1 Pro measurement

`dfn3_h0`, combined streaming, 1 thread, 100 frames, plugged in:

| | M1 Pro | Linux container |
|---|---|---|
| mean | 0.47 ms | 0.93-1.80 ms |
| max | 0.74 ms | 1.26-2.80 ms |
| RTF | 0.047 | 0.093-0.180 |

The worst frame used **7% of the 10 ms deadline**, against a budget of 50%.

Provisional: one second of audio, plugged in, and the tail is what sizes the jitter
buffer. Container figures move substantially run to run (`dfn3_h0` combined measured
0.93, 1.14 and 1.80 ms mean across three runs), so only M1 Pro numbers should be
quoted. The ordering has held in every run.

## Benchmark (container, ordering only)

x86_64 Linux container, 1 ONNX intra-op thread, 800 frames (8 s) of synthetic
input, ONNX Runtime 1.23.2 CPU, `combined` and `split` session modes. Absolute
values are noise-dominated in this environment; read the ordering, not the numbers.

| Model | Mode | mean | p99 | max | RTF | % of 10 ms deadline (worst) |
|---|---|---|---|---|---|---|
| dfn3_h0 | combined | 0.93 ms | 1.17 ms | 1.26 ms | 0.093 | 13% |
| dfn3 | combined | 1.06 ms | 1.41 ms | 1.47 ms | 0.106 | 15% |
| dfn3_h0 | split | 2.32 ms | 3.10 ms | 3.48 ms | 0.232 | 35% |
| dfn3 | split | 2.44 ms | 3.36 ms | 3.43 ms | 0.244 | 34% |
| dfn3_ll | combined | 2.48 ms | 3.04 ms | 3.22 ms | 0.248 | 32% |
| dfn3_ll | split | 3.76 ms | 5.01 ms | 5.23 ms | 0.376 | 52% |

Upstream reports mean 1.70 ms / max 5.21 ms and RTF 0.11 on Windows; the
combined-mode figures here are consistent with that once hardware differs.

## Findings that change the plan

### 1. The default session mode costs ~2.3x

`SessionMode::Auto` prefers split streaming whenever the split ONNX files are
present, and every bundled model directory contains them. Split measured 2.32 ms
mean against 0.93 ms for combined on the same model. Upstream's own table shows
the same gap (RTF 0.34 vs 0.11).

`voicemic` therefore defaults to `--mode combined` rather than leaving it to Auto.

### 2. `dfn3_ll` is the wrong default

The plan assumed the low-latency variant was the obvious choice for calls: 10 ms
algorithmic delay instead of 30 ms. Measured, `dfn3_ll` costs 2.48 ms per frame
against 1.06 ms for `dfn3` — 2.3x more for 20 ms less delay. Upstream also
reports lower quality for it (correlation 0.999605 and SNR 31.0 dB against
0.999991 and 47.6 dB).

Since a larger per-frame tail forces a deeper jitter buffer, and each jitter
frame costs 10 ms, `dfn3_ll` can give the 20 ms straight back.

**Revised default: `dfn3_h0` with combined streaming** — the cheapest measured
config (0.93 ms mean, 1.26 ms max) and the one upstream calls best quality, at
30 ms algorithmic delay.

### 3. Two upstream defects block a clean build

**`ort` version float.** `deepfilter-rt` requests `ort = "2.0.0-rc.11"`. That
prerelease range also matches rc.12 and rc.13, and rc.13 made `ort::Error`
generic over the failing builder type. A fresh build resolves to rc.13 and fails
inside `deepfilter-rt` with a missing `From<ort::Error<SessionBuilder>>`. Fixed
by pinning `ort = "=2.0.0-rc.11"` in this crate, which constrains the shared
resolution.

**Hardcoded dylib leaf name.** `deepfilter-rt` calls
`ort::init_from("libonnxruntime")` and ignores `ORT_DYLIB_PATH`. The shipped file
is `libonnxruntime.dylib` on macOS and `libonnxruntime.so.N` on Linux, and
`dlopen` resolves neither from that name, so a correct build fails at first use
with an opaque error. Worked around with `scripts/ort_env.sh`, which creates a
correctly named symlink, plus a targeted error message pointing at it. Both are
worth reporting upstream.

## Next steps

1. Re-run `scripts/bench_matrix.sh` on the M1 Pro now that it works, plugged in and
   on battery. Battery matters: the chip downclocks and may schedule onto
   efficiency cores.
2. Compare `voicemic file --align` against upstream `deep-filter -D` and check
   correlation (upstream reports 0.999991 for combined streaming).
3. Measure the CoreML feature against CPU. At 100 frames/s, per-call dispatch
   overhead can lose to plain CPU for a model this size. The answer generalises
   to every later model.
4. First live run against BlackHole. Watch `under`/`over`/`late`; they are the
   pass criterion, and `bridge.rs` has never executed.
5. Impulse click test for true end-to-end latency; do not trust the arithmetic.
6. 45-minute stability run on AirPods and built-in, then provoke sleep/wake,
   AirPods reconnect, and mid-run device switch.
