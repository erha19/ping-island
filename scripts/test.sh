#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

run_step() {
    local title="$1"
    shift

    echo ""
    echo "=== $title ==="
    "$@"
}

cd "$PROJECT_DIR"

run_step "Prototype Tests" \
    swift test --package-path Prototype

run_step "Clean Debug Build Products" \
    xcodebuild \
        -project PingIsland.xcodeproj \
        -scheme PingIsland \
        -configuration Debug \
        clean

run_step "Root Xcode Unit Tests" \
    xcodebuild \
        -project PingIsland.xcodeproj \
        -scheme PingIsland \
        -configuration Debug \
        CODE_SIGNING_ALLOWED=NO \
        test \
        -only-testing:PingIslandTests

run_step "Clean Before Full Scheme Test" \
    xcodebuild \
        -project PingIsland.xcodeproj \
        -scheme PingIsland \
        -configuration Debug \
        clean

run_step "Root Xcode Full Test Scheme" \
    xcodebuild \
        -project PingIsland.xcodeproj \
        -scheme PingIsland \
        -configuration Debug \
        CODE_SIGN_IDENTITY=- \
        test

echo ""
echo "=== All Tests Passed ==="
