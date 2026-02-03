#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf "==> %s\n" "$*"; }
die() { printf "ERROR: %s\n" "$*" >&2; exit 1; }

say "Bootstrapping dependencies"

# --- Syphon ---
if [[ ! -d "$ROOT_DIR/Frameworks/Syphon.framework" ]]; then
  say "Syphon.framework not found; building it now…"
  "$ROOT_DIR/scripts/update_syphon_framework.sh"
else
  say "Syphon.framework present."
fi

# --- libgphoto2 (build-time dependency; bundled into app at build/package time) ---
# We do not commit libgphoto2 into this repo. Instead we bundle it into the .app via
# scripts/embed_gphoto2_runtime.sh (an Xcode build phase).

if command -v brew >/dev/null 2>&1; then
  if brew list --versions libgphoto2 >/dev/null 2>&1; then
    say "Homebrew libgphoto2 is installed (ok)."
  else
    say "Homebrew detected but libgphoto2 is not installed."
    say "Install with: brew install libgphoto2"
  fi
else
  say "Homebrew not found."
  say "You can still build if libgphoto2 is installed elsewhere, but the bundling script"
  say "currently knows how to locate it via Homebrew (/opt/homebrew or /usr/local)."
fi

say "Done."
