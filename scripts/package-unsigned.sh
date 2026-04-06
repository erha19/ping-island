#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build/unsigned"
DERIVED_DATA_PATH="$BUILD_DIR/DerivedData"
STAGING_DIR="$BUILD_DIR/dmg-staging"
RELEASE_DIR="$PROJECT_DIR/releases/unsigned"

APP_BUNDLE_NAME="Ping Island.app"
APP_PRODUCT_NAME="PingIsland"
SCHEME="PingIsland"
PROJECT_FILE="$PROJECT_DIR/PingIsland.xcodeproj"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release/$APP_BUNDLE_NAME"
BUILD_MODE_LABEL="release"

echo "=== Packaging Unsigned Ping Island ==="
echo ""

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

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")

ZIP_PATH="$RELEASE_DIR/$APP_PRODUCT_NAME-$VERSION-$BUILD-$BUILD_MODE_LABEL-unsigned.zip"
DMG_PATH="$RELEASE_DIR/$APP_PRODUCT_NAME-$VERSION-$BUILD-$BUILD_MODE_LABEL-unsigned.dmg"

rm -f "$ZIP_PATH" "$DMG_PATH"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

echo ""
echo "Creating ZIP..."
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Preparing DMG contents..."
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "Creating DMG..."
hdiutil create \
    -volname "Ping Island" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING_DIR"

echo ""
echo "=== Unsigned Package Ready ==="
echo "Version: $VERSION ($BUILD)"
echo "Build mode: $BUILD_MODE_LABEL"
echo "App: $APP_PATH"
echo "ZIP: $ZIP_PATH"
echo "DMG: $DMG_PATH"
echo ""
echo "Note: This build is ad-hoc signed only. Other users may need to right-click Open or clear quarantine manually."
