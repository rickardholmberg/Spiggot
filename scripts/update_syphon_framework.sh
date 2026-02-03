#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMEWORKS_DIR="$ROOT_DIR/Frameworks"
DEST_FRAMEWORK="$FRAMEWORKS_DIR/Syphon.framework"

REPO_URL="${SYPHON_REPO_URL:-https://github.com/Syphon/Syphon-Framework.git}"
REF="${SYPHON_REF:-}"

workdir="$(mktemp -d)"
cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

printf "==> Working dir: %s\n" "$workdir"
printf "==> Cloning: %s\n" "$REPO_URL"

if [[ -n "$REF" ]]; then
  git clone --depth 1 --branch "$REF" "$REPO_URL" "$workdir/Syphon-Framework"
else
  git clone --depth 1 "$REPO_URL" "$workdir/Syphon-Framework"
fi

cd "$workdir/Syphon-Framework"

# Locate an Xcode project.
proj=""
if [[ -f "Syphon.xcodeproj/project.pbxproj" ]]; then
  proj="Syphon.xcodeproj"
else
  # Fallback: first .xcodeproj in the repo root.
  proj="$(ls -1 *.xcodeproj 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "$proj" ]]; then
  echo "ERROR: Could not find an .xcodeproj in the Syphon repo." >&2
  exit 1
fi

printf "==> Using project: %s\n" "$proj"

derivedData="$workdir/DerivedData"

# Try a small set of likely scheme names, then fall back to the first scheme from xcodebuild -list.
try_schemes=(
  "Syphon"
  "Syphon Framework"
  "Syphon-Framework"
)

schemes_from_list="$(xcodebuild -list -project "$proj" 2>/dev/null | awk '/Schemes:/ {flag=1; next} flag && NF {print $1} flag && !NF {exit}' || true)"
if [[ -n "$schemes_from_list" ]]; then
  while IFS= read -r s; do
    try_schemes+=("$s")
  done <<< "$schemes_from_list"
fi

scheme=""
for s in "${try_schemes[@]}"; do
  if [[ -z "$s" ]]; then continue; fi
  printf "==> Trying scheme: %s\n" "$s"
  if xcodebuild \
      -project "$proj" \
      -scheme "$s" \
      -configuration Release \
      -sdk macosx \
      -derivedDataPath "$derivedData" \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      CODE_SIGN_IDENTITY= \
      SKIP_INSTALL=NO \
      BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
      build \
      | cat; then
    scheme="$s"
    break
  fi
  echo "    (scheme failed)"
done

if [[ -z "$scheme" ]]; then
  echo "ERROR: Failed to build Syphon.framework (no scheme succeeded)." >&2
  exit 1
fi

printf "==> Built scheme: %s\n" "$scheme"

frameworkPath="$(find "$derivedData/Build/Products" -maxdepth 5 -name Syphon.framework -print -quit)"
if [[ -z "$frameworkPath" ]]; then
  echo "ERROR: Build succeeded but Syphon.framework was not found under DerivedData." >&2
  echo "Searched in: $derivedData/Build/Products" >&2
  exit 1
fi

printf "==> Found framework: %s\n" "$frameworkPath"

mkdir -p "$FRAMEWORKS_DIR"
rm -rf "$DEST_FRAMEWORK"

# Use ditto to preserve symlinks and framework structure.
/usr/bin/ditto "$frameworkPath" "$DEST_FRAMEWORK"

# Ensure Versions/Current is a symlink (some copies can end up wrong).
if [[ -d "$DEST_FRAMEWORK/Versions" ]]; then
  if [[ -e "$DEST_FRAMEWORK/Versions/Current" && ! -L "$DEST_FRAMEWORK/Versions/Current" ]]; then
    rm -rf "$DEST_FRAMEWORK/Versions/Current"
    ln -s A "$DEST_FRAMEWORK/Versions/Current"
  fi
fi

printf "==> Installed to: %s\n" "$DEST_FRAMEWORK"
printf "==> Done.\n"
