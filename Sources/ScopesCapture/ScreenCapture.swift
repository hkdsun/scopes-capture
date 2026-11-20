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

    private var stream: SCStream?
    private let output: StreamOutput
    private let frameQueue = DispatchQueue(label: "scopes.capture.frames", qos: .userInteractive)
    private var ownApps: [SCRunningApplication] = []

    init(frames: FrameSource) {
        output = StreamOutput(frames: frames)
        output.onStop = { [weak self] error in
            Task { @MainActor in
                self?.stream = nil
                self?.activeSourceName = nil
                self?.lastError = error.localizedDescription
            }
        }
    }

    func refreshSources() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let myBundle = Bundle.main.bundleIdentifier
            let myPID = ProcessInfo.processInfo.processIdentifier
            ownApps = content.applications.filter { $0.processID == myPID || ($0.bundleIdentifier == myBundle && myBundle != nil) }
            displays = content.displays
            windows = content.windows
                .filter { w in
                    w.windowLayer == 0
                        && w.frame.width > 64 && w.frame.height > 64
                        && w.owningApplication?.processID != myPID
                        && !(w.title ?? "").isEmpty
                }
                .sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }
            lastError = nil
        } catch {
            lastError = "Can't list screen content: \(error.localizedDescription). Grant Screen Recording permission in System Settings › Privacy & Security."
        }
    }

    func capture(display: SCDisplay) async {
        // Exclude our own windows so the scope never analyzes itself.
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        await start(filter: filter, name: "Display \(display.displayID) (\(display.width)×\(display.height))")
    }

    func capture(window: SCWindow) async {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        await start(filter: filter, name: Self.title(for: window))
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        activeSourceName = nil
    }

    private func start(filter: SCContentFilter, name: String) async {
        await stop()

        let scale = CGFloat(filter.pointPixelScale)
        let rect = filter.contentRect
        let config = SCStreamConfiguration()
        config.width = max(2, Int(rect.width * scale))
        config.height = max(2, Int(rect.height * scale))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 5
        config.showsCursor = false
        config.capturesAudio = false

        do {
            let stream = SCStream(filter: filter, configuration: config, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: frameQueue)
            try await stream.startCapture()
            self.stream = stream
            activeSourceName = name
            lastError = nil
        } catch {
            lastError = "Capture failed: \(error.localizedDescription)"
        }
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
