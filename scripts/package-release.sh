#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PING_ISLAND_BUILD_DIR:-$PROJECT_DIR/build/release}"
DERIVED_DATA_PATH="$BUILD_DIR/DerivedData"
EXPORT_PATH="$BUILD_DIR/export"
RELEASE_DIR="${PING_ISLAND_RELEASE_DIR:-$PROJECT_DIR/releases/signed}"
NOTES_DIR="$PROJECT_DIR/releases/notes"
KEYS_DIR="$PROJECT_DIR/.sparkle-keys"
STAGING_DIR="$BUILD_DIR/dmg-staging"

APP_BUNDLE_NAME="Ping Island.app"
APP_PRODUCT_NAME="PingIsland"
APP_PATH="$EXPORT_PATH/$APP_BUNDLE_NAME"

NOTARY_APPLE_ID="${PING_ISLAND_NOTARY_APPLE_ID:-${APPLE_ID:-}}"
NOTARY_TEAM_ID="${PING_ISLAND_NOTARY_TEAM_ID:-${APPLE_TEAM_ID:-}}"
NOTARY_PASSWORD="${PING_ISLAND_NOTARY_PASSWORD:-${APPLE_APP_SPECIFIC_PASSWORD:-}}"
NOTARY_KEYCHAIN_PROFILE="${PING_ISLAND_NOTARY_KEYCHAIN_PROFILE:-${NOTARY_KEYCHAIN_PROFILE:-PingIsland}}"
SKIP_NOTARIZATION="${PING_ISLAND_SKIP_NOTARIZATION:-0}"

SPARKLE_PRIVATE_KEY_PATH="${PING_ISLAND_SPARKLE_PRIVATE_KEY_PATH:-$KEYS_DIR/eddsa_private_key}"
GENERATE_APPCAST="${PING_ISLAND_GENERATE_APPCAST:-0}"

notary_args=()

log_section() {
    echo ""
    echo "=== $1 ==="
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: Missing required command: $1"
        exit 1
    fi
}

resolve_notary_credentials() {
    if [ "$SKIP_NOTARIZATION" = "1" ]; then
        return
    fi

    if [ -n "$NOTARY_APPLE_ID" ] && [ -n "$NOTARY_TEAM_ID" ] && [ -n "$NOTARY_PASSWORD" ]; then
        notary_args=(
            --apple-id "$NOTARY_APPLE_ID"
            --team-id "$NOTARY_TEAM_ID"
            --password "$NOTARY_PASSWORD"
        )
        return
    fi

    if xcrun notarytool history --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" >/dev/null 2>&1; then
        notary_args=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
        return
    fi

    echo "ERROR: No usable notarization credentials were found."
    echo "Provide one of:"
    echo "  1. PING_ISLAND_NOTARY_APPLE_ID / PING_ISLAND_NOTARY_TEAM_ID / PING_ISLAND_NOTARY_PASSWORD"
    echo "  2. A notarytool keychain profile named '$NOTARY_KEYCHAIN_PROFILE'"
    echo ""
    echo "You can skip notarization explicitly with PING_ISLAND_SKIP_NOTARIZATION=1."
    exit 1
}

notarize_and_staple() {
    local submit_path="$1"
    local staple_path="$2"

    if [ "$SKIP_NOTARIZATION" = "1" ]; then
        echo "Skipping notarization for $submit_path"
        return
    fi

    echo "Submitting $(basename "$submit_path") for notarization..."
    xcrun notarytool submit "$submit_path" "${notary_args[@]}" --wait

    echo "Stapling $(basename "$staple_path")..."
    xcrun stapler staple "$staple_path"
    xcrun stapler validate "$staple_path"
}

