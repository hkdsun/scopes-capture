import MetalKit
import Observation
import SwiftUI

/// One measurement scope in the scope column.
@Observable
@MainActor
final class ScopePane: Identifiable {
    let id = UUID()
    let renderer: ScopeRenderer
    var config: ScopePaneConfig {
        didSet {
            renderer.config = config
            if config.kind != oldValue.kind { clip = nil }
            onChange?()
        }
    }
    /// Histogram clipping readout.
    private(set) var clip: ClipStats?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var lastClipUpdate = Date.distantPast

    init(config: ScopePaneConfig, renderer: ScopeRenderer) {
        self.config = config
        self.renderer = renderer
        renderer.onClipStats = { [weak self] stats in
            guard let self, Date().timeIntervalSince(self.lastClipUpdate) > 0.2 || self.clip == nil else { return }
            self.lastClipUpdate = Date()
            self.clip = stats
        }
    }
}

/// Right-hand column of 1–3 scope panes.
struct ScopeStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            VSplitView {
                ForEach(model.panes) { pane in
                    ScopePaneView(pane: pane)
                        .frame(minHeight: 140)
                }
            }
            HStack {
                Button {
                    model.addPane()
                } label: {
                    Label("Add Scope", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(model.panes.count >= AppModel.maxPanes)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color.black)
    }
}

struct ScopePaneView: View {
    @Environment(AppModel.self) private var model
    let pane: ScopePane

    private var focused: Bool { model.focusedPaneID == pane.id }

