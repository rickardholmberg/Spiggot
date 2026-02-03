#!/usr/bin/env bash
set -euo pipefail

# Xcode Run Script phase: bundle libgphoto2 + its runtime deps (and camlibs) into the app.
#
# This is intentionally "least surprising" for macOS projects:
# - libgphoto2 is a build-time dependency (often installed via Homebrew)
# - the finished .app is self-contained and can be zipped and distributed
#
# Inputs expected from Xcode:
# - TARGET_BUILD_DIR
# - WRAPPER_NAME
# - EXECUTABLE_PATH
# - FRAMEWORKS_FOLDER_PATH
# - UNLOCALIZED_RESOURCES_FOLDER_PATH

say() { printf "[embed_gphoto2] %s\n" "$*"; }
die() { printf "[embed_gphoto2] ERROR: %s\n" "$*" >&2; exit 1; }

APP_DIR="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
APP_EXE="${TARGET_BUILD_DIR:?}/${EXECUTABLE_PATH:?}"
FW_DIR="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}"
RES_DIR="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"

mkdir -p "$FW_DIR" "$RES_DIR"

# --- Locate libgphoto2 install prefix (Homebrew is the default, but we also fall back) ---
GPHOTO2_PREFIX=""
if command -v brew >/dev/null 2>&1; then
  if brew list --versions libgphoto2 >/dev/null 2>&1; then
    GPHOTO2_PREFIX="$(brew --prefix libgphoto2)"
  fi
fi

if [[ -z "$GPHOTO2_PREFIX" ]]; then
  for p in /opt/homebrew/opt/libgphoto2 /usr/local/opt/libgphoto2; do
    if [[ -d "$p" ]]; then
      GPHOTO2_PREFIX="$p"
      break
    fi
  done
fi

[[ -n "$GPHOTO2_PREFIX" ]] || die "Could not locate libgphoto2. Install it (e.g. 'brew install libgphoto2')."

say "Using libgphoto2 prefix: $GPHOTO2_PREFIX"

copy_if_missing() {
  local src="$1"
  local dst_dir="$2"
  local base
  base="$(basename "$src")"

  if [[ -f "$dst_dir/$base" ]]; then
    return 0
  fi

  say "Copying $(basename "$src")"
  /usr/bin/ditto "$src" "$dst_dir/$base"
}

# Read non-system dylib deps of a Mach-O binary.
list_non_system_deps() {
  local file="$1"
  /usr/bin/otool -L "$file" \
    | tail -n +2 \
    | awk '{print $1}' \
    | grep -E '^/opt/homebrew/|^/usr/local/|^@rpath/' \
    | grep -v '^@rpath/' \
    || true
}

# Additional runtime libraries that may be loaded dynamically by libgphoto2's
# camlibs or image-processing code. These are not always visible via otool -L
# because they can be dlopen'd at runtime. We enumerate known Homebrew deps.
EXTRA_RUNTIME_LIBS=(
  # Image format support (used by various camlibs for RAW/JPEG/etc processing)
  "libjpeg"
  "libpng"
  "libtiff"
  "libwebp"
  "libavif"
  "libaom"
  "libdav1d"
  "libvmaf"
  # Compression (transitive deps of image libs)
  "liblzma"
  "libzstd"
  "libbrotli"
  # Font/text (sometimes pulled in by EXIF/metadata handling)
  "libfontconfig"
  "libfreetype"
  # RAW image processing
  "libraw"
  "liblcms2"
  # XML (EXIF/metadata)
  "libexif"
  "libxml2"
)

copy_extra_runtime_libs() {
  local brew_lib_dir=""
  if command -v brew >/dev/null 2>&1; then
    brew_lib_dir="$(brew --prefix)/lib"
  elif [[ -d /opt/homebrew/lib ]]; then
    brew_lib_dir="/opt/homebrew/lib"
  elif [[ -d /usr/local/lib ]]; then
    brew_lib_dir="/usr/local/lib"
  fi

  [[ -n "$brew_lib_dir" && -d "$brew_lib_dir" ]] || return 0

  for lib_base in "${EXTRA_RUNTIME_LIBS[@]}"; do
    # Find the newest versioned dylib for this library
    local found_lib
    found_lib="$(ls -1 "$brew_lib_dir/${lib_base}"*.dylib 2>/dev/null | grep -E '\.([0-9]+\.)*dylib$' | head -n 1 || true)"
    if [[ -z "$found_lib" ]]; then
      # Try without version number
      found_lib="$(ls -1 "$brew_lib_dir/${lib_base}.dylib" 2>/dev/null | head -n 1 || true)"
    fi
    if [[ -n "$found_lib" && -f "$found_lib" ]]; then
      copy_if_missing "$found_lib" "$FW_DIR"
    fi
  done
}

# Some gphoto2 deps can be in other brew prefixes (e.g. libusb). We just copy any
# referenced /opt/homebrew or /usr/local dylib.
copy_transitive_deps() {
  local file="$1"
  local dep

  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    if [[ -f "$dep" ]]; then
      copy_if_missing "$dep" "$FW_DIR"
    fi
  done < <(list_non_system_deps "$file")
}

# Fix install names to use @rpath for everything we bundle.
fixup_macho() {
  local file="$1"

  # Ensure the app executable can find bundled dylibs.
  if [[ "$file" == "$APP_EXE" ]]; then
    if ! /usr/bin/otool -l "$APP_EXE" | grep -q "@executable_path/../Frameworks"; then
      /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_EXE" || true
    fi
  fi

  local dep
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    local base
    base="$(basename "$dep")"

    if [[ -f "$FW_DIR/$base" ]]; then
      /usr/bin/install_name_tool -change "$dep" "@rpath/$base" "$file" || true
    fi
  done < <(list_non_system_deps "$file")
}

