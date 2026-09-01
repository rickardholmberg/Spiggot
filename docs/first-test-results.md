# First test: DeepFilterNet as a virtual microphone — results

Status: **Phase 1 complete and passed on the target M1 Pro. Phases 2 and 3 not yet run.**

## What has been verified

| Claim | Method | Result |
|---|---|---|
| `deepfilter-rt` builds and runs | `cargo build`, `voicemic bench` | Yes, after two fixes below |
| Per-frame cost and tail | 3000-frame benchmark, 12 configs, M1 Pro | Table below |
| Session mode dominates cost | benchmark matrix | 4.2x on M1 Pro, and the library default picks the slow mode |
| `dfn3_ll` is cheaper than `dfn3` | benchmark matrix | **False** — 2.9x more on M1 Pro |
| Drift controller converges | closed-loop unit test | Converges under 0.1% clock mismatch |
| All feature combinations compile | `cargo check` × 3 | Clean, no warnings |

## What has NOT been verified

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

## Phase 1 result: passed, with ~12x headroom

M1 Pro, 3000 frames (30 s) per configuration, 1 ONNX intra-op thread, plugged in.
Times in milliseconds against a 10 ms deadline.

| Model | Mode | mean | p99 | p99.9 | max | RTF | worst vs deadline |
|---|---|---|---|---|---|---|---|
| dfn3_h0 | combined | 0.40 | 0.54 | 0.62 | 0.86 | 0.040 | 8.6% |
| dfn2_h0 | combined | 0.46 | 0.62 | 0.74 | 0.83 | 0.046 | 8.3% |
| dfn3 | combined | 0.41 | 0.56 | 0.85 | 1.01 | 0.041 | 10.1% |
| dfn2_ll | combined | 0.46 | 0.67 | 0.91 | 1.15 | 0.046 | 11.5% |
| dfn2 | combined | 0.46 | 0.64 | 0.78 | 1.46 | 0.046 | 14.6% |
| dfn3_ll | combined | 1.15 | 1.55 | 2.45 | 2.79 | 0.115 | 27.9% |
| dfn2_h0 | split | 1.95 | 2.40 | 2.54 | 3.32 | 0.195 | 33.2% |
| dfn3_h0 | split | 1.69 | 2.16 | 2.61 | 3.71 | 0.169 | 37.1% |
| dfn3_ll | split | 2.78 | 3.30 | 3.74 | 4.11 | 0.278 | 41.1% |
| dfn3 | split | 1.78 | 2.26 | 3.57 | 9.45 | 0.178 | 94.5% |
| dfn2_ll | split | 1.97 | 2.43 | 4.91 | 28.42 | 0.197 | 284% |
| dfn2 | split | 2.00 | 2.51 | 10.18 | 29.83 | 0.200 | 298% |

**The gate is passed.** `dfn3_h0` combined runs at RTF 0.040 with its worst frame
at 8.6% of the deadline, against a 50%-of-a-core budget. That is roughly 12x
headroom and leaves about 0.46 RTF for a generative second stage. Compute is not
the binding constraint for the front end.

The M1 Pro is 2.3-2.8x faster than the Linux container on the same configurations,
and far more consistent: container means for `dfn3_h0` combined ranged 0.93-1.80 ms
across three runs of the same build, against 0.40 ms here.

### Session mode costs 4.2x

Split streaming costs 4.2-4.3x the mean of combined on every model measured, wider
than the 2.3x seen in the container and wider than the ~3x upstream reports.
`SessionMode::Auto` selects split whenever the split ONNX files are present, which
every bundled model directory has, so the library default is the expensive one.

Split tails are also much worse. Combined holds max within 1.3-2.3x of p99; split
reaches 11.9x on `dfn2`, whose p99.9 of 10.18 ms is already over deadline. The two
~29 ms outliers (`dfn2` and `dfn2_ll` split) landed on consecutive runs and may be
an extrinsic scheduling event rather than the model. Not worth chasing: split loses
on the mean regardless.

### Correction: the earlier argument against dfn3_ll was wrong

Recorded because it changed a recommendation. Based on container measurements this
document previously argued that `dfn3_ll` was the wrong default, reasoning that its
higher per-frame cost would force a deeper jitter buffer and hand back the 20 ms of
algorithmic delay it saves.

The premise does not hold on the target hardware. `dfn3_ll`'s worst frame is
2.79 ms, well inside the 10 ms deadline, so it needs the same minimum 2-frame
buffer as `dfn3_h0` at 0.86 ms. The 20 ms saving is real.

| | dfn3_h0 combined | dfn3_ll combined |
|---|---|---|
| worst frame | 0.86 ms | 2.79 ms |
| jitter buffer needed | 2 frames | 2 frames |
| model delay | 30 ms | 10 ms |
| total end-to-end (est.) | 55-61 ms | 35-41 ms |
| upstream quality vs Tract | corr 0.999991, SNR 47.6 dB | corr 0.999605, SNR 31.0 dB |

`dfn3_ll` is the only configuration that reaches the ~40 ms call target. The choice
between the two is now a listening test, not a CPU measurement. What survives from
the earlier finding is the direction (`_ll` is the more expensive variant, contrary
to the assumption that a low-latency model would be cheaper) and the combined-mode
default.

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

1. Re-run the matrix **on battery**. Done plugged in; the chip downclocks and may
   schedule onto efficiency cores, and the jitter buffer must be sized for the
   worse case.
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
