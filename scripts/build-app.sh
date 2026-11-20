#!/bin/bash
# Builds the SwiftPM executable and wraps it in a signed .app bundle.
# Usage: scripts/build-app.sh [debug|release]   (CODESIGN_IDENTITY env var overrides ad-hoc signing)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"

# The Command Line Tools toolchain on this machine can't link SwiftPM manifests;
# fall back to the full Xcode toolchain when xcode-select points at CLT.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/ScopesCapture.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ScopesCapture" "$APP/Contents/MacOS/ScopesCapture"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
