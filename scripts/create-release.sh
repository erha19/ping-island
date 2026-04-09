#!/bin/bash
# Create a release: build, notarize, create DMG, optionally sign for Sparkle, upload to GitHub, update website
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PING_ISLAND_BUILD_DIR:-$PROJECT_DIR/build/release}"
EXPORT_PATH="$BUILD_DIR/export"
RELEASE_DIR="${PING_ISLAND_RELEASE_DIR:-$PROJECT_DIR/releases/signed}"
NOTES_DIR="$PROJECT_DIR/releases/notes"

# GitHub repository (owner/repo format)
GITHUB_REPO="${PING_ISLAND_GITHUB_REPO:-farouqaldori/ping-island}"

# Website repo for auto-updating appcast
WEBSITE_DIR="${PING_ISLAND_WEBSITE:-$PROJECT_DIR/../PingIsland-website}"
WEBSITE_PUBLIC="$WEBSITE_DIR/public"

APP_PATH="$EXPORT_PATH/Ping Island.app"
APP_NAME="PingIsland"
NOTARY_PROFILE="${PING_ISLAND_NOTARY_KEYCHAIN_PROFILE:-PingIsland}"

echo "=== Creating Release ==="
echo ""

export PING_ISLAND_BUILD_DIR="$BUILD_DIR"
export PING_ISLAND_RELEASE_DIR="$RELEASE_DIR"
export PING_ISLAND_GENERATE_APPCAST=1
export PING_ISLAND_NOTARY_KEYCHAIN_PROFILE="$NOTARY_PROFILE"

"$SCRIPT_DIR/package-release.sh"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: App not found at $APP_PATH"
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PATH/Contents/Info.plist")
DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION-$BUILD.dmg"
NOTES_PATH="$NOTES_DIR/$VERSION.md"
NOTES_ASSET_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.md"

if [ ! -f "$DMG_PATH" ]; then
    echo "ERROR: DMG not found at $DMG_PATH"
    exit 1
fi

echo "Version: $VERSION (build $BUILD)"
echo ""

mkdir -p "$RELEASE_DIR" "$NOTES_DIR"

# ============================================
# Step 1: Create GitHub Release
# ============================================
echo "=== Step 1: Creating GitHub Release ==="

GITHUB_DOWNLOAD_URL=""

if ! command -v gh >/dev/null 2>&1; then
    echo "WARNING: gh CLI not found. Install with: brew install gh"
    echo "Skipping GitHub release."
else
    if gh release view "v$VERSION" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
        echo "Release v$VERSION already exists. Updating..."
        gh release upload "v$VERSION" "$DMG_PATH" --repo "$GITHUB_REPO" --clobber
        if [ -f "$NOTES_ASSET_PATH" ]; then
            gh release upload "v$VERSION" "$NOTES_ASSET_PATH" --repo "$GITHUB_REPO" --clobber
        fi
        if [ -f "$NOTES_PATH" ]; then
            gh release edit "v$VERSION" \
                --repo "$GITHUB_REPO" \
                --title "Ping Island v$VERSION" \
                --notes-file "$NOTES_PATH"
        fi
    else
        echo "Creating release v$VERSION..."
        RELEASE_ASSETS=("$DMG_PATH")
        if [ -f "$NOTES_ASSET_PATH" ]; then
            RELEASE_ASSETS+=("$NOTES_ASSET_PATH")
        fi

        if [ -f "$NOTES_PATH" ]; then
            gh release create "v$VERSION" "${RELEASE_ASSETS[@]}" \
                --repo "$GITHUB_REPO" \
                --title "Ping Island v$VERSION" \
                --notes-file "$NOTES_PATH"
        else
            gh release create "v$VERSION" "${RELEASE_ASSETS[@]}" \
                --repo "$GITHUB_REPO" \
                --title "Ping Island v$VERSION" \
                --notes "## Ping Island v$VERSION

### Installation
1. Download \`$(basename "$DMG_PATH")\`
2. Open the DMG and drag Ping Island to Applications
3. Launch Ping Island from Applications

### Auto-updates
After installation, Ping Island will automatically check for updates."
        fi
    fi

    GITHUB_DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION/$(basename "$DMG_PATH")"
    echo "GitHub release created: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
    echo "Download URL: $GITHUB_DOWNLOAD_URL"
fi

echo ""

# ============================================
# Step 2: Update website appcast and deploy
# ============================================
echo "=== Step 2: Updating Website ==="

if [ -d "$WEBSITE_PUBLIC" ] && [ -f "$RELEASE_DIR/appcast/appcast.xml" ]; then
    cp "$RELEASE_DIR/appcast/appcast.xml" "$WEBSITE_PUBLIC/appcast.xml"
    if [ -f "$NOTES_ASSET_PATH" ]; then
        cp "$NOTES_ASSET_PATH" "$WEBSITE_PUBLIC/"
    fi

    if [ -n "$GITHUB_DOWNLOAD_URL" ]; then
        sed -i '' "s|url=\"[^\"]*$(basename "$DMG_PATH")\"|url=\"$GITHUB_DOWNLOAD_URL\"|g" "$WEBSITE_PUBLIC/appcast.xml"
        echo "Updated appcast.xml with GitHub download URL"
    fi

    CONFIG_FILE="$WEBSITE_DIR/src/config.ts"
    if [ -n "$GITHUB_DOWNLOAD_URL" ]; then
        cat > "$CONFIG_FILE" << EOF
// Auto-updated by create-release.sh
export const LATEST_VERSION = "$VERSION";
export const DOWNLOAD_URL = "$GITHUB_DOWNLOAD_URL";
EOF
        echo "Updated src/config.ts with version $VERSION"
    fi

    cd "$WEBSITE_DIR"
    if [ -d ".git" ]; then
        git add public/appcast.xml src/config.ts
        if [ -f "$NOTES_ASSET_PATH" ]; then
            git add "public/$APP_NAME-$VERSION.md"
        fi
        if ! git diff --cached --quiet; then
            git commit -m "Update appcast for v$VERSION"
            echo "Committed appcast update"

            read -p "Push website changes to deploy? (Y/n) " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                git push
                echo "Website deployed!"
            else
                echo "Changes committed but not pushed. Run 'git push' in $WEBSITE_DIR to deploy."
            fi
        else
            echo "No changes to commit"
        fi
    else
        echo "Copied appcast.xml to $WEBSITE_PUBLIC/"
        echo "Note: Website directory is not a git repo"
    fi
    cd "$PROJECT_DIR"
else
    echo "Website directory not found or appcast not generated"
    echo "Skipping website update."
fi

echo ""
echo "=== Release Complete ==="
echo ""
echo "Files created:"
echo "  - DMG: $DMG_PATH"
if [ -f "$RELEASE_DIR/appcast/appcast.xml" ]; then
    echo "  - Appcast: $RELEASE_DIR/appcast/appcast.xml"
fi
if [ -f "$NOTES_ASSET_PATH" ]; then
    echo "  - Release notes: $NOTES_ASSET_PATH"
fi
if [ -n "$GITHUB_DOWNLOAD_URL" ]; then
    echo "  - GitHub: https://github.com/$GITHUB_REPO/releases/tag/v$VERSION"
fi
if [ -f "$WEBSITE_PUBLIC/appcast.xml" ]; then
    echo "  - Website: $WEBSITE_PUBLIC/appcast.xml"
fi
