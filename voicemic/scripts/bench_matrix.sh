#!/usr/bin/env bash
# Per-frame cost across model variants and ONNX session modes.
#
# This is the Phase 1 gate. The number that matters is the tail, not the mean:
# the worst frame sizes the jitter buffer, and the jitter buffer dominates
# end-to-end latency. Run it plugged in and again on battery -- Apple Silicon
# downclocks and may schedule onto efficiency cores.
#
# Note on environment: this script deliberately does NOT export a library search
# path. voicemic locates ONNX Runtime itself, by absolute path recorded at build
# time. That matters on macOS, where SIP strips DYLD_* whenever a protected system
# binary runs -- including the shell -- so a path exported by the caller never
# reaches the binary through a script. An earlier version of this script relied on
# exactly that and reported FAILED for all twelve configurations while the same
# binary invoked directly worked fine.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: bench_matrix.sh [models-dir] [frames]

  models-dir  directory holding dfn3/, dfn3_ll/, ... Defaults to the models
              bundled with deepfilter-rt, recorded at build time.
  frames      frames per configuration (default 3000, = 30s of audio)

env:
  VOICEMIC_BIN   path to the voicemic binary (default ./target/release/voicemic)
EOF
  exit 2
}

[ "${1:-}" = "-h" ] && usage
[ "${1:-}" = "--help" ] && usage

MODELS_DIR="${1:-}"
FRAMES="${2:-3000}"
BIN="${VOICEMIC_BIN:-./target/release/voicemic}"

if [ ! -x "$BIN" ]; then
  cat >&2 <<EOF
error: voicemic binary not found or not executable at: $BIN

Build it first, from the voicemic/ directory:
    cargo build --release

Or point VOICEMIC_BIN at an existing binary.
EOF
  exit 1
fi

# Preflight. Catches a broken runtime or model directory once, with a real
# explanation, rather than twelve identical failures with none.
echo "Preflight:" >&2
if ! "$BIN" doctor ${MODELS_DIR:+"$MODELS_DIR/dfn3_h0"} >&2; then
  echo >&2
  echo "error: preflight failed. Fix the FAIL lines above before benchmarking." >&2
  exit 1
fi
echo >&2

MODELS=(dfn3 dfn3_ll dfn3_h0 dfn2 dfn2_ll dfn2_h0)
failures=0

printf "%-10s %-10s %8s %8s %8s %8s %8s\n" MODEL MODE MEANms P99ms P999ms MAXms RTF
for m in "${MODELS[@]}"; do
  # With no models-dir the binary resolves its own bundled path, so only skip
  # when an explicit directory was given and this variant is missing from it.
  if [ -n "$MODELS_DIR" ]; then
    [ -d "$MODELS_DIR/$m" ] || continue
    model_arg="$MODELS_DIR/$m"
  else
    model_arg=""
  fi

  for mode in combined split; do
    if [ -z "$model_arg" ] && [ "$m" != "dfn3_h0" ]; then
      # Without an explicit directory only the default model is addressable.
      continue
    fi
    if out=$("$BIN" bench ${model_arg:+"$model_arg"} --frames "$FRAMES" --mode "$mode" --threads 1 2>&1); then
      printf "%-10s %-10s %8s %8s %8s %8s %8s\n" "$m" "$mode" \
        "$(awk '/^  mean/{print $2}'  <<<"$out")" \
        "$(awk '/^  p99  /{print $2}' <<<"$out")" \
        "$(awk '/^  p99.9/{print $2}' <<<"$out")" \
        "$(awk '/^  max/{print $2}'   <<<"$out")" \
        "$(awk '/^  RTF/{print $2}'   <<<"$out")"
    else
      failures=$((failures + 1))
      printf "%-10s %-10s %8s\n" "$m" "$mode" "FAILED"
      # Print the real error. Hiding it is what turned a one-line environment
      # problem into a round-trip.
      echo >&2
      echo "--- $m/$mode failed ---" >&2
      printf '%s\n' "$out" >&2
      echo "--- end $m/$mode ---" >&2
      echo >&2
    fi
  done
done

if [ "$failures" -gt 0 ]; then
  echo >&2
  echo "$failures configuration(s) failed; see the errors above." >&2
  exit 1
fi
