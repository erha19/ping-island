#!/bin/bash
# Build the Debug app and launch it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCHEME="${PING_ISLAND_SCHEME:-PingIsland}"
PROJECT_FILE="${PING_ISLAND_PROJECT_FILE:-PingIsland.xcodeproj}"
DERIVED_DATA_PATH="${PING_ISLAND_DERIVED_DATA_PATH:-$PROJECT_DIR/build/DerivedData}"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/Ping Island.app"

cd "$PROJECT_DIR"

echo "=== Building Ping Island (Debug) ==="
xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -destination "platform=macOS" \
    build

if [[ ! -d "$APP_PATH" ]]; then
    echo "error: expected app bundle missing: $APP_PATH" >&2
    exit 1
fi

# Prefer a single Debug instance for local iteration.
if pgrep -f "$APP_PATH/Contents/MacOS/Ping Island" >/dev/null 2>&1; then
    echo "Stopping existing Debug instance..."
    pkill -f "$APP_PATH/Contents/MacOS/Ping Island" || true
    sleep 0.4
fi

echo "Launching: $APP_PATH"
open "$APP_PATH"
echo "Done."
