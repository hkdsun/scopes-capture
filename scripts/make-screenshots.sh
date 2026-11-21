#!/bin/bash
# Regenerates the README's scope renders in docs/screenshots/ from docs/sample.jpg using the
# headless renderer (no window or screen-capture permission needed).
# The two app-window screenshots (app-scopes.png, app-dock.png) are taken by hand; see README.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release >/dev/null 2>&1 || swift build -c release  # quiet unless it fails
BIN="$(swift build -c release --show-bin-path)/ScopesCapture"
SRC=docs/sample.jpg
OUT=docs/screenshots
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$OUT"

# Picture scopes: render at full size, then save a 600px-wide JPEG.
picture() { # <mode> <file>
    "$BIN" --render "$SRC" "$TMP/$2.png" "$1" >/dev/null
    sips -Z 600 -s format jpeg -s formatOptions 82 "$TMP/$2.png" --out "$OUT/$2.jpg" >/dev/null
}
picture "ARRI" false-color-arri
picture "RED Video" false-color-red
picture "Heatmap" false-color-heatmap
picture "Zone System" zone-system
picture "Solar Curve" solar-curve
picture "skin-ycbcr" skintone
picture "tint" tint
picture "neutrals" neutrals

# Measurement scopes (high-quality JPEG: dense traces make PNGs several hundred KB each).
scope() { # <mode> <file>
    "$BIN" --render "$SRC" "$TMP/$2.png" "$1" >/dev/null
    sips -s format jpeg -s formatOptions 90 "$TMP/$2.png" --out "$OUT/$2.jpg" >/dev/null
}
scope parade-yrgb waveform-yrgb-parade
scope waveform-rgb waveform-rgb
scope vector-yuv@2 vectorscope-yuv
scope vector-hsl vectorscope-hsl
scope satlum sat-lum
scope hist-rgb histogram-rgb
scope hist-hue histogram-hue
scope twinpeaks twin-peaks

echo "wrote $(ls "$OUT" | wc -l | tr -d ' ') files to $OUT"
