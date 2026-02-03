#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

say() { printf "==> %s\n" "$*"; }
die() { printf "ERROR: %s\n" "$*" >&2; exit 1; }

# Builds a self-contained Release .app (bundled Syphon + libgphoto2 runtime) and zips it.
#
# Output: dist/Spiggot-macOS[-<version>].zip

VERSION="${VERSION:-}"
if [[ -z "$VERSION" ]] && command -v git >/dev/null 2>&1; then
  VERSION="$(git describe --tags --always --dirty=-dirty 2>/dev/null || true)"
fi

# MARKETING_VERSION should typically be numeric (e.g. 1.2.3). If VERSION is a tag
# like "v1.2.3", strip the leading 'v' for the bundle version fields.
MARKETING_VERSION_OVERRIDE="${MARKETING_VERSION_OVERRIDE:-${VERSION#v}}"
CURRENT_PROJECT_VERSION_OVERRIDE="${CURRENT_PROJECT_VERSION_OVERRIDE:-${VERSION#v}}"

declare -a XCODEBUILD_VERSION_ARGS=()
# Only force these when they look like normal version strings.
if [[ -n "$MARKETING_VERSION_OVERRIDE" && "$MARKETING_VERSION_OVERRIDE" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  XCODEBUILD_VERSION_ARGS+=("MARKETING_VERSION=$MARKETING_VERSION_OVERRIDE")
fi
if [[ -n "$CURRENT_PROJECT_VERSION_OVERRIDE" && "$CURRENT_PROJECT_VERSION_OVERRIDE" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  XCODEBUILD_VERSION_ARGS+=("CURRENT_PROJECT_VERSION=$CURRENT_PROJECT_VERSION_OVERRIDE")
fi

DIST_DIR="$ROOT_DIR/dist"
mkdir -p "$DIST_DIR"

say "Bootstrapping build deps (Syphon, etc.)"
"$ROOT_DIR/scripts/bootstrap_deps.sh" || true

say "Building Release"
/usr/bin/xcodebuild \
  -project "$ROOT_DIR/Spiggot.xcodeproj" \
  -scheme Spiggot \
  -configuration Release \
  ${XCODEBUILD_VERSION_ARGS[@]+"${XCODEBUILD_VERSION_ARGS[@]}"} \
  ${CI:+CODE_SIGNING_ALLOWED=NO} \
  ${CI:+CODE_SIGNING_REQUIRED=NO} \
  ${CI:+CODE_SIGN_IDENTITY=} \
  build \
  | cat

APP_PATH="$ROOT_DIR/build/Release/Spiggot.app"
# Xcodebuild puts products in DerivedData by default. Try to locate the built app.
if [[ ! -d "$APP_PATH" ]]; then
  APP_PATH="$(find "$HOME/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/Release/Spiggot.app' -print -quit 2>/dev/null || true)"
fi
[[ -n "$APP_PATH" && -d "$APP_PATH" ]] || die "Could not locate built Release app. Try building once in Xcode to populate DerivedData." 

# The libgphoto2 embedding step uses install_name_tool which invalidates any existing
# signatures on copied dylibs. Ensure the final app bundle is consistently signed
# before zipping so it can actually launch.
CODESIGN_IDENTITY_OVERRIDE="${CODESIGN_IDENTITY_OVERRIDE:--}"
say "Code signing app bundle (identity: $CODESIGN_IDENTITY_OVERRIDE)"
/usr/bin/codesign --force --deep --sign "$CODESIGN_IDENTITY_OVERRIDE" --timestamp=none "$APP_PATH" \
  || die "codesign failed; try opening the project in Xcode and fixing Signing & Capabilities"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH" \
  || die "codesign verification failed"

if [[ "$CODESIGN_IDENTITY_OVERRIDE" == "-" ]]; then
  say "NOTE: App is ad-hoc signed (-). Gatekeeper may reject it if it has a quarantine attribute (e.g. downloaded zip)."
  say "      For local testing you can clear quarantine: xattr -dr com.apple.quarantine Spiggot.app"
  say "      For distribution you typically need a 'Developer ID Application' signature + notarization."
  /usr/sbin/spctl --assess --type execute --verbose=2 "$APP_PATH" >/dev/null 2>&1 || true
fi

ZIP_SUFFIX=""
if [[ -n "$VERSION" ]]; then
  ZIP_SUFFIX="-$VERSION"
fi

ZIP_PATH="$DIST_DIR/Spiggot-macOS${ZIP_SUFFIX}.zip"
rm -f "$ZIP_PATH"

say "Creating zip: $ZIP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

say "Done: $ZIP_PATH"
