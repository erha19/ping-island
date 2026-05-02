#!/bin/zsh

set -euo pipefail

PACKAGE_PATH="${PING_ISLAND_BRIDGE_PACKAGE_PATH:-$SRCROOT/Prototype}"
PRODUCT_NAME="${PING_ISLAND_BRIDGE_PRODUCT_NAME:-PingIslandBridge}"
BUILD_CONFIGURATION=$(echo "${CONFIGURATION:-Debug}" | tr '[:upper:]' '[:lower:]')
SCRATCH_BASE="${DERIVED_FILE_DIR:?DERIVED_FILE_DIR is required}/PingIslandBridge-build"
APP_BRIDGE_PATH="${TARGET_BUILD_DIR:?TARGET_BUILD_DIR is required}/${EXECUTABLE_FOLDER_PATH:?EXECUTABLE_FOLDER_PATH is required}/$PRODUCT_NAME"
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

archs=()
for arch in ${(s: :)${ARCHS:-arm64 x86_64}}; do
  case "$arch" in
    arm64|x86_64)
      if (( ${archs[(Ie)$arch]} == 0 )); then
        archs+=("$arch")
      fi
      ;;
  esac
done

if (( ${#archs[@]} == 0 )); then
  echo "error: No supported architectures found in ARCHS='${ARCHS:-}'" >&2
  exit 1
fi

rm -rf "$SCRATCH_BASE"
mkdir -p "$(dirname "$APP_BRIDGE_PATH")"

bridge_slices=()
for arch in "${archs[@]}"; do
  arch_scratch_path="$SCRATCH_BASE/$arch"
  xcrun swift build \
    --package-path "$PACKAGE_PATH" \
    --product "$PRODUCT_NAME" \
    --configuration "$BUILD_CONFIGURATION" \
    --scratch-path "$arch_scratch_path" \
    --triple "$arch-apple-macosx$DEPLOYMENT_TARGET"

  bridge_path=$(find "$arch_scratch_path" -type f -path "*/$BUILD_CONFIGURATION/$PRODUCT_NAME" | head -n 1)
  if [[ -z "$bridge_path" || ! -x "$bridge_path" ]]; then
    echo "error: Failed to build $PRODUCT_NAME for $arch" >&2
    exit 1
  fi

  bridge_slices+=("$bridge_path")
done

if (( ${#bridge_slices[@]} == 1 )); then
  cp "${bridge_slices[1]}" "$APP_BRIDGE_PATH"
else
  xcrun lipo -create "${bridge_slices[@]}" -output "$APP_BRIDGE_PATH"
fi

chmod 755 "$APP_BRIDGE_PATH"

actual_archs=$(xcrun lipo -archs "$APP_BRIDGE_PATH")
for arch in "${archs[@]}"; do
  if [[ " $actual_archs " != *" $arch "* ]]; then
    echo "error: $PRODUCT_NAME is missing $arch slice; found: $actual_archs" >&2
    exit 1
  fi
done

if [[ "${CODE_SIGNING_ALLOWED:-NO}" == "YES" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
  codesign_args=(
    --force
    --sign "$EXPANDED_CODE_SIGN_IDENTITY"
    --timestamp
  )

  if [[ "${ENABLE_HARDENED_RUNTIME:-NO}" == "YES" ]]; then
    codesign_args+=(--options runtime)
  fi

  if [[ -n "${OTHER_CODE_SIGN_FLAGS:-}" ]]; then
    codesign_args+=(${=OTHER_CODE_SIGN_FLAGS})
  fi

  codesign_args+=("$APP_BRIDGE_PATH")
  /usr/bin/codesign "${codesign_args[@]}"
fi
