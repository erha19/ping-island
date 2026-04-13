#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKGROUND_GENERATOR="$SCRIPT_DIR/generate-dmg-background.swift"
BRAND_LOGO_SOURCE="${PING_ISLAND_DMG_LOGO_SOURCE:-$PROJECT_DIR/docs/images/ping-island-icon-transparent.svg}"
DMG_ICON_SOURCE="${PING_ISLAND_DMG_ICON_SOURCE:-}"
FALLBACK_ICON_PNG="$PROJECT_DIR/PingIsland/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png"

VOLNAME=""
SOURCE_DIR=""
OUTPUT_DMG=""
APP_NAME="Ping Island.app"
WINDOW_WIDTH="${PING_ISLAND_DMG_WINDOW_WIDTH:-520}"
WINDOW_HEIGHT="${PING_ISLAND_DMG_WINDOW_HEIGHT:-360}"
ICON_SIZE="${PING_ISLAND_DMG_ICON_SIZE:-92}"
APP_X="${PING_ISLAND_DMG_APP_X:-138}"
APP_Y="${PING_ISLAND_DMG_APP_Y:-168}"
APPLICATIONS_X="${PING_ISLAND_DMG_APPLICATIONS_X:-388}"
APPLICATIONS_Y="${PING_ISLAND_DMG_APPLICATIONS_Y:-168}"
FAIL_ON_PLAIN="${PING_ISLAND_DMG_FAIL_ON_PLAIN:-0}"
FINDER_VOLUME_NAME=""

resolve_image_source() {
  local requested_source="$1"

  if [[ -n "$requested_source" && -f "$requested_source" ]]; then
    printf '%s\n' "$requested_source"
    return 0
  fi

  if [[ -f "$FALLBACK_ICON_PNG" ]]; then
    printf '%s\n' "$FALLBACK_ICON_PNG"
    return 0
  fi

  return 1
}

resolve_app_bundle_icon_source() {
  local app_bundle_path="$1"
  local info_plist="$app_bundle_path/Contents/Info.plist"
  local resources_dir="$app_bundle_path/Contents/Resources"
  local icon_file=""
  local icon_path=""

  if [[ ! -d "$app_bundle_path" || ! -d "$resources_dir" ]]; then
    return 1
  fi

  if [[ -f "$info_plist" ]]; then
    icon_file="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$info_plist" 2>/dev/null || true)"
    if [[ -n "$icon_file" ]]; then
      if [[ "$icon_file" != *.icns ]]; then
        icon_file="${icon_file}.icns"
      fi
      icon_path="$resources_dir/$icon_file"
      if [[ -f "$icon_path" ]]; then
        printf '%s\n' "$icon_path"
        return 0
      fi
    fi
  fi

  icon_path="$resources_dir/AppIcon.icns"
  if [[ -f "$icon_path" ]]; then
    printf '%s\n' "$icon_path"
    return 0
  fi

  icon_path="$(find "$resources_dir" -maxdepth 1 -type f -name '*.icns' | head -n 1)"
  if [[ -n "$icon_path" ]]; then
    printf '%s\n' "$icon_path"
    return 0
  fi

  return 1
}

resolve_dmg_icon_source() {
  local app_bundle_path="$SOURCE_DIR/$APP_NAME"
  local requested_icon_source="${DMG_ICON_SOURCE:-}"

  if [[ -n "$requested_icon_source" ]]; then
    resolve_image_source "$requested_icon_source"
    return $?
  fi

  if resolve_app_bundle_icon_source "$app_bundle_path"; then
    return 0
  fi

  resolve_image_source "$FALLBACK_ICON_PNG"
}

rasterize_to_png() {
  local source_path="$1"
  local output_path="$2"

  case "$source_path" in
    *.svg|*.SVG|*.icns|*.ICNS)
      sips -s format png "$source_path" --out "$output_path" >/dev/null
      ;;
    *.png|*.PNG)
      cp "$source_path" "$output_path"
      ;;
    *)
      echo "Unsupported DMG image source: $source_path" >&2
      return 1
      ;;
  esac
}

