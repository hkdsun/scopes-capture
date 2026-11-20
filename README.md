# Scopes Capture

macOS color-grading scopes (OmniScope-style), GPU-accelerated with Metal.
Scopes:
- **False Color** — exposure: ARRI, RED Video, 5/10-band greyscale, Heatmap; retouching: Solar Curve, Contour Lines, Zone System, Print Clipping, Channel Clipping; custom presets as JSON (Load/Save).
- **Skintone** — highlights skin hues (YCbCr skin line or HSL), green on-line → red off-line.
- **Tint** — green ↔ magenta (CIE a*) per pixel, with GPU-measured average cast.
- **Neutrals** — near-neutral pixels colored blue ↔ yellow (CIE b*) for setting white balance.
- **Twin Peaks** — diamond display (B/G over R/G) with RGB gamut outline.

## Build & run

    scripts/build-app.sh            # release build → build/ScopesCapture.app
    open build/ScopesCapture.app

Requires macOS 14+. The first capture asks for Screen Recording permission
(System Settings › Privacy & Security › Screen & System Audio Recording); quit and
reopen the app after granting. The bundle is ad-hoc signed, so a rebuild may need
the permission re-granted — set `CODESIGN_IDENTITY` to a real signing identity to avoid that.

## Headless test

    .build/release/ScopesCapture --render <input.png|ramp|huesweep|wbchart> out.png <mode>
    # mode: a preset name ("RED Video", Heatmap, …), skin-ycbcr, skin-hsl, tint, neutrals, twinpeaks
    # tint/neutrals also print the measured average a*/b*

## Pipeline

ScreenCaptureKit (BGRA IOSurface) → CVMetalTextureCache (zero-copy) → fragment shader
(Rec.709 Y′ → 1024-entry LUT texture) → MTKView. Redraws only when a frame or setting changes.
