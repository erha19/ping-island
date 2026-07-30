#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SVG="${ROOT_DIR}/docs/images/notchcode-icon.svg"
OUTPUT_DIR="${ROOT_DIR}/PingIsland/Assets.xcassets/AppIcon.appiconset"

usage() {
  cat <<'EOF'
Usage: render-app-icons.sh [--source <svg-path>] [--output-dir <path>]

Regenerates the macOS AppIcon asset set from the NotchCode SVG source.
The export intentionally preserves SVG transparency so the rounded corners
stay transparent instead of being baked onto a white canvas.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      shift
      SOURCE_SVG="${1:-}"
      ;;
    --output-dir)
      shift
      OUTPUT_DIR="${1:-}"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

if [[ -z "${SOURCE_SVG}" || -z "${OUTPUT_DIR}" ]]; then
  echo "Both source SVG and output directory are required." >&2
  usage >&2
  exit 1
fi

if [[ ! -f "${SOURCE_SVG}" ]]; then
  echo "Source SVG not found: ${SOURCE_SVG}" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"

render_icon() {
  local size="$1"
  local filename="$2"
  local output_path="${OUTPUT_DIR}/${filename}"

  sips -z "${size}" "${size}" -s format png "${SOURCE_SVG}" --out "${output_path}" >/dev/null
}

render_icon 16 "icon_16x16.png"
render_icon 32 "icon_32x32 1.png"
render_icon 32 "icon_32x32.png"
render_icon 64 "icon_64x64.png"
render_icon 128 "icon_128x128.png"
render_icon 256 "icon_256x256 1.png"
render_icon 256 "icon_256x256.png"
render_icon 512 "icon_512x512 1.png"
render_icon 512 "icon_512x512.png"
render_icon 1024 "icon_1024x1024.png"

echo "Rendered AppIcon assets from ${SOURCE_SVG}"
