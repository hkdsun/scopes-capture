#!/bin/bash
# Builds the SwiftPM executable and wraps it in a signed .app bundle.
# Usage: scripts/build-app.sh [debug|release]
# Signing identity: $CODESIGN_IDENTITY if set, else the first valid "Apple Development" or
# "ScopesCapture Dev" certificate in the keychain, else ad-hoc. A stable identity keeps the
# Screen Recording permission across rebuilds (ad-hoc signatures change every build).
# Optional env (used by .github/workflows/release.yml):
#   ARCHS="arm64 x86_64"  build a universal binary (default: host arch only)
#   VERSION=1.2.3         stamp CFBundleShortVersionString; BUILD_NUMBER stamps CFBundleVersion
#   CODESIGN_FLAGS="..."  extra codesign flags, e.g. "--options runtime --timestamp" for notarization
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"

# The Command Line Tools toolchain on this machine can't link SwiftPM manifests;
# fall back to the full Xcode toolchain when xcode-select points at CLT.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

ARCH_ARGS=()
for arch in ${ARCHS:-}; do ARCH_ARGS+=(--arch "$arch"); done

swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)"

APP="build/ScopesCapture.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ScopesCapture" "$APP/Contents/MacOS/ScopesCapture"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/"(Apple Development|ScopesCapture Dev)/ { print $2; exit }')"
fi
if [[ -z "$IDENTITY" ]]; then
    echo "warning: no signing certificate found; signing ad-hoc (Screen Recording permission resets each build)" >&2
    IDENTITY="-"
fi

# shellcheck disable=SC2086  # CODESIGN_FLAGS is intentionally word-split
codesign --force ${CODESIGN_FLAGS:-} --sign "$IDENTITY" "$APP"
echo "Built $APP (signed: $(codesign -dv --verbose=2 "$APP" 2>&1 | awk -F= '/^Authority/ { print $2; exit }' || true))"
