#!/usr/bin/env bash
# Make ONNX Runtime loadable by deepfilter-rt.
#
# deepfilter-rt calls ort::init_from("libonnxruntime") with a hardcoded leaf name
# and ignores ORT_DYLIB_PATH. The shipped file is libonnxruntime.dylib (macOS) or
# libonnxruntime.so.N (Linux), and dlopen resolves neither from that name, so an
# otherwise correct build fails at first use. This creates a correctly named
# symlink and prints the export line to add to your shell.
set -euo pipefail

LINK_DIR="${VOICEMIC_ORT_DIR:-$HOME/.voicemic/ort}"

case "$(uname -s)" in
  Darwin) PATTERN='libonnxruntime*.dylib'; VAR=DYLD_LIBRARY_PATH ;;
  *)      PATTERN='libonnxruntime.so*';    VAR=LD_LIBRARY_PATH ;;
esac

# ort's build script unpacks the runtime under the cargo git checkout or registry.
echo "Searching for $PATTERN under ~/.cargo ..." >&2
LIB=""
for root in "$HOME/.cargo/git/checkouts" "$HOME/.cargo/registry/src" "${CARGO_TARGET_DIR:-target}"; do
  [ -d "$root" ] || continue
  found=$(find "$root" -name "$PATTERN" -type f 2>/dev/null | head -1 || true)
  if [ -n "$found" ]; then LIB="$found"; break; fi
done

if [ -z "$LIB" ]; then
  cat >&2 <<'EOF'
Could not find an ONNX Runtime library.

Build once first so the ort build script downloads it:
    cargo build --release
then re-run this script. Alternatively install ONNX Runtime yourself
(`brew install onnxruntime`) and set VOICEMIC_ORT_LIB to the .dylib path.
EOF
  [ -n "${VOICEMIC_ORT_LIB:-}" ] || exit 1
  LIB="$VOICEMIC_ORT_LIB"
fi

mkdir -p "$LINK_DIR"
ln -sf "$LIB" "$LINK_DIR/libonnxruntime"
echo "Linked: $LINK_DIR/libonnxruntime -> $LIB" >&2
echo >&2
echo "Add this to your shell (the loader reads it at process start, so it must be" >&2
echo "set before launching voicemic, not from inside it):" >&2
echo >&2
echo "export $VAR=\"$LINK_DIR:\${$VAR:-}\""