usage() {
  cat <<'EOF'
Usage: create-styled-dmg.sh --volname <name> --source <folder> --output <dmg-path> [options]

Options:
  --app-name <bundle-name>       App bundle name inside the DMG
  --window-width <pixels>        Finder window width
  --window-height <pixels>       Finder window height
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --volname)
      VOLNAME="${2:-}"
      shift 2
      ;;
    --source)
      SOURCE_DIR="${2:-}"
      shift 2
      ;;
    --output)
      OUTPUT_DMG="${2:-}"
      shift 2
      ;;
    --app-name)
      APP_NAME="${2:-}"
      shift 2
      ;;
    --window-width)
      WINDOW_WIDTH="${2:-}"
      shift 2
      ;;
    --window-height)
      WINDOW_HEIGHT="${2:-}"
      shift 2
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
done

if [[ -z "$VOLNAME" || -z "$SOURCE_DIR" || -z "$OUTPUT_DMG" ]]; then
  usage >&2
  exit 1
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "Source directory not found: $SOURCE_DIR" >&2
  exit 1
fi

if [[ ! -x "$BACKGROUND_GENERATOR" ]]; then
  chmod +x "$BACKGROUND_GENERATOR"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ping-island-dmg.XXXXXX")"
RW_DMG="$TMP_DIR/styled.dmg"
MOUNT_POINT=""
BACKGROUND_PATH="$TMP_DIR/background.png"
ICON_WORK_PNG="$TMP_DIR/dmg-icon.png"
ICON_RESOURCE_PATH="$TMP_DIR/dmg-icon.rsrc"
BRAND_LOGO_PNG="$TMP_DIR/brand-logo.png"
LAYOUT_READY=0
ATTACHED=0