# --- Copy core dylibs ---
GPHOTO2_LIB="$(ls -1 "$GPHOTO2_PREFIX/lib"/libgphoto2.*.dylib 2>/dev/null | head -n 1 || true)"
GPHOTO2_PORT_LIB="$(ls -1 "$GPHOTO2_PREFIX/lib"/libgphoto2_port.*.dylib 2>/dev/null | head -n 1 || true)"

[[ -n "$GPHOTO2_LIB" && -f "$GPHOTO2_LIB" ]] || die "Could not find libgphoto2 dylib under $GPHOTO2_PREFIX/lib"
[[ -n "$GPHOTO2_PORT_LIB" && -f "$GPHOTO2_PORT_LIB" ]] || die "Could not find libgphoto2_port dylib under $GPHOTO2_PREFIX/lib"

copy_if_missing "$GPHOTO2_LIB" "$FW_DIR"
copy_if_missing "$GPHOTO2_PORT_LIB" "$FW_DIR"

# Copy deps for core dylibs + app exe (so we pick up libusb etc)
copy_transitive_deps "$FW_DIR/$(basename "$GPHOTO2_LIB")"
copy_transitive_deps "$FW_DIR/$(basename "$GPHOTO2_PORT_LIB")"
copy_transitive_deps "$APP_EXE"

# Also recursively copy deps of anything we just copied.
# (Simple fixed-point iteration; repo is small so we keep it straightforward.)
for _ in 1 2 3; do
  for f in "$FW_DIR"/*.dylib; do
    [[ -f "$f" ]] || continue
    copy_transitive_deps "$f"
  done
done

# Copy extra runtime libraries that may be dlopen'd by camlibs at runtime.
# These aren't visible via otool -L but are required for image processing.
say "Copying extra runtime libraries (image processing, compression, etc.)"
copy_extra_runtime_libs

# Copy transitive deps of the extra runtime libs we just added
for _ in 1 2 3; do
  for f in "$FW_DIR"/*.dylib; do
    [[ -f "$f" ]] || continue
    copy_transitive_deps "$f"
  done
done

# Set install_name IDs for bundled dylibs
for f in "$FW_DIR"/*.dylib; do
  [[ -f "$f" ]] || continue
  /usr/bin/install_name_tool -id "@rpath/$(basename "$f")" "$f" || true
done

# Fix references in app + dylibs
fixup_macho "$APP_EXE"
for f in "$FW_DIR"/*.dylib; do
  [[ -f "$f" ]] || continue
  fixup_macho "$f"
done

# --- Copy camlibs (camera drivers) ---
# We support both common layouts:
# - Older:  <prefix>/lib/libgphoto2/<version>/camlibs/*.so
# - Homebrew: <prefix>/lib/libgphoto2/<version>/*.so
CAMLIBS_SRC=""

# Prefer explicit camlibs directory when present.
CAMLIBS_SRC="$(find "$GPHOTO2_PREFIX/lib" -type d -path '*/libgphoto2/*/camlibs' -print -quit 2>/dev/null || true)"

# Fall back to the newest versioned folder containing *.so drivers.
if [[ -z "$CAMLIBS_SRC" && -d "$GPHOTO2_PREFIX/lib/libgphoto2" ]]; then
  while IFS= read -r d; do
    d="${d%/}"
    if compgen -G "$d/*.so" >/dev/null; then
      CAMLIBS_SRC="$d"
      break
    fi
  done < <(ls -1d "$GPHOTO2_PREFIX/lib/libgphoto2/"*/ 2>/dev/null | sort -r || true)
fi

if [[ -z "$CAMLIBS_SRC" ]]; then
  say "WARNING: camlibs not found under $GPHOTO2_PREFIX/lib/libgphoto2. Some cameras may not work."
else
  CAMLIBS_DST="$RES_DIR/libgphoto2/camlibs"
  mkdir -p "$CAMLIBS_DST"
  say "Copying camlibs from: $CAMLIBS_SRC"
  /usr/bin/ditto "$CAMLIBS_SRC" "$CAMLIBS_DST"

  # Camlibs often carry additional runtime deps (e.g. libusb) that the core
  # libgphoto2 dylibs do not directly link against. Copy those too so the
  # finished .app does not depend on a Homebrew install at runtime.
  while IFS= read -r bundle; do
    [[ -f "$bundle" ]] || continue
    copy_transitive_deps "$bundle"
  done < <(find "$CAMLIBS_DST" -type f \( -name '*.so' -o -name '*.dylib' \) -print 2>/dev/null)

  # Also recursively copy deps of anything we just pulled in (fixed-point iteration).
  for _ in 1 2 3; do
    for f in "$FW_DIR"/*.dylib; do
      [[ -f "$f" ]] || continue
      copy_transitive_deps "$f"
    done
  done

  # Ensure any newly-copied dylibs get stable @rpath IDs.
  for f in "$FW_DIR"/*.dylib; do
    [[ -f "$f" ]] || continue
    /usr/bin/install_name_tool -id "@rpath/$(basename "$f")" "$f" || true
  done

  # Fix up Mach-O bundles in camlibs to reference @rpath libs
  while IFS= read -r bundle; do
    [[ -f "$bundle" ]] || continue
    fixup_macho "$bundle"
  done < <(find "$CAMLIBS_DST" -type f \( -name '*.so' -o -name '*.dylib' \) -print 2>/dev/null)

  # Re-run fixups for the app + dylibs, since camlibs may have introduced new deps.
  fixup_macho "$APP_EXE"
  for f in "$FW_DIR"/*.dylib; do
    [[ -f "$f" ]] || continue
    fixup_macho "$f"
  done
fi

say "Bundled libgphoto2 into: $APP_DIR"