    var body: some View {
        VStack(spacing: 0) {
            header
            plot
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black)
        .overlay(alignment: .top) {
            Rectangle().fill(focused ? Color.accentColor.opacity(0.7) : .clear).frame(height: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(Array(ScopeKind.allCases.enumerated()), id: \.element) { i, kind in
                    Button("\(kind.title)  (⇧\(i + 1))") {
                        pane.config = ScopePaneConfig(kind: kind, mode: 0)
                        model.focusedPaneID = pane.id
                    }
                }
            } label: {
                Text(pane.config.kind.title).fontWeight(.semibold)
            }
            .fixedSize()

            if pane.config.kind.modes.count > 1 {
                Menu {
                    ForEach(Array(pane.config.kind.modes.enumerated()), id: \.offset) { i, name in
                        Toggle(name, isOn: Binding(get: { pane.config.mode == i },
                                                   set: { if $0 { pane.config.mode = i; model.focusedPaneID = pane.id } }))
                    }
                } label: {
                    Text(pane.config.modeName)
                }
                .fixedSize()
            }

            if pane.config.kind == .vectorscope {
                Picker("Zoom", selection: Binding(get: { pane.config.zoom }, set: { pane.config.zoom = $0 })) {
                    Text("1×").tag(Float(1))
                    Text("2×").tag(Float(2))
                    Text("5×").tag(Float(5))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            Spacer(minLength: 4)

            if pane.config.kind == .histogram, pane.config.mode <= 1, let clip = pane.clip {
                Text("▼\(percent(clip.low))  ▲\(percent(clip.high))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(clip.low > 0.005 || clip.high > 0.005 ? .orange : .secondary)
                    .help("Share of pixels clipped to black / white")
            }

            Menu {
                if pane.config.kind == .histogram {
                    Toggle("Log Scale", isOn: Binding(get: { pane.config.logScale }, set: { pane.config.logScale = $0 }))
                } else {
                    Picker("Brightness", selection: Binding(get: { pane.config.brightness }, set: { pane.config.brightness = $0 })) {
                        Text("Dim").tag(Float(0.7))
                        Text("Normal").tag(Float(1))
                        Text("Bright").tag(Float(1.4))
                        Text("Brightest").tag(Float(2))
                    }
                }
                if model.panes.count > 1 {
                    Divider()
                    Button("Remove Scope") { model.removePane(pane) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.system(size: 11))
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(white: 0.09))
    }

    @ViewBuilder
    private var plot: some View {
        let view = MetalScopeView(delegate: pane.renderer, frames: model.frames,
                                  onMouseDown: { model.focusedPaneID = pane.id }) { view in
            view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pane.renderer.view = view
        }
        .overlay { GeometryReader { geo in ScopeLabels(config: pane.config, legalRange: model.settings.legalRange, size: geo.size) } }
        if let aspect = pane.config.kind.aspect {
            view.aspectRatio(aspect, contentMode: .fit)
        } else {
            view
        }
    }

    private func percent(_ v: Float) -> String {
        v < 0.001 ? "0%" : String(format: v < 0.1 ? "%.1f%%" : "%.0f%%", v * 100)
    }
}

/// Text labels drawn over a scope's Metal graticule; positions use the same geometry as
/// the shaders.
struct ScopeLabels: View {
    let config: ScopePaneConfig
    let legalRange: Bool
    let size: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            switch config.kind {
            case .waveform: waveform
            case .vectorscope: vectorscope
            case .satLum: satLum
            case .histogram: histogram
            case .twinPeaks: twinPeaks
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func label(_ text: String, _ color: Color = .secondary, at p: CGPoint, size font: CGFloat = 9) -> some View {
        Text(text)
            .font(.system(size: font, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .fixedSize()
            .position(p)
    }

    private var waveform: some View {
        let (lo, hi): (Double, Double) = legalRange ? (-0.07, 1.09) : (-0.04, 1.04)
        let parade = config.mode >= 2
        let names = config.mode == 3 ? ["Y", "R", "G", "B"] : ["R", "G", "B"]
        let colors: [String: Color] = ["Y": .white, "R": .red, "G": .green, "B": Color(red: 0.4, green: 0.55, blue: 1)]
        return ZStack(alignment: .topLeading) {
            ForEach([0, 25, 50, 75, 100], id: \.self) { v in
                label("\(v)", at: CGPoint(x: 12, y: (hi - Double(v) / 100) / (hi - lo) * size.height - 6))
            }
            if parade {
                ForEach(Array(names.enumerated()), id: \.offset) { i, name in
                    label(name, colors[name] ?? .white,
                          at: CGPoint(x: (Double(i) + 0.5) * size.width / Double(names.count), y: 8), size: 10)
                }
            }
        }
    }

    private func vectorPoint(_ cb: Double, _ cr: Double) -> CGPoint {
        let e = Double(VectorscopeGeometry.extent(zoom: config.zoom))
        return CGPoint(x: (cb + e) / (2 * e) * size.width, y: (e - cr) / (2 * e) * size.height)
    }

    private var vectorscope: some View {
        let targets: [(String, (Double, Double, Double), Color)] = [
            ("R", (1, 0, 0), .red), ("Yl", (1, 1, 0), .yellow), ("G", (0, 1, 0), .green),
            ("Cy", (0, 1, 1), .cyan), ("B", (0, 0, 1), Color(red: 0.4, green: 0.55, blue: 1)), ("Mg", (1, 0, 1), Color(red: 1, green: 0.3, blue: 1)),
        ]
        return ZStack(alignment: .topLeading) {
            ForEach(Array(targets.enumerated()), id: \.offset) { i, t in
                let angle: Double = config.mode == 0
                    ? { let p = VectorscopeGeometry.cbcr(t.1.0, t.1.1, t.1.2); return atan2(p.cr, p.cb) }()
                    : (VectorscopeGeometry.hslRedAngleDegrees + Double(i) * 60) * .pi / 180
                // Just inside the ring, between the 75% and 100% target boxes.
                let r = config.mode == 0
                    ? { let p = VectorscopeGeometry.cbcr(t.1.0, t.1.1, t.1.2); return hypot(p.cb, p.cr) }() * 0.87
                    : 0.45
                let p = vectorPoint(cos(angle) * r, sin(angle) * r)
                if p.x > 6, p.y > 6, p.x < size.width - 6, p.y < size.height - 6 {
                    label(t.0, t.2.opacity(0.85), at: p, size: 10)
                }
            }
            label("\(Int(VectorscopeGeometry.skinLineDegrees))° skin line", Color(red: 0.8, green: 0.6, blue: 0.45),
                  at: CGPoint(x: 50, y: 10))
        }
    }

    private var satLum: some View {
        let lo = Double(SatLumGeometry.lo), hi = Double(SatLumGeometry.hi)
        func x(_ v: Double) -> Double { (v - lo) / (hi - lo) * size.width }
        func y(_ v: Double) -> Double { (hi - v) / (hi - lo) * size.height }
        return ZStack(alignment: .topLeading) {
            ForEach([0, 50, 100], id: \.self) { v in
                label("\(v)", at: CGPoint(x: min(max(x(Double(v) / 100), 10), size.width - 14), y: size.height - 8))
            }
            ForEach([50, 100], id: \.self) { v in
                label("\(v)", at: CGPoint(x: 12, y: y(Double(v) / 100) + 8))
            }
            label("Luma →", at: CGPoint(x: size.width / 2, y: size.height - 8))
            label(config.mode == 0 ? "Chroma ↑" : "HSL Sat ↑", at: CGPoint(x: 36, y: 10))
            label("— 95th percentile", Color(red: 1, green: 0.68, blue: 0.18), at: CGPoint(x: size.width - 62, y: 10))
        }
    }

    private var histogram: some View {
        let ticks: [(Double, String)] = config.mode == 3
            ? [(0, "0°"), (1.0 / 3, "120°"), (2.0 / 3, "240°"), (1, "360°")]
            : [(0, "0"), (0.5, "50"), (1, "100")]
        return ZStack(alignment: .topLeading) {
            ForEach(Array(ticks.enumerated()), id: \.offset) { _, t in
                label(t.1, at: CGPoint(x: min(max(t.0 * size.width, 12), size.width - 16), y: size.height - 8))
            }
            if config.logScale { label("log", at: CGPoint(x: size.width - 14, y: 8)) }
        }
    }

    private var twinPeaks: some View {
        let items: [(String, Color, Float, Float)] = [
            ("G", .green, -1, 1), ("B", .blue, 1, 1),
            ("G", .green, -1, -1), ("R", .red, 1, -1),
        ]
        return ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let (u, v) = TwinPeaksGeometry.uv(x: item.2, y: item.3)
                label(item.0, item.1.opacity(0.9),
                      at: CGPoint(x: CGFloat(u) * size.width + (item.2 < 0 ? -2 : 2),
                                  y: CGFloat(v) * size.height + (item.3 > 0 ? -12 : 12)), size: 11)
            }
        }
    }
}
