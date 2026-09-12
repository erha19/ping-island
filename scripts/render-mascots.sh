#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build/mascot-export"
EXECUTABLE_PATH="${BUILD_DIR}/mascot-export"
ARCH="$(uname -m)"

mkdir -p "${BUILD_DIR}"
cd "${ROOT_DIR}"

xcrun swiftc \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "${ARCH}-apple-macos14.0" \
  -o "${EXECUTABLE_PATH}" \
  "${ROOT_DIR}/scripts/mascot-export/SessionStubs.swift" \
  "${ROOT_DIR}/PingIsland/Models/MascotStatus.swift" \
  "${ROOT_DIR}/PingIsland/UI/Components/TerminalColors.swift" \
  "${ROOT_DIR}/PingIsland/UI/Components/MascotView.swift" \
  "${ROOT_DIR}/scripts/mascot-export/MascotGIFExporterMain.swift"

"${EXECUTABLE_PATH}" "$@"
