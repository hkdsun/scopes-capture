import MetalKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showOptions = false

    var body: some View {
        let docked = model.dockMode
        Group {
            if docked {
                // Picture only, extending under the (transparent) title bar.
                scopeView.ignoresSafeArea()
            } else {
                HSplitView {
                    imageColumn
                        .frame(minWidth: 420, maxWidth: .infinity)
                    if model.showTwinPeaks {
                        TwinPeaksPanel(renderer: model.twinPeaks, frames: model.frames)
                            .frame(minWidth: 220, idealWidth: 320, maxWidth: 700)
                    }
                }
            }
        }
        .frame(minWidth: docked ? 120 : 640, minHeight: docked ? 68 : 400)
        .background(Color.black)
        .ignoresSafeArea(edges: docked ? .top : [])
        .overlay(alignment: .top) { toast }
        .overlay {
            if model.showShortcuts {
                ShortcutsGuide { model.showShortcuts = false }
            }
        }
        .toolbar { toolbar }
        .toolbar(docked ? .hidden : .visible, for: .windowToolbar)
        .background(WindowChrome(docked: docked, aspect: model.sourceSize))
        .task {
            // Test hooks: `--image <path>` opens a still without touching screen capture
            // (so no permission prompt); `--dock` starts in dock mode.
            if CommandLine.arguments.contains("--dock") { model.dockMode = true }
            if let i = CommandLine.arguments.firstIndex(of: "--image"), i + 1 < CommandLine.arguments.count {
                model.loadImage(url: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
                return
            }
            await model.capture.captureMainDisplay()
            await model.capture.keepSourcesFresh()
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.loadImage(url: url) } }
            }
            return true
        }
    }

    private var scopeView: some View {
        ZStack {
            MetalScopeView(delegate: model.imageScope, frames: model.frames,
                           zoomTarget: model.imageScope,
                           onRightClick: { model.dockMode.toggle() }) { model.imageScope.view = $0 }
            if model.sourceSize == nil { placeholder.allowsHitTesting(false) }
        }
    }

    private var imageColumn: some View {
        VStack(spacing: 0) {
            scopeView
            chrome
        }
    }

    /// Brief name of the mode/preset just picked from the keyboard (useful in dock mode).
    @ViewBuilder
    private var toast: some View {
        if let text = model.toast {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.65), in: Capsule())
                .foregroundStyle(.white)
                .padding(.top, model.dockMode ? 10 : 8)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// Legend + status bar under the image (hidden in dock mode).
    @ViewBuilder
    private var chrome: some View {
        Group {
            Divider()
            Group {
                switch model.settings.imageMode {
                case .falseColor:
                    if model.settings.preset.channel == .rgbClipping {
                        ChannelClippingLegend()
                    } else {
                        FalseColorLegend(preset: model.settings.preset)
                    }
                case .skintone: SkintoneLegend(settings: model.settings)
                case .tint, .neutrals: WhiteBalanceLegend(settings: model.settings, stats: model.wbStats)
                }
            }
            .frame(height: 34)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            statusBar
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.dashed.badge.record").font(.system(size: 36))
            Text("Choose a display or window from **Source**, or drop an image here.")
            Text("Press ? for keyboard shortcuts · right-click the picture for dock mode").font(.caption)
        }
        .foregroundStyle(.secondary)
    }

    private var statusBar: some View {
        HStack {
            Text(model.sourceDescription)
            if let size = model.sourceSize {
                Text("\(Int(size.width))×\(Int(size.height))").foregroundStyle(.secondary)
            }
            Spacer()
            if let err = model.capture.lastError ?? model.capture.sourcesError ?? model.message {
                Text(err).foregroundStyle(.red).lineLimit(1).truncationMode(.tail)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = model
        ToolbarItem(placement: .navigation) { sourceMenu }
        ToolbarItem {
            Picker("Scope", selection: $model.settings.imageMode) {
                ForEach(ImageScopeMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Scope mode (keys 1–4)")
        }
        ToolbarItem {
            switch model.settings.imageMode {
            case .falseColor:
                presetMenu
            case .skintone:
                Picker("Skintone mode", selection: $model.settings.skintoneMode) {
                    ForEach(SkintoneMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            case .tint, .neutrals:
                EmptyView()
            }
        }
        ToolbarItem {
            HStack(spacing: 6) {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
                Slider(value: $model.settings.opacity, in: 0...1).frame(width: 80)
            }
            .help("Overlay opacity")
        }
        ToolbarItem {
            Button { showOptions.toggle() } label: { Label("Options", systemImage: "slider.horizontal.3") }
                .popover(isPresented: $showOptions, arrowEdge: .bottom) { OptionsPanel() }
        }
        ToolbarItem {
            Toggle(isOn: $model.showTwinPeaks) { Label("Twin Peaks", systemImage: "rhombus") }
                .help("Show Twin Peaks scope")
        }
    }

    private var sourceMenu: some View {
        Menu {
            Section("Displays") {
                ForEach(model.capture.displays, id: \.displayID) { display in
                    Button(ScreenCaptureController.name(for: display)) {
                        model.startCapture { await $0.capture(display: display) }
                    }
                }
            }
            Section("Windows") {
                ForEach(model.capture.windows, id: \.windowID) { window in
                    Button(ScreenCaptureController.title(for: window)) {
                        model.startCapture { await $0.capture(window: window) }
                    }
                }
            }
            Divider()
            Button("Select Capture Region…  (R)") { model.editRegion() }
            Divider()
            Button("Open Image…") { model.openImage() }
            Button("Stop Capture") { Task { await model.capture.stop() } }
                .disabled(model.capture.activeSourceName == nil)
        } label: {
            Label("Source", systemImage: "rectangle.on.rectangle")
        }
    }

    private var presetMenu: some View {
        Menu {
            Section("Exposure") { presetItems(FalseColorPreset.exposure) }
            Section("Retouching") { presetItems(FalseColorPreset.retouching) }
            if !model.userPresets.isEmpty {
                Section("Custom") { presetItems(model.userPresets) }
            }
            Divider()
            Button("Load Preset…") { model.loadPreset() }
            Button("Save Preset…") { model.savePreset() }
        } label: {
            Text(model.settings.preset.name)
        }
        .fixedSize()
        .help("False color preset (↑/↓ to cycle)")
    }

    private func presetItems(_ presets: [FalseColorPreset]) -> some View {
        ForEach(presets) { preset in
            Toggle(preset.name, isOn: Binding(
                get: { model.settings.preset == preset },
                set: { if $0 { model.settings.preset = preset } }))
        }
    }
}

struct OptionsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Signal") {
                Toggle("Legal range (16–235)", isOn: $model.settings.legalRange)
            }
            Section("False Color") {
                Toggle("Original color between bands", isOn: $model.settings.colorInGaps)
            }
            Section("Skintone") {
                LabeledContent("Hue tolerance") {
                    HStack {
                        Slider(value: $model.settings.skinTolerance, in: 3...40)
                        Text("±\(Int(model.settings.skinTolerance))°").monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
                LabeledContent("Min saturation") {
                    HStack {
                        Slider(value: $model.settings.skinMinSaturation, in: 0...0.5)
                        Text("\(Int(model.settings.skinMinSaturation * 100))%").monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
                Toggle("Dim non-skin areas", isOn: $model.settings.dimNonSkin)
            }
            Section("Tint & Neutrals (L*a*b*)") {
                LabeledContent("Full color at") {
                    HStack {
                        Slider(value: $model.settings.wbRange, in: 2...30)
                        Text("±\(Int(model.settings.wbRange))").monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
                LabeledContent("Neutral if C* <") {
                    HStack {
                        Slider(value: $model.settings.neutralChroma, in: 3...30)
                        Text("\(Int(model.settings.neutralChroma))").monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
                Toggle("Tint: only near-neutral pixels", isOn: $model.settings.tintNeutralsOnly)
            }
        }
        .formStyle(.grouped)
        .frame(width: 340)
    }
}

/// MTKView that redraws only when a new frame or setting arrives.
struct MetalScopeView: NSViewRepresentable {
    let delegate: MTKViewDelegate
    let frames: FrameSource
    var zoomTarget: ImageScopeRenderer? = nil
    var onRightClick: (() -> Void)? = nil
    let onCreate: (MTKView) -> Void

    func makeNSView(context: Context) -> ScopeMTKView {
        let view = ScopeMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = scopePixelFormat
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.05, alpha: 1)
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = delegate
        view.needsDisplay = true
        frames.attach(view)
        onCreate(view)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ScopeMTKView, context: Context) {
        view.onRightClick = onRightClick
        view.zoomTarget = zoomTarget
    }
}

/// MTKView that reports right-clicks (or control-clicks) and acts as a window drag handle:
/// left-click and drag on the picture moves the window, in dock mode and full mode alike.
final class ScopeMTKView: MTKView {
    var onRightClick: (() -> Void)?
    /// When set, scroll/pinch zooms and pans this renderer's picture.
    weak var zoomTarget: ImageScopeRenderer?

    /// Event location in normalized device coordinates (−1…1, y up).
    private func ndc(_ event: NSEvent) -> SIMD2<Float> {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return [Float(p.x / bounds.width * 2 - 1), Float(p.y / bounds.height * 2 - 1)]
    }

    /// Mouse wheel zooms (toward the cursor). Trackpad / Magic Mouse two-finger scroll pans
    /// when zoomed in; hold ⌘ to zoom with it instead.
    override func scrollWheel(with event: NSEvent) {
        guard let target = zoomTarget else { return super.scrollWheel(with: event) }
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            guard bounds.width > 0, bounds.height > 0 else { return }
            target.pan(by: [Float(event.scrollingDeltaX / bounds.width * 2),
                            Float(-event.scrollingDeltaY / bounds.height * 2)])
            return
        }
        // Device-native direction: rolling the wheel away from you zooms in, whatever the
        // natural-scrolling setting.
        var dy = Float(event.scrollingDeltaY)
        if event.isDirectionInvertedFromDevice { dy = -dy }
        if event.hasPreciseScrollingDeltas { dy /= 40 }
        guard dy != 0 else { return }
        target.zoom(by: pow(1.15, dy), anchor: ndc(event))
    }

    /// Trackpad pinch.
    override func magnify(with event: NSEvent) {
        guard let target = zoomTarget else { return super.magnify(with: event) }
        target.zoom(by: Float(1 + event.magnification), anchor: ndc(event))
    }

    /// Trackpad two-finger double-tap: toggle between fit and 2×.
    override func smartMagnify(with event: NSEvent) {
        guard let target = zoomTarget else { return super.smartMagnify(with: event) }
        if target.zoom > 1 { target.resetZoom() } else { target.zoom(by: 2, anchor: ndc(event)) }
    }

    override var mouseDownCanMoveWindow: Bool { true }

    // Let the first click on an inactive window start the drag straight away.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        guard let onRightClick else { return super.rightMouseDown(with: event) }
        onRightClick()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let onRightClick { return onRightClick() }
        if event.clickCount == 2, let zoomTarget { return zoomTarget.resetZoom() }
        window?.performDrag(with: event)
    }
}

/// Strips the window down to just the picture in dock mode (no title bar, traffic lights or
/// toolbar; floats above other windows; aspect-locked) and restores it afterwards.
/// (Window dragging is done by ScopeMTKView. Don't toggle `isMovableByWindowBackground` here:
/// SwiftUI's hosting view observes it and can crash if it changes during a graph update.)
struct WindowChrome: NSViewRepresentable {
    let docked: Bool
    /// Source size; in dock mode the window is locked to this aspect ratio (no letterboxing).
    let aspect: CGSize?

    func makeNSView(context: Context) -> ChromeView { ChromeView() }

    func updateNSView(_ view: ChromeView, context: Context) {
        view.aspect = aspect
        view.docked = docked
    }

    final class ChromeView: NSView {
        private struct Saved {
            let styleMask: NSWindow.StyleMask
            let titlebarTransparent: Bool
            let separator: NSTitlebarSeparatorStyle
            let level: NSWindow.Level
            let collectionBehavior: NSWindow.CollectionBehavior
        }

        private var saved: Saved?
        /// Full-window size from before docking, restored on undock.
        private var undockedSize: NSSize?

        var docked = false {
            didSet { if docked != oldValue { scheduleApply() } }
        }

        var aspect: CGSize? {
            didSet {
                guard aspect != oldValue, docked else { return }
                // New source while docked: reshape, keeping roughly the same window area.
                DispatchQueue.main.async { [weak self] in self?.fitToAspect(keepArea: true) }
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleApply()
        }

        /// Runs after SwiftUI's own window updates (e.g. hiding the toolbar), which would
        /// otherwise reset the title bar settings.
        private func scheduleApply() {
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            guard let window else { return }
            if saved == nil {
                saved = Saved(styleMask: window.styleMask,
                              titlebarTransparent: window.titlebarAppearsTransparent,
                              separator: window.titlebarSeparatorStyle,
                              level: window.level,
                              collectionBehavior: window.collectionBehavior)
            }
            guard let saved else { return }
            if docked {
                window.styleMask.insert(.fullSizeContentView)
                window.titlebarAppearsTransparent = true
                window.titlebarSeparatorStyle = .none
                // Stay above other apps' windows, on every Space, including over full-screen apps.
                window.level = .floating
                window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
                if undockedSize == nil { undockedSize = window.frame.size }
                fitToAspect(keepArea: false)
            } else {
                window.styleMask = saved.styleMask
                window.titlebarAppearsTransparent = saved.titlebarTransparent
                window.titlebarSeparatorStyle = saved.separator
                window.level = saved.level
                window.collectionBehavior = saved.collectionBehavior
                window.contentResizeIncrements = NSSize(width: 1, height: 1) // clears the aspect lock
                if let size = undockedSize {
                    undockedSize = nil
                    setFrameSize(size, of: window)
                }
            }
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = docked
            }
        }

        /// Locks the window to the source's aspect ratio and reshapes it to match: on entering
        /// dock mode the picture is fitted inside the current window (trimming the bars); on a
        /// source change the window keeps about the same area.
        private func fitToAspect(keepArea: Bool) {
            guard let window, docked, let a = aspect, a.width > 0, a.height > 0 else { return }
            window.contentAspectRatio = a
            let content = window.contentRect(forFrameRect: window.frame).size
            var size: NSSize
            if keepArea {
                let w = (content.width * content.height * a.width / a.height).squareRoot()
                size = NSSize(width: w, height: w * a.height / a.width)
            } else {
                let k = min(content.width / a.width, content.height / a.height)
                size = NSSize(width: a.width * k, height: a.height * k)
            }
            if let visible = window.screen?.visibleFrame.size {
                let k = min(1, visible.width / size.width, visible.height / size.height)
                size = NSSize(width: size.width * k, height: size.height * k)
            }
            setFrameSize(window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size, of: window)
        }

        /// Resizes keeping the top-left corner fixed, nudged back onto the screen if needed.
        private func setFrameSize(_ size: NSSize, of window: NSWindow) {
            var frame = window.frame
            frame.origin.y = frame.maxY - size.height
            frame.size = size
            if let visible = window.screen?.visibleFrame {
                frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width))
                frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height))
            }
            window.setFrame(frame, display: true, animate: false)
            // SwiftUI re-applies its own title bar styling after a resize; re-assert ours.
            DispatchQueue.main.async { [weak self] in self?.assertDockedTitlebar() }
        }

        private func assertDockedTitlebar() {
            guard let window, docked else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
        }
    }
}

// MARK: - Keyboard shortcuts guide

struct ShortcutsGuide: View {
    let dismiss: () -> Void

    static let rows: [(keys: String, action: String)] = [
        ("1", "False Color"),
        ("2", "Skintone"),
        ("3", "Tint"),
        ("4", "Neutrals"),
        ("↑  ↓", "Previous / next false color preset (False Color mode)"),
        ("Drag picture", "Move the window"),
        ("Scroll / pinch", "Zoom toward the pointer (mouse wheel, trackpad pinch, or ⌘ + two-finger scroll)"),
        ("Two-finger scroll", "Pan around when zoomed in"),
        ("0 · double-click", "Fit the whole picture (reset zoom)"),
        ("R", "Select the capture region: drag on the screen overlay, ↩ to apply, F for the whole screen, esc to cancel. Remembered per display."),
        ("Right-click", "Toggle dock mode: picture only, floating above other windows, window locked to the picture's shape. Right-click again to restore the full window. Control-click works too."),
        ("?", "Show / hide this guide"),
        ("Q", "Quit"),
        ("esc", "Close this guide"),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: dismiss)
            VStack(alignment: .leading, spacing: 10) {
                Text("Keyboard Shortcuts").font(.headline)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
                    ForEach(Self.rows, id: \.keys) { row in
                        GridRow {
                            Text(row.keys)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                                .gridColumnAlignment(.trailing)
                            Text(row.action)
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(16)
        }
    }
}

// MARK: - Twin Peaks

struct TwinPeaksPanel: View {
    let renderer: TwinPeaksRenderer
    let frames: FrameSource

    var body: some View {
        VStack(spacing: 0) {
            Text("TWIN PEAKS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            MetalScopeView(delegate: renderer, frames: frames) { view in
                view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                renderer.view = view
            }
            .overlay { GeometryReader { geo in labels(in: geo.size) } }
            .aspectRatio(0.8, contentMode: .fit)
            .padding(12)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func labels(in size: CGSize) -> some View {
        let items: [(String, Color, Float, Float)] = [
            ("G", .green, -1, 1), ("B", .blue, 1, 1),
            ("G", .green, -1, -1), ("R", .red, 1, -1),
        ]
        return ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            let (u, v) = TwinPeaksGeometry.uv(x: item.2, y: item.3)
            Text(item.0)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(item.1.opacity(0.9))
                .position(x: CGFloat(u) * size.width + (item.2 < 0 ? -2 : 2),
                          y: CGFloat(v) * size.height + (item.3 > 0 ? -12 : 12))
        }
    }
}

// MARK: - Legends

/// Horizontal 0–100% key showing which ranges map to which color.
struct FalseColorLegend: View {
    let preset: FalseColorPreset

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let barHeight = geo.size.height * 0.55
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
                    .frame(height: barHeight)
                ForEach(Array(preset.bands.enumerated()), id: \.offset) { _, band in
                    let x0 = CGFloat(band.lower) / 100 * w
                    let x1 = CGFloat(min(band.upper, 100)) / 100 * w
                    bandFill(band)
                        .frame(width: max(1, x1 - x0), height: barHeight)
                        .offset(x: x0)
                        .help("\(band.label): \(format(band.lower))–\(format(min(band.upper, 100)))%")
                }
                ForEach(Array(stride(from: 0, through: 100, by: 10)), id: \.self) { pct in
                    Text("\(pct)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .position(x: min(max(CGFloat(pct) / 100 * w, 8), w - 10), y: barHeight + 8)
                }
                if preset.channel != .luma {
                    Text(preset.channel.axisLabel)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .position(x: w - 12, y: barHeight + 8)
                        .offset(x: -24)
                }
            }
        }
    }

    @ViewBuilder
    private func bandFill(_ band: FalseColorPreset.Band) -> some View {
        let c0 = Color(rgb: FalseColorPreset.rgb(hex: band.color))
        if let end = band.endColor {
            LinearGradient(colors: [c0, Color(rgb: FalseColorPreset.rgb(hex: end))], startPoint: .leading, endPoint: .trailing)
        } else {
            Rectangle().fill(c0)
        }
    }

    private func format(_ v: Float) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}

struct SkintoneLegend: View {
    let settings: ScopeSettings

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                LinearGradient(colors: [Color(red: 0.15, green: 0.95, blue: 0.15),
                                        Color(red: 1, green: 0.92, blue: 0),
                                        Color(red: 1, green: 0.12, blue: 0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 18)
                HStack {
                    Text("On skin line")
                    Spacer()
                    Text("±\(Int(settings.skinTolerance / 2))°")
                    Spacer()
                    Text("±\(Int(settings.skinTolerance))°")
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            Text(settings.skintoneMode == .ycbcr
                 ? "YCbCr · skin line \(Int(settings.skintoneMode.centerDegrees))°"
                 : "HSL · hue \(Int(settings.skintoneMode.centerDegrees))°")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

struct ChannelClippingLegend: View {
    private let items: [(String, Color)] = [
        ("R", .red), ("G", .green), ("B", .blue), ("R+G", .yellow), ("All", .white),
        ("R=0", .cyan), ("G=0", Color(red: 1, green: 0, blue: 1)), ("B=0", .yellow), ("All=0", Color(red: 0.15, green: 0.35, blue: 1)),
    ]

    var body: some View {
        HStack(spacing: 10) {
            Text("Highlights").foregroundStyle(.secondary)
            ForEach(items.prefix(5), id: \.0) { swatch($0.0, $0.1) }
            Divider().frame(height: 16)
            Text("Shadows").foregroundStyle(.secondary)
            ForEach(items.suffix(4), id: \.0) { swatch($0.0, $0.1) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, design: .monospaced))
    }

    private func swatch(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 12, height: 12)
            Text(label)
        }
    }
}

/// Diverging key (green↔magenta or blue↔yellow) plus the GPU-measured average cast.
struct WhiteBalanceLegend: View {
    let settings: ScopeSettings
    let stats: WhiteBalanceStats?

    private var isTint: Bool { settings.imageMode == .tint }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                LinearGradient(colors: isTint
                               ? [Color(red: 0.1, green: 0.95, blue: 0.25), .gray, Color(red: 1, green: 0.15, blue: 0.85)]
                               : [Color(red: 0.15, green: 0.45, blue: 1), .gray, Color(red: 1, green: 0.85, blue: 0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 18)
                HStack {
                    Text(isTint ? "Green −\(Int(settings.wbRange))" : "Blue −\(Int(settings.wbRange))")
                    Spacer()
                    Text(isTint ? "a* 0" : "b* 0")
                    Spacer()
                    Text(isTint ? "+\(Int(settings.wbRange)) Magenta" : "+\(Int(settings.wbRange)) Yellow")
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            }
            readout.fixedSize()
        }
    }

    @ViewBuilder
    private var readout: some View {
        if let s = stats, s.sampleCount > 0 {
            // Neutrals are the meaningful reference for white balance; fall back to all pixels.
            let useNeutral = (!isTint || settings.tintNeutralsOnly) && s.neutralFraction > 0.001
            let a = useNeutral ? s.neutralMeanA : s.meanA
            let b = useNeutral ? s.neutralMeanB : s.meanB
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    castText(a, neg: "green", pos: "magenta", axis: "a*", emphasized: isTint)
                    castText(b, neg: "blue", pos: "yellow", axis: "b*", emphasized: !isTint)
                }
                Text(useNeutral ? "avg of neutrals · \(Int((s.neutralFraction * 100).rounded()))% of image"
                                : "avg of all pixels")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11, design: .monospaced))
        } else {
            Text("No signal").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func castText(_ v: Float, neg: String, pos: String, axis: String, emphasized: Bool) -> some View {
        let word = abs(v) < 0.5 ? "neutral" : (v < 0 ? neg : pos)
        return Text("\(axis) \(String(format: "%+.1f", v)) \(word)")
            .fontWeight(emphasized ? .semibold : .regular)
            .foregroundStyle(emphasized ? .primary : .secondary)
    }
}

extension Color {
    init(rgb: SIMD3<Float>) {
        self.init(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }
}
