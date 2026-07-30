#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/dmg-layout.sh"

BUILD_DIR="$PROJECT_DIR/build/unsigned"
DERIVED_DATA_PATH="$BUILD_DIR/DerivedData"
STAGING_DIR="$BUILD_DIR/dmg-staging"
RELEASE_DIR="$PROJECT_DIR/releases/unsigned"
DMG_BACKGROUND_SOURCE="${PING_ISLAND_DMG_BACKGROUND_SOURCE:-$PROJECT_DIR/docs/images/ping-island-dmg-installer-background.png}"
DMG_LOGO_SOURCE="${PING_ISLAND_DMG_LOGO_SOURCE:-$PROJECT_DIR/docs/images/notchcode-icon-transparent.svg}"

APP_BUNDLE_NAME="NotchCode.app"
APP_PRODUCT_NAME="NotchCode"
SCHEME="PingIsland"
PROJECT_FILE="$PROJECT_DIR/PingIsland.xcodeproj"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/$APP_BUNDLE_NAME"
BUILD_MODE_LABEL="release"

echo "=== Packaging Unsigned NotchCode ==="
echo ""

resolve_exported_app_icon() {
    local requested_icon_source="${PING_ISLAND_DMG_ICON_SOURCE:-}"
    local bundled_icon_path="$APP_PATH/Contents/Resources/AppIcon.icns"

    if [ -n "$requested_icon_source" ]; then
        echo "$requested_icon_source"
        return 0
    fi

    if [ -f "$bundled_icon_path" ]; then
        echo "$bundled_icon_path"
        return 0
    fi

    echo "$PROJECT_DIR/PingIsland/Assets.xcassets/AppIcon.appiconset/icon_1024x1024.png"
}

resolve_dmg_icon_source() {
    if [ -f "$DMG_LOGO_SOURCE" ]; then
        echo "$DMG_LOGO_SOURCE"
        return 0
    fi

    resolve_exported_app_icon
}

if [ ! -f "$DMG_BACKGROUND_SOURCE" ]; then
    echo "ERROR: DMG background image not found at $DMG_BACKGROUND_SOURCE"
    exit 1
fi

export PING_ISLAND_DMG_BACKGROUND_SOURCE="$DMG_BACKGROUND_SOURCE"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$RELEASE_DIR"

echo "Building Release app with ad-hoc signing..."
if ! xcodebuild \
    -project "$PROJECT_FILE" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGN_IDENTITY=- \
    build; then
    echo ""
    echo "Release optimizer crashed. Retrying with stable compiler settings..."
    rm -rf "$DERIVED_DATA_PATH"

    xcodebuild \
        -project "$PROJECT_FILE" \
        -scheme "$SCHEME" \
        -configuration Release \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        CODE_SIGN_IDENTITY=- \
        SWIFT_OPTIMIZATION_LEVEL=-Onone \
        SWIFT_COMPILATION_MODE=singlefile \
        build

    BUILD_MODE_LABEL="release-safe"
fi

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App bundle not found at $APP_PATH"
    exit 1
fi

DMG_ICON_SOURCE="$(resolve_dmg_icon_source)"
if [ ! -f "$DMG_ICON_SOURCE" ]; then
    echo "ERROR: DMG icon image not found at $DMG_ICON_SOURCE"
    exit 1
fi

export PING_ISLAND_DMG_ICON_SOURCE="$DMG_ICON_SOURCE"

echo ""
echo "Re-signing app bundle with a consistent ad-hoc signature..."
# Do not preserve the original signing flags here. Keeping the release build's
# hardened runtime flags on an ad-hoc unsigned app has produced Sparkle load
# failures on downloaded DMGs.
codesign \
    --force \
    --deep \
    --sign - \
    --preserve-metadata=identifier,entitlements \
    "$APP_PATH"

echo "Verifying app bundle signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")

ZIP_PATH="$RELEASE_DIR/$APP_PRODUCT_NAME-$VERSION-$BUILD_MODE_LABEL-unsigned.zip"
DMG_PATH="$RELEASE_DIR/$APP_PRODUCT_NAME-$VERSION-$BUILD_MODE_LABEL-unsigned.dmg"

rm -f "$ZIP_PATH" "$DMG_PATH"
rm -rf "$STAGING_DIR"

echo ""
echo "Creating ZIP..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Creating DMG..."
create_styled_dmg "$APP_PATH" "$DMG_PATH" "NotchCode" "$STAGING_DIR" "$PROJECT_DIR"

echo ""
echo "=== Unsigned Package Ready ==="
echo "Version: $VERSION ($BUILD)"
echo "Build mode: $BUILD_MODE_LABEL"
echo "App: $APP_PATH"
echo "ZIP: $ZIP_PATH"
echo "DMG: $DMG_PATH"
echo ""
echo "Note: This build is for local testing only."
echo "Note: It is ad-hoc signed and not notarized, so macOS may require right-click Open or quarantine removal on first launch."
