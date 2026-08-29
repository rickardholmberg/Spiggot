#!/usr/bin/env bash
set -euo pipefail

# Post-build, pre-publish QA gate for the packaged .app. Run against the
# actual zipped artifact (unzipped fresh) so it tests what a user would
# actually download, not the pre-zip build directory.
#
# Checks:
# 1. No Mach-O file inside the bundle references an unbundled/absolute
#    library path (e.g. a build-machine Homebrew path) -- this is exactly
#    the class of bug that broke camera detection in earlier releases.
# 2. The code signature verifies.
# 3. The app actually launches and is still running a few seconds later.
# 4. libgphoto2's autodetect doesn't fail to load its port/camera drivers
#    (regression test for the missing-iolibs bug fixed in v0.0.6) -- this
#    doesn't require real camera hardware to be a meaningful check.

say() { printf "[qa] %s\n" "$*"; }
fail() { printf "[qa] FAIL: %s\n" "$*" >&2; exit 1; }

APP="${1:?Usage: qa_verify_release.sh <path-to-.app>}"
[[ -d "$APP" ]] || fail "App bundle not found: $APP"

EXE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Contents/Info.plist")"
EXE_PATH="$APP/Contents/MacOS/$EXE_NAME"
[[ -x "$EXE_PATH" ]] || fail "Executable not found/executable: $EXE_PATH"

# --- 1. No leftover build-machine library paths ---
say "Checking for unbundled/absolute library references..."
bad_refs=0
while IFS= read -r -d '' f; do
  file "$f" | grep -q "Mach-O" || continue
  # A dylib/framework's own install name (LC_ID_DYLIB) is listed by `otool -L`
  # as if it were a dependency -- it's the library's own identity, not
  # something it links against, so exclude it (may itself be an absolute
  # path; that's fine, it's just how the file identifies itself). Filter by
  # indentation, not line position: for a universal (multi-arch) binary,
  # otool repeats an unindented "<path> (architecture X):" header per slice,
  # which `tail -n +2` alone doesn't strip for the 2nd+ architecture.
  self_ids="$(otool -D "$f" 2>/dev/null | grep -v ':$' || true)"
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    if [[ -n "$self_ids" ]] && grep -qxF "$dep" <<< "$self_ids"; then
      continue
    fi
    case "$dep" in
      @rpath/*|@executable_path/*|@loader_path/*) ;;
      /usr/lib/*|/System/*) ;;
      *)
        say "  BAD: $(basename "$f") depends on $dep"
        bad_refs=1
        ;;
    esac
  done < <(otool -L "$f" | grep -E '^[[:space:]]' | awk '{print $1}')
done < <(find "$APP" -type f -print0)

[[ "$bad_refs" -eq 0 ]] || fail "Found Mach-O files referencing unbundled/absolute library paths (see above). The app is not self-contained."
say "OK: no unbundled library references found."

# --- 2. Code signature sanity ---
say "Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/[qa]   /' || fail "codesign verification failed"
say "OK: code signature verifies."

# --- 3. App actually launches and stays alive ---
say "Launching app..."
open "$APP"
sleep 5
if ! pgrep -f "$EXE_PATH" >/dev/null; then
  fail "App is not running 5s after launch (crashed or failed to start)"
fi
say "OK: app launched and is running."
pkill -f "$EXE_PATH" || true

# --- 4. libgphoto2 autodetect must not hard-fail (iolibs/camlibs regression) ---
say "Verifying libgphoto2 autodetect doesn't fail to load (iolibs/camlibs bundling regression check)..."

GPHOTO2_LIB="$(ls -1 "$APP/Contents/Frameworks"/libgphoto2.*.dylib 2>/dev/null | head -n 1 || true)"
GPHOTO2_PORT_LIB="$(ls -1 "$APP/Contents/Frameworks"/libgphoto2_port.*.dylib 2>/dev/null | head -n 1 || true)"
[[ -n "$GPHOTO2_LIB" && -n "$GPHOTO2_PORT_LIB" ]] || fail "Could not find bundled libgphoto2/libgphoto2_port dylibs under $APP/Contents/Frameworks"

GPHOTO2_PREFIX="$(brew --prefix libgphoto2)"
WORK_DIR="$(mktemp -d)"
HARNESS_SRC="$WORK_DIR/gp_autodetect_check.c"
HARNESS_BIN="$WORK_DIR/gp_autodetect_check"

cat > "$HARNESS_SRC" <<'C_EOF'
#include <stdio.h>
#include <gphoto2/gphoto2.h>
int main(void) {
    GPContext *ctx = gp_context_new();
    if (!ctx) { fprintf(stderr, "gp_context_new failed\n"); return 1; }
    CameraList *list = NULL;
    if (gp_list_new(&list) < GP_OK) { fprintf(stderr, "gp_list_new failed\n"); return 1; }
    int ret = gp_camera_autodetect(list, ctx);
    if (ret < GP_OK) {
        fprintf(stderr, "gp_camera_autodetect failed: %d (%s)\n", ret, gp_result_as_string(ret));
        return 1;
    }
    printf("gp_camera_autodetect OK, found %d camera(s) (0 is expected with no hardware attached in CI)\n", gp_list_count(list));
    return 0;
}
C_EOF

clang "$HARNESS_SRC" -o "$HARNESS_BIN" \
  -I"$GPHOTO2_PREFIX/include" -I"$GPHOTO2_PREFIX/include/gphoto2" \
  "$GPHOTO2_LIB" "$GPHOTO2_PORT_LIB" \
  -Wl,-rpath,"$APP/Contents/Frameworks" \
  || fail "Failed to build gphoto2 autodetect check harness"

CAMLIBS="$APP/Contents/Resources/libgphoto2/camlibs" \
IOLIBS="$APP/Contents/Resources/libgphoto2/iolibs" \
"$HARNESS_BIN" || fail "libgphoto2 autodetect failed inside the bundled app (missing/broken iolibs or camlibs)"

say "OK: libgphoto2 autodetect works against the bundled runtime."

say "All QA checks passed."
