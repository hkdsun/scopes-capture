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
    var showTwinPeaks = true
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
        frames.onSizeChange = { [weak self] size in self?.sourceSize = size }
        imageScope.onWhiteBalanceStats = { [weak self] stats in
            guard let self, Date().timeIntervalSince(self.lastStatsUpdate) > 0.12 || self.wbStats == nil else { return }
            self.lastStatsUpdate = Date()
            self.wbStats = stats
        }
        userPresets = Self.loadUserPresets()
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
