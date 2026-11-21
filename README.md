# Scopes Capture

macOS color-grading scopes (OmniScope-style), GPU-accelerated with Metal.
Scopes:
- **False Color** — exposure: ARRI, RED Video, 5/10-band greyscale, Heatmap; retouching: Solar Curve, Contour Lines, Zone System, Print Clipping, Channel Clipping; custom presets as JSON (Load/Save).
- **Skintone** — highlights skin hues (YCbCr skin line or HSL), green on-line → red off-line.
- **Tint** — green ↔ magenta (CIE a*) per pixel, with GPU-measured average cast.
- **Neutrals** — near-neutral pixels colored blue ↔ yellow (CIE b*) for setting white balance.
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

    .build/release/ScopesCapture --render <input.png|ramp|huesweep|wbchart> out.png <mode>
    # mode: a preset name ("RED Video", Heatmap, …), skin-ycbcr, skin-hsl, tint, neutrals, twinpeaks
    # tint/neutrals also print the measured average a*/b*

## Pipeline

ScreenCaptureKit (BGRA IOSurface) → CVMetalTextureCache (zero-copy) → fragment shader
(Rec.709 Y′ → 1024-entry LUT texture) → MTKView. Redraws only when a frame or setting changes.
