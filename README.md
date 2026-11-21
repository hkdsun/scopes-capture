# Scopes Capture

macOS color-grading scopes (OmniScope-style), GPU-accelerated with Metal.

Picture scopes (drawn over the image):
- **False Color** — exposure: ARRI, RED Video, 5/10-band greyscale, Heatmap; retouching: Solar Curve, Contour Lines, Zone System, Print Clipping, Channel Clipping; custom presets as JSON (Load/Save).
- **Skintone** — highlights skin hues (YCbCr skin line or HSL), green on-line → red off-line.
- **Tint** — green ↔ magenta (CIE a*) per pixel, with GPU-measured average cast.
- **Neutrals** — near-neutral pixels colored blue ↔ yellow (CIE b*) for setting white balance.

Measurement scopes (scope column, press **S**; 1–3 panes, each with its own type and mode):
- **Waveform** — Luma, RGB overlay, RGB Parade, YRGB Parade; 10% graticule.
- **Vectorscope** — YUV with 75%/100% bar targets, skin line and 1×/2×/5× zoom; HSL polar mode.
- **Sat / Lum** — saturation against luma with a 95th-percentile curve.
- **Histogram** — RGB, Luma, Saturation, Hue; log scale; clipped-pixel readout.
- **Twin Peaks** — diamond display (B/G over R/G) with RGB gamut outline.

## Controls

| Key / action | Does |
|---|---|
| 1 / 2 / 3 / 4 | False Color / Skintone / Tint / Neutrals |
| ↑ / ↓ | Previous / next false color preset (False Color mode) |
| Drag the picture | Move the window (full and dock mode) |
| Mouse wheel / trackpad pinch / ⌘ + two-finger scroll | Zoom toward the pointer (pixels go crisp past 1:1) |
| Two-finger scroll | Pan when zoomed in |
| 0 or double-click | Fit the whole picture |
| R | Select the capture region on screen (↩ apply, F whole screen, esc cancel); remembered per display |
| Right-click (or ⌃-click) the picture | Toggle dock mode: picture only, floats above other windows, window keeps the picture's aspect ratio |
| S | Show / hide the scope column |
| ⇧1 – ⇧5 | Focused scope pane → Waveform / Vectorscope / Sat-Lum / Histogram / Twin Peaks |
| ⇧↑ / ⇧↓ | Previous / next mode of the focused scope pane |
| ? | Keyboard shortcut guide (also Help › Keyboard Shortcuts) |
| Q | Quit |

## Build & run

    scripts/build-app.sh            # release build → build/ScopesCapture.app
    open build/ScopesCapture.app

Requires macOS 14+. The first capture asks for Screen Recording permission
(System Settings › Privacy & Security › Screen & System Audio Recording); quit and
reopen the app after granting. The build script signs with your "Apple Development"
certificate when one is in the keychain (override with `CODESIGN_IDENTITY`), so the
permission survives rebuilds; without one it falls back to ad-hoc signing, which re-prompts.

## Headless test

    .build/release/ScopesCapture --render <input.png|ramp|huesweep|wbchart|bars|l10r-bars> out.png <mode>
    # picture modes: a preset name ("RED Video", Heatmap, …), skin-ycbcr, skin-hsl, tint, neutrals
    #   (tint/neutrals also print the measured average a*/b*)
    # measurement modes: waveform-luma, waveform-rgb, parade-rgb, parade-yrgb, vector-yuv, vector-hsl,
    #   satlum, satlum-hsl, hist-rgb, hist-luma, hist-sat, hist-hue, twinpeaks
    # l10r-bars feeds colour bars through the 10-bit capture path
    .build/release/ScopesCapture --bench     # GPU time per measurement scope on a 4K source

## Pipeline

ScreenCaptureKit (10-bit `l10r` IOSurface, falling back to 8-bit BGRA) → CVMetalTextureCache
(zero-copy) → MTKViews that redraw only when a frame or setting changes.

- Picture scopes: one fragment shader (Rec.709 Y′ → 1024-entry LUT, Lab, skin hue).
- Measurement scopes: a once-per-frame **analysis pass** point-samples the frame (≤ ~1080p),
  dithers by one code value and writes R′G′B′Y′ + Cb Cr hue sat to half-float textures; each
  pane then **accumulates** samples into bins with GPU atomics (histograms count per
  threadgroup first) and a fragment shader tone-maps the bins and draws the graticule.
  About 0.4–1 ms of GPU time per pane on a 4K source (M3 Max, `--bench`).
