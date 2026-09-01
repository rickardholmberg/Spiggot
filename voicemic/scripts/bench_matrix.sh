#!/usr/bin/env bash
# Per-frame cost across model variants and ONNX session modes.
#
# This is the Phase 1 gate. The number that matters is the tail, not the mean:
# the worst frame sizes the jitter buffer, and the jitter buffer dominates
# end-to-end latency. Run it plugged in and again on battery -- Apple Silicon
# downclocks and may schedule onto efficiency cores.
set -euo pipefail

MODELS_DIR="${1:?usage: bench_matrix.sh <deepfilter-rt-models-dir> [frames]}"
FRAMES="${2:-3000}"
BIN="${VOICEMIC_BIN:-./target/release/voicemic}"

printf "%-10s %-10s %8s %8s %8s %8s %8s\n" MODEL MODE MEANms P99ms P999ms MAXms RTF
for m in dfn3 dfn3_ll dfn3_h0 dfn2 dfn2_ll dfn2_h0; do
  [ -d "$MODELS_DIR/$m" ] || continue
  for mode in combined split; do
    out=$("$BIN" bench "$MODELS_DIR/$m" --frames "$FRAMES" --mode "$mode" --threads 1 2>&1) || { 
      printf "%-10s %-10s %8s\n" "$m" "$mode" "FAILED"; continue; }
    printf "%-10s %-10s %8s %8s %8s %8s %8s\n" "$m" "$mode" \
      "$(awk '/^  mean/{print $2}'  <<<"$out")" \
      "$(awk '/^  p99  /{print $2}' <<<"$out")" \
      "$(awk '/^  p99.9/{print $2}' <<<"$out")" \
      "$(awk '/^  max/{print $2}'   <<<"$out")" \
      "$(awk '/^  RTF/{print $2}'   <<<"$out")"
  done
done