find_sparkle_bin_dir() {
    shopt -s nullglob
    local candidates=(
        "$DERIVED_DATA_PATH/SourcePackages/artifacts/sparkle/Sparkle/bin"
        "$HOME/Library/Developer/Xcode/DerivedData/PingIsland-*/SourcePackages/artifacts/sparkle/Sparkle/bin"
        "$PROJECT_DIR/.build/artifacts/sparkle/Sparkle/bin"
    )

    for candidate in "${candidates[@]}"; do
        if [ -x "$candidate/generate_appcast" ] && [ -x "$candidate/sign_update" ]; then
            echo "$candidate"
            return 0
        fi
    done

    return 1
}

generate_sparkle_appcast() {
    if [ "$GENERATE_APPCAST" != "1" ]; then
        return
    fi

    log_section "Generating Sparkle Appcast"

    if [ ! -f "$SPARKLE_PRIVATE_KEY_PATH" ]; then
        echo "ERROR: Sparkle private key not found at $SPARKLE_PRIVATE_KEY_PATH"
        exit 1
    fi

    local sparkle_bin_dir
    if ! sparkle_bin_dir="$(find_sparkle_bin_dir)"; then
        echo "ERROR: Could not find Sparkle tools in DerivedData or local artifacts."
        exit 1
    fi

    local appcast_dir="$RELEASE_DIR/appcast"
    mkdir -p "$appcast_dir"

    cp "$DMG_PATH" "$appcast_dir/"
    if [ -f "$NOTES_ASSET_PATH" ]; then
        cp "$NOTES_ASSET_PATH" "$appcast_dir/"
    fi

    "$sparkle_bin_dir/generate_appcast" \
        --ed-key-file "$SPARKLE_PRIVATE_KEY_PATH" \
        "$appcast_dir"

    echo "Appcast generated at: $appcast_dir/appcast.xml"
}

require_command xcodebuild
require_command xcrun
require_command ditto
require_command hdiutil
require_command codesign
require_command spctl

resolve_notary_credentials

echo "=== Packaging Signed Ping Island ==="
echo ""

export PING_ISLAND_BUILD_DIR="$BUILD_DIR"
"$SCRIPT_DIR/build.sh"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App bundle not found at $APP_PATH"
    exit 1
fi

log_section "Verifying App Signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute -vv "$APP_PATH"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")

mkdir -p "$RELEASE_DIR"

ZIP_PATH="$RELEASE_DIR/$APP_PRODUCT_NAME-$VERSION-$BUILD.zip"
DMG_PATH="$RELEASE_DIR/$APP_PRODUCT_NAME-$VERSION-$BUILD.dmg"
NOTES_PATH="$NOTES_DIR/$VERSION.md"
NOTES_ASSET_PATH="$RELEASE_DIR/$APP_PRODUCT_NAME-$VERSION.md"
NOTARY_ZIP_PATH="$BUILD_DIR/$APP_PRODUCT_NAME-$VERSION-$BUILD-notarization.zip"

rm -f "$ZIP_PATH" "$DMG_PATH" "$NOTARY_ZIP_PATH"
rm -rf "$STAGING_DIR"

log_section "Notarizing App Bundle"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARY_ZIP_PATH"
notarize_and_staple "$NOTARY_ZIP_PATH" "$APP_PATH"
rm -f "$NOTARY_ZIP_PATH"

log_section "Creating ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

log_section "Creating DMG"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "Ping Island" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$STAGING_DIR"

notarize_and_staple "$DMG_PATH" "$DMG_PATH"
if [ "$SKIP_NOTARIZATION" != "1" ]; then
    spctl --assess --type open -vv "$DMG_PATH"
fi

if [ -f "$NOTES_PATH" ]; then
    cp "$NOTES_PATH" "$NOTES_ASSET_PATH"
    echo "Release notes copied: $NOTES_ASSET_PATH"
fi

generate_sparkle_appcast

echo ""
echo "=== Signed Package Ready ==="
echo "Version: $VERSION ($BUILD)"
echo "App: $APP_PATH"
echo "ZIP: $ZIP_PATH"
echo "DMG: $DMG_PATH"
