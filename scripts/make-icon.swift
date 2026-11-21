// Renders the app icon (1024×1024 master PNG) with CoreGraphics.
// Usage: swift scripts/make-icon.swift <out.png>    (scripts/make-icon.sh builds the .icns)
//
// Design: a dark macOS-style tile with a faint scope graticule and a glowing tone trace
// drawn in the false-color heatmap gradient (violet shadows → red highlights).

import AppKit
import CoreGraphics

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// macOS icon grid: 824pt body centred on a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow + body fill.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.45))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(0x15171C))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(0x2B2F38), rgb(0x0F1115)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

// Scope area and graticule.
let plot = body.insetBy(dx: 118, dy: 150)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.09))
ctx.setLineWidth(3)
for i in 0...4 {
    let y = plot.minY + plot.height * CGFloat(i) / 4
    ctx.move(to: CGPoint(x: plot.minX - 30, y: y))
    ctx.addLine(to: CGPoint(x: plot.maxX + 30, y: y))
}
ctx.strokePath()
ctx.setStrokeColor(rgb(0xFFFFFF, 0.045))
for i in 0...6 {
    let x = plot.minX + plot.width * CGFloat(i) / 6
    ctx.move(to: CGPoint(x: x, y: plot.minY - 30))
    ctx.addLine(to: CGPoint(x: x, y: plot.maxY + 30))
}
ctx.strokePath()

// Tone trace: an S-curve with a little texture, like a waveform's centre line.
func trace(offset: CGFloat, wobble: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let steps = 160
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let s = t * t * (3 - 2 * t)                       // smoothstep
        let y = 0.08 + 0.84 * (0.35 * t + 0.65 * s)        // shadows → highlights
            + wobble * sin(t * .pi * 5.0 + offset * 3) * (1 - abs(2 * t - 1) * 0.5)
        let p = CGPoint(x: plot.minX + plot.width * t, y: plot.minY + plot.height * (y + offset))
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    return path
}

let heat = CGGradient(colorsSpace: space, colors: [
    rgb(0x7B2FF7), rgb(0x2F6BFF), rgb(0x00C2C2), rgb(0x22C55E),
    rgb(0xD4E21A), rgb(0xFFC300), rgb(0xFF6A00), rgb(0xFF2D2D),
] as CFArray, locations: [0, 0.16, 0.32, 0.47, 0.6, 0.72, 0.86, 1])!

func strokeGradient(_ path: CGPath, width: CGFloat, alpha: CGFloat, glow: CGFloat) {
    ctx.saveGState()
    ctx.setAlpha(alpha)
    if glow > 0 {
        // Soft halo: the stroke rendered blurred behind itself.
        ctx.setShadow(offset: .zero, blur: glow, color: rgb(0x6FA8FF, 0.9))
    }
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(path)
    ctx.setLineWidth(width)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(heat, start: CGPoint(x: plot.minX, y: 0), end: CGPoint(x: plot.maxX, y: 0),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

// Faint "trace density" echoes around the main line, then the main line with a glow.
for (i, off) in [-0.075, -0.045, 0.045, 0.075].enumerated() {
    strokeGradient(trace(offset: off, wobble: 0.018 + CGFloat(i) * 0.004), width: 10, alpha: 0.22, glow: 0)
}
strokeGradient(trace(offset: 0, wobble: 0.012), width: 34, alpha: 1, glow: 36)

// Gloss: subtle top highlight and a hairline rim.
let gloss = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY + 80), options: [])
ctx.restoreGState()

ctx.addPath(bodyPath)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
ctx.setLineWidth(3)
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
