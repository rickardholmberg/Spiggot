#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/generate_app_icons.sh [path/to/icon.svg] [path/to/AppIcon.appiconset]

Defaults:
  icon.svg:            <repo>/assets/icons/icon.svg
  AppIcon.appiconset:  <repo>/Spiggot/Assets.xcassets/AppIcon.appiconset

Description:
  Renders the SVG to a 1024x1024 PNG via macOS Quick Look (qlmanage), then
  downscales it into the full set of required macOS AppIcon PNGs.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
svg_path="${1:-"$repo_root/assets/icons/icon.svg"}"
appiconset_dir="${2:-"$repo_root/Spiggot/Assets.xcassets/AppIcon.appiconset"}"

if [[ ! -f "$svg_path" ]]; then
  echo "error: SVG not found: $svg_path" >&2
  exit 1
fi

if ! command -v qlmanage >/dev/null 2>&1; then
  echo "error: qlmanage not found (required to render SVG to PNG)" >&2
  exit 1
fi

if ! command -v sips >/dev/null 2>&1; then
  echo "error: sips not found (required to resize PNGs)" >&2
  exit 1
fi

magick_cmd=""
if command -v magick >/dev/null 2>&1; then
  magick_cmd="magick"
elif command -v convert >/dev/null 2>&1; then
  # Back-compat for older ImageMagick installs.
  magick_cmd="convert"
fi

mkdir -p "$appiconset_dir"

work_dir="$(mktemp -d)"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

# Quick Look thumbnail generator writes "<basename>.png" into the output directory.
qlmanage -t -s 1024 -o "$work_dir" "$svg_path" >/dev/null 2>&1 || {
  echo "error: failed to render SVG with qlmanage" >&2
  exit 1
}

rendered_png="$work_dir/$(basename "$svg_path").png"
if [[ ! -f "$rendered_png" ]]; then
  echo "error: expected rendered PNG not found: $rendered_png" >&2
  echo "hint: qlmanage output directory was: $work_dir" >&2
  exit 1
fi

src_png="$appiconset_dir/icon_512x512@2x.png"
cp -f "$rendered_png" "$src_png"

# Generate required macOS app icon PNGs.
# Names match entries in AppIcon.appiconset/Contents.json.

declare -a outputs=(
  "16 16 icon_16x16.png"
  "32 32 icon_16x16@2x.png"
  "32 32 icon_32x32.png"
  "64 64 icon_32x32@2x.png"
  "128 128 icon_128x128.png"
  "256 256 icon_128x128@2x.png"
  "256 256 icon_256x256.png"
  "512 512 icon_256x256@2x.png"
  "512 512 icon_512x512.png"
)

for spec in "${outputs[@]}"; do
  read -r height width filename <<<"$spec"
  out_path="$appiconset_dir/$filename"
  sips -z "$height" "$width" "$src_png" --out "$out_path" >/dev/null
done

echo "Generated macOS app icon PNGs from: $svg_path"
echo "Output directory: $appiconset_dir"

# Also generate the menu bar (NSStatusItem) template icon if present.
menubar_svg="$repo_root/assets/icons/menuicon.svg"
menubar_imageset="$repo_root/Spiggot/Assets.xcassets/MenuBarIcon.imageset"

if [[ -f "$menubar_svg" ]]; then
  mkdir -p "$menubar_imageset"

  menubar_tmp="$(mktemp -d)"
  trap 'rm -rf "$work_dir" "$menubar_tmp"' EXIT

  qlmanage -t -s 256 -o "$menubar_tmp" "$menubar_svg" >/dev/null 2>&1 || {
    echo "warning: failed to render menu bar SVG: $menubar_svg" >&2
    exit 0
  }

  menubar_rendered_png="$menubar_tmp/$(basename "$menubar_svg").png"
  if [[ -f "$menubar_rendered_png" ]]; then
    # Ensure we end up with a proper template image: transparent background and
    # an alpha mask derived from luminance (so it won't look inverted if the
    # renderer bakes in a white page background).
    if [[ -n "$magick_cmd" ]]; then
      menubar_base_png="$menubar_tmp/menubar_base.png"

      # Build alpha as (1 - luminance), then set RGB to solid black.
      # This makes "black strokes on white" become an opaque icon on transparent.
      "$magick_cmd" "$menubar_rendered_png" \
        \( +clone -alpha off -colorspace gray -negate \) \
        -alpha off -compose CopyOpacity -composite \
        -background none -alpha on \
        -fill black -colorize 100 \
        "$menubar_base_png"

      "$magick_cmd" "$menubar_base_png" -resize 36x36 "$menubar_imageset/menubaricon@2x.png"
      "$magick_cmd" "$menubar_base_png" -resize 18x18 "$menubar_imageset/menubaricon.png"
    else
      # Fallback: best-effort resize only (may invert if the PNG has an opaque background).
      sips -z 36 36 "$menubar_rendered_png" --out "$menubar_imageset/menubaricon@2x.png" >/dev/null
      sips -z 18 18 "$menubar_rendered_png" --out "$menubar_imageset/menubaricon.png" >/dev/null
    fi

    echo "Generated menu bar icon PNGs from: $menubar_svg"
    echo "Output directory: $menubar_imageset"
  else
    echo "warning: expected rendered menu bar PNG not found: $menubar_rendered_png" >&2
  fi
fi
