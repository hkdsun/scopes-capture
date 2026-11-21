import AppKit
import CoreMedia
import Foundation
import Observation
import ScreenCaptureKit

/// Wraps ScreenCaptureKit: lists capturable displays/windows and streams BGRA frames
/// straight into the renderer (no CPU copies).
@Observable
@MainActor
final class ScreenCaptureController {
    private(set) var displays: [SCDisplay] = []
    private(set) var windows: [SCWindow] = []
    private(set) var activeSourceName: String?
    var lastError: String?
    /// Set when the display/window list can't be read (usually missing permission).
    private(set) var sourcesError: String?

    private var stream: SCStream?
    private let output: StreamOutput
    private let frameQueue = DispatchQueue(label: "scopes.capture.frames", qos: .userInteractive)
    private var ownApps: [SCRunningApplication] = []

    init(frames: FrameSource) {
        output = StreamOutput(frames: frames)
        output.onStop = { [weak self] error in
            Task { @MainActor in
                self?.stream = nil
                self?.activeFilter = nil
                self?.activeDisplay = nil
                self?.activeWindow = nil
                self?.activeSourceName = nil
                self?.lastError = error.localizedDescription
            }
        }
    }

    /// Keeps the display/window list current for as long as the calling task runs: refreshes
    /// immediately, whenever the app becomes active or another app launches/quits, and every
    /// few seconds while the app is frontmost.
    func keepSourcesFresh(interval: Duration = .seconds(3)) async {
        let center = NSWorkspace.shared.notificationCenter
        let events = [
            NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification),
            center.notifications(named: NSWorkspace.didLaunchApplicationNotification),
            center.notifications(named: NSWorkspace.didTerminateApplicationNotification),
        ]
        await refreshSources()
        await withTaskGroup(of: Void.self) { group in
            for stream in events {
                group.addTask { @MainActor [weak self] in
                    for await _ in stream { await self?.refreshSources() }
                }
            }
            group.addTask { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    if NSApp.isActive { await self?.refreshSources() }
                }
            }
        }
    }

    func refreshSources() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let myBundle = Bundle.main.bundleIdentifier
            let myPID = ProcessInfo.processInfo.processIdentifier
            ownApps = content.applications.filter { $0.processID == myPID || ($0.bundleIdentifier == myBundle && myBundle != nil) }
            let newWindows = content.windows
                .filter { w in
                    w.windowLayer == 0
                        && w.frame.width > 64 && w.frame.height > 64
                        && w.owningApplication?.processID != myPID
                        && !(w.title ?? "").isEmpty
                }
                .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
            // Only publish real changes so the menu isn't rebuilt on every poll.
            if content.displays.map(Self.key) != displays.map(Self.key) { displays = content.displays }
            if newWindows.map(Self.key) != windows.map(Self.key) { windows = newWindows }
            sourcesError = nil
        } catch {
            sourcesError = "Can't list screen content: \(error.localizedDescription). Grant Screen Recording permission in System Settings › Privacy & Security."
        }
    }

    /// Default source at launch: the whole main display (the one with the menu bar).
    func captureMainDisplay() async {
        guard stream == nil else { return }
        if displays.isEmpty { await refreshSources() }
        let main = CGMainDisplayID()
        guard let display = displays.first(where: { $0.displayID == main }) ?? displays.first else { return }
        await capture(display: display)
    }

    func capture(display: SCDisplay) async {
        // Exclude our own windows so the scope never analyzes itself (this also keeps the
        // region-selection overlay out of the picture).
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        await start(filter: filter, display: display, window: nil)
    }

    func capture(window: SCWindow) async {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        await start(filter: filter, display: nil, window: window)
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        activeFilter = nil
        activeDisplay = nil
        activeWindow = nil
        activeSourceName = nil
    }

    // MARK: - Capture region (display capture only)

    /// Display being captured, if the source is a display.
    private(set) var activeDisplay: SCDisplay?
    /// Window being captured, if the source is a window.
    private(set) var activeWindow: SCWindow?
    private var activeFilter: SCContentFilter?

    /// Saved region for a display, in the display's points with a top-left origin
    /// (ScreenCaptureKit's `sourceRect` space). nil = whole display.
    func region(for displayID: CGDirectDisplayID) -> CGRect? {
        guard let a = UserDefaults.standard.array(forKey: Self.regionKey(displayID)) as? [Double], a.count == 4 else { return nil }
        let r = CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        return r.width >= 8 && r.height >= 8 ? r : nil
    }

    /// Sets (or clears) the capture region for `display` and remembers it across launches.
    /// Updates the running stream in place when that display is already being captured.
    func setRegion(_ region: CGRect?, for display: SCDisplay) async {
        let key = Self.regionKey(display.displayID)
        if let r = region?.integral {
            UserDefaults.standard.set([r.minX, r.minY, r.width, r.height].map(Double.init), forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if let stream, let filter = activeFilter, activeDisplay?.displayID == display.displayID {
            do {
                try await stream.updateConfiguration(makeConfiguration(filter: filter, display: display))
                activeSourceName = Self.sourceName(display: display, region: self.region(for: display.displayID))
            } catch {
                lastError = "Couldn't change region: \(error.localizedDescription)"
            }
        } else {
            await capture(display: display)
        }
    }

    private static func regionKey(_ id: CGDirectDisplayID) -> String { "captureRegion.\(id)" }

    private static func sourceName(display: SCDisplay, region: CGRect?) -> String {
        guard let r = region else { return name(for: display) }
        return "\(name(for: display)) · region \(Int(r.width))×\(Int(r.height)) pt"
    }

    private func makeConfiguration(filter: SCContentFilter, display: SCDisplay?) -> SCStreamConfiguration {
        let scale = CGFloat(filter.pointPixelScale)
        let full = filter.contentRect
        var size = full.size
        let config = SCStreamConfiguration()
        if let display, let region = region(for: display.displayID) {
            // Keep the region inside the display (its resolution may have changed since).
            let bounds = CGRect(origin: .zero, size: full.size)
            let r = region.intersection(bounds)
            if r.width >= 8, r.height >= 8 {
                config.sourceRect = r
                size = r.size
            }
        }
        config.width = max(2, Int(size.width * scale))
        config.height = max(2, Int(size.height * scale))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 5
        config.showsCursor = false
        config.capturesAudio = false
        return config
    }

    private func start(filter: SCContentFilter, display: SCDisplay?, window: SCWindow?) async {
        await stop()
        do {
            let stream = SCStream(filter: filter, configuration: makeConfiguration(filter: filter, display: display),
                                  delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: frameQueue)
            try await stream.startCapture()
            self.stream = stream
            activeFilter = filter
            activeDisplay = display
            activeWindow = window
            if let display {
                activeSourceName = Self.sourceName(display: display, region: region(for: display.displayID))
            } else if let window {
                activeSourceName = Self.title(for: window)
            }
            lastError = nil
        } catch {
            lastError = "Capture failed: \(error.localizedDescription)"
        }
    }

    private static func key(_ d: SCDisplay) -> String { "\(d.displayID):\(d.width)x\(d.height)" }
    private static func key(_ w: SCWindow) -> String { "\(w.windowID):\(title(for: w))" }

    /// Human-readable display name, e.g. "Built-in Retina Display (1512×982)".
    static func name(for display: SCDisplay) -> String {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }
        let label = screen?.localizedName ?? "Display \(display.displayID)"
        return "\(label) (\(display.width)×\(display.height))"
    }

    static func title(for window: SCWindow) -> String {
        let app = window.owningApplication?.applicationName ?? "Unknown"
        let title = window.title ?? ""
        return title.isEmpty ? app : "\(app) — \(title)"
    }
}

private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let frames: FrameSource
    var onStop: ((Error) -> Void)?

    init(frames: FrameSource) {
        self.frames = frames
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        frames.setPixelBuffer(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}