cleanup() {
  if [[ "$ATTACHED" -eq 1 && -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

SOURCE_SIZE_MB=$(du -sk "$SOURCE_DIR" | awk '{ printf "%d", ($1 / 1024) + 80 }')
rm -f "$OUTPUT_DMG"

if logo_source="$(resolve_image_source "$BRAND_LOGO_SOURCE")"; then
  rasterize_to_png "$logo_source" "$BRAND_LOGO_PNG"
fi

background_args=(
  --output "$BACKGROUND_PATH"
  --width "$WINDOW_WIDTH"
  --height "$WINDOW_HEIGHT"
)

swift "$BACKGROUND_GENERATOR" "${background_args[@]}"

if icon_source="$(resolve_dmg_icon_source)"; then
  rasterize_to_png "$icon_source" "$ICON_WORK_PNG"
  sips -i "$ICON_WORK_PNG" >/dev/null
  DeRez -only icns "$ICON_WORK_PNG" > "$ICON_RESOURCE_PATH"
fi

hdiutil create \
  -srcfolder "$SOURCE_DIR" \
  -volname "$VOLNAME" \
  -fs HFS+ \
  -format UDRW \
  -size "${SOURCE_SIZE_MB}m" \
  -ov \
  "$RW_DMG" >/dev/null

attach_output="$(
  hdiutil attach \
    -readwrite \
    -noverify \
    -noautoopen \
    -nobrowse \
    "$RW_DMG"
)"
MOUNT_POINT="$(printf '%s\n' "$attach_output" | awk '/\/Volumes\// { sub(/^.*\/Volumes\//, "/Volumes/"); print; exit }')"
if [[ -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT" ]]; then
  echo "ERROR: Unable to determine mounted DMG path" >&2
  exit 1
fi
FINDER_VOLUME_NAME="$(basename "$MOUNT_POINT")"
ATTACHED=1

mkdir -p "$MOUNT_POINT/.background"
cp "$BACKGROUND_PATH" "$MOUNT_POINT/.background/background.png"

if [[ -f "$ICON_RESOURCE_PATH" ]]; then
  local_volume_icon="$MOUNT_POINT/Icon"$'\r'
  Rez -append "$ICON_RESOURCE_PATH" -o "$local_volume_icon"
  xcrun SetFile -a V "$local_volume_icon"
  xcrun SetFile -a C "$MOUNT_POINT"
fi

if osascript - "$FINDER_VOLUME_NAME" "$WINDOW_WIDTH" "$WINDOW_HEIGHT" "$ICON_SIZE" "$APP_NAME" "$APP_X" "$APP_Y" "$APPLICATIONS_X" "$APPLICATIONS_Y" <<'EOF'
on run argv
  set volumeName to item 1 of argv
  set windowWidth to (item 2 of argv) as integer
  set windowHeight to (item 3 of argv) as integer
  set iconSize to (item 4 of argv) as integer
  set appName to item 5 of argv
  set appX to (item 6 of argv) as integer
  set appY to (item 7 of argv) as integer
  set applicationsX to (item 8 of argv) as integer
  set applicationsY to (item 9 of argv) as integer
  set windowOriginX to 120
  set windowOriginY to 120
  set windowRightX to windowOriginX + windowWidth
  set windowBottomY to windowOriginY + windowHeight
  set dsStorePath to "/Volumes/" & volumeName & "/.DS_Store"

  tell application "Finder"
    repeat 20 times
      if exists disk volumeName then exit repeat
      delay 0.5
    end repeat

    if not (exists disk volumeName) then error "Disk " & volumeName & " not visible in Finder"

    tell disk volumeName
      open

      tell container window
        set current view to icon view
        try
          set toolbar visible to false
        end try
        try
          set statusbar visible to false
        end try
        set bounds to {windowOriginX, windowOriginY, windowRightX, windowBottomY}
      end tell

      set viewOptions to the icon view options of container window
      tell viewOptions
        set arrangement to not arranged
        set icon size to iconSize
        set text size to 13
      end tell
      set background picture of viewOptions to file ".background:background.png"

      try
        set position of item appName to {appX, appY}
      end try
      try
        set position of item "Applications" to {applicationsX, applicationsY}
      end try

      close
      open
      update without registering applications
      delay 1

      tell container window
        try
          set statusbar visible to false
        end try
        set bounds to {windowOriginX, windowOriginY, windowRightX - 10, windowBottomY - 10}
      end tell
    end tell

    delay 1

    tell disk volumeName
      tell container window
        try
          set statusbar visible to false
        end try
        set bounds to {windowOriginX, windowOriginY, windowRightX, windowBottomY}
      end tell
    end tell

    repeat 40 times
      if (do shell script "[ -s " & quoted form of dsStorePath & " ] && echo ready || echo waiting") is "ready" then exit repeat
      delay 0.5
    end repeat
  end tell
end run
EOF
then
  if [[ -s "$MOUNT_POINT/.DS_Store" ]]; then
    LAYOUT_READY=1
  else
    echo "warning: Finder customization finished but .DS_Store was not written; falling back to a plain DMG layout" >&2
  fi
else
  echo "warning: Finder customization failed; falling back to a plain DMG layout" >&2
fi

sync
hdiutil detach "$MOUNT_POINT" >/dev/null
ATTACHED=0

hdiutil convert \
  "$RW_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  -o "$OUTPUT_DMG" >/dev/null

if [[ -f "$ICON_RESOURCE_PATH" ]]; then
  Rez -append "$ICON_RESOURCE_PATH" -o "$OUTPUT_DMG"
  xcrun SetFile -a C "$OUTPUT_DMG"
fi

if [[ "$LAYOUT_READY" -eq 1 ]]; then
  echo "Styled DMG created at $OUTPUT_DMG"
else
  if [[ "$FAIL_ON_PLAIN" = "1" ]]; then
    echo "ERROR: DMG styling did not persist; refusing to ship a plain DMG" >&2
    exit 1
  fi
  echo "DMG created without Finder styling at $OUTPUT_DMG"
fi
