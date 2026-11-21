import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

@Observable
@MainActor
final class AppModel {
    let gpu: GPUContext
    let frames: FrameSource
    let imageScope: ImageScopeRenderer
    let twinPeaks: TwinPeaksRenderer
    let capture: ScreenCaptureController

    var settings = ScopeSettings() {
        didSet {
            if !settings.imageMode.isWhiteBalance { wbStats = nil }
            imageScope.settings = settings
            twinPeaks.legalRange = settings.legalRange
        }
    }
    var showTwinPeaks = false
    /// Picture-only window: no toolbar, legend, status bar or title bar. Toggled by right-click.
    var dockMode = false
    var showShortcuts = false
    /// Short-lived label shown after a keyboard change of mode/preset.
    private(set) var toast: String?
    private var toastTask: Task<Void, Never>?
    private var keyMonitor: Any?
    /// Latest white balance measurement (Tint/Neutrals modes), refreshed ~8×/s.
    private(set) var wbStats: WhiteBalanceStats?
    private var lastStatsUpdate = Date.distantPast
    private(set) var userPresets: [FalseColorPreset] = []
    private(set) var sourceSize: CGSize?
    private(set) var imageName: String?
    var message: String?

    init() {
        do {
            gpu = try GPUContext()
            frames = FrameSource(gpu: gpu)
            imageScope = try ImageScopeRenderer(gpu: gpu, source: frames)
            twinPeaks = try TwinPeaksRenderer(gpu: gpu, source: frames)
        } catch {
            fatalError("Failed to initialize Metal: \(error.localizedDescription)")
        }
        capture = ScreenCaptureController(frames: frames)
        frames.onSizeChange = { [weak self] size in
            self?.sourceSize = size
            self?.imageScope.resetZoom(notify: false) // new source: start from the whole picture
        }
        imageScope.onZoomChange = { [weak self] zoom in
            self?.showToast(zoom <= 1 ? "Fit" : "Zoom \(Int((zoom * 100).rounded()))%")
        }
        imageScope.onWhiteBalanceStats = { [weak self] stats in
            guard let self, Date().timeIntervalSince(self.lastStatsUpdate) > 0.12 || self.wbStats == nil else { return }
            self.lastStatsUpdate = Date()
            self.wbStats = stats
        }
        userPresets = Self.loadUserPresets()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) == true ? nil : event }
        }
    }

    // MARK: - Keyboard shortcuts

    /// Returns true when the key was handled. Only acts on the main scope window, and never
    /// with ⌘/⌃/⌥ held, so menus, popovers and dialogs keep their usual keys.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window != nil, event.window === NSApp.mainWindow,
              !(event.window?.firstResponder is NSText),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }

        if showShortcuts, event.keyCode == 53 { // esc
            showShortcuts = false
            return true
        }
        switch event.keyCode {
        case 126: return stepPreset(by: -1) // ↑
        case 125: return stepPreset(by: 1)  // ↓
        default: break
        }
        switch event.characters {
        case "?":
            showShortcuts.toggle()
            return true
        case "q", "Q":
            NSApp.terminate(nil)
            return true
        case "1": selectMode(.falseColor); return true
        case "2": selectMode(.skintone); return true
        case "3": selectMode(.tint); return true
        case "4": selectMode(.neutrals); return true
        case "0": imageScope.resetZoom(); return true
        case "r", "R": editRegion(); return true
        default: return false
        }
    }

    /// Opens the on-screen overlay to pick which part of the display is captured.
    /// Uses the display being captured; for a window source, the display under that window
    /// (starting from the window's frame); otherwise the main display.
    func editRegion() {
        guard !RegionSelector.isActive else { return }
        Task {
            if capture.displays.isEmpty { await capture.refreshSources() }
            var display = capture.activeDisplay
            var initial = display.flatMap { capture.region(for: $0.displayID) }
            if display == nil, let w = capture.activeWindow {
                let center = CGPoint(x: w.frame.midX, y: w.frame.midY)
                if let d = capture.displays.first(where: { $0.frame.contains(center) }) {
                    display = d
                    let local = w.frame.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY)
                    initial = local.intersection(CGRect(x: 0, y: 0, width: d.frame.width, height: d.frame.height))
                }
            }
            if display == nil {
                display = capture.displays.first { $0.displayID == CGMainDisplayID() } ?? capture.displays.first
                initial = display.flatMap { capture.region(for: $0.displayID) }
            }
            guard let display,
                  let screen = NSScreen.screens.first(where: {
                      ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
                  }) else {
                showToast("No display available for region capture")
                return
            }
            RegionSelector.present(on: screen, initial: initial) { [weak self] region in
                guard let self else { return }
                self.imageName = nil
                Task { await self.capture.setRegion(region, for: display) }
            }
        }
    }

    var allPresets: [FalseColorPreset] { FalseColorPreset.builtIn + userPresets }

    private func selectMode(_ mode: ImageScopeMode) {
        settings.imageMode = mode
        showToast(mode == .falseColor ? "False Color · \(settings.preset.name)" : mode.rawValue)
    }

    private func stepPreset(by delta: Int) -> Bool {
        guard settings.imageMode == .falseColor else { return false }
        let presets = allPresets
        guard !presets.isEmpty else { return false }
        let i = presets.firstIndex(where: { $0.name == settings.preset.name }) ?? 0
        settings.preset = presets[(i + delta + presets.count) % presets.count]
        showToast(settings.preset.name)
        return true
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    var sourceDescription: String {
        capture.activeSourceName ?? imageName ?? "No source"
    }

    // MARK: - Sources

    func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadImage(url: url)
    }

    func loadImage(url: URL) {
        Task {
            await capture.stop()
            do {
                frames.setTexture(try gpu.loadImageTexture(url: url))
                imageName = url.lastPathComponent
                message = nil
            } catch {
                message = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    func startCapture(_ start: @escaping (ScreenCaptureController) async -> Void) {
        imageName = nil
        Task { await start(capture) }
    }

    // MARK: - False color presets

    static var presetsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScopesCapture/Presets", isDirectory: true)
    }

    private static func loadUserPresets() -> [FalseColorPreset] {
        let dir = presetsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(FalseColorPreset.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Imports a preset JSON file into the user presets folder and selects it.
    func loadPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var preset = try JSONDecoder().decode(FalseColorPreset.self, from: Data(contentsOf: url))
            if FalseColorPreset.builtIn.contains(where: { $0.name == preset.name }) {
                preset.name += " (custom)"
            }
            try savePresetToLibrary(preset)
            userPresets = Self.loadUserPresets()
            settings.preset = preset
            settings.imageMode = .falseColor
            message = nil
        } catch {
            message = "Couldn't load preset: \(error.localizedDescription)"
        }
    }

    /// Exports the current preset as JSON (a starting point for custom scales).
    func savePreset() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(settings.preset.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Self.encode(settings.preset).write(to: url)
            message = nil
        } catch {
            message = "Couldn't save preset: \(error.localizedDescription)"
        }
    }

    private func savePresetToLibrary(_ preset: FalseColorPreset) throws {
        let dir = Self.presetsDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = preset.name.replacingOccurrences(of: "/", with: "-")
        try Self.encode(preset).write(to: dir.appendingPathComponent("\(safe).json"))
    }

    private static func encode(_ preset: FalseColorPreset) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(preset)
    }
}
