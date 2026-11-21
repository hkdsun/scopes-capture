import AppKit

/// Full-screen overlay for picking the capture region on one display.
///
/// Drag to draw a new region, drag inside it to move it, drag a handle to resize.
/// Return applies, Esc cancels, F selects the whole screen. Rectangles are exchanged in the
/// display's points with a top-left origin (ScreenCaptureKit's `sourceRect` space).
@MainActor
final class RegionSelector {
    private static var active: RegionSelector?

    private let window: OverlayWindow
    private let onCommit: (CGRect?) -> Void

    static var isActive: Bool { active != nil }

    /// - Parameters:
    ///   - initial: current region (top-left origin points), or nil for the whole screen.
    ///   - onCommit: called with the chosen region, or nil for the whole screen. Not called on cancel.
    static func present(on screen: NSScreen, initial: CGRect?, onCommit: @escaping (CGRect?) -> Void) {
        active?.close()
        let selector = RegionSelector(screen: screen, initial: initial, onCommit: onCommit)
        active = selector
        NSApp.activate(ignoringOtherApps: true)
        selector.window.makeKeyAndOrderFront(nil)
    }

    private init(screen: NSScreen, initial: CGRect?, onCommit: @escaping (CGRect?) -> Void) {
        self.onCommit = onCommit
        window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let size = screen.frame.size
        // Top-left-origin display points -> bottom-left-origin view points.
        let viewRect = initial.map { CGRect(x: $0.minX, y: size.height - $0.maxY, width: $0.width, height: $0.height) }
            ?? CGRect(origin: .zero, size: size)
        let view = RegionEditorView(frame: CGRect(origin: .zero, size: size), rect: viewRect,
                                    pixelScale: screen.backingScaleFactor)
        window.contentView = view
        window.initialFirstResponder = view

        view.onFinish = { [weak self] result in
            guard let self else { return }
            switch result {
            case .cancel:
                break
            case .fullScreen:
                self.onCommit(nil)
            case .region(let r):
                let full = CGRect(origin: .zero, size: size)
                if r.insetBy(dx: -1, dy: -1).contains(full) {
                    self.onCommit(nil)
                } else {
                    self.onCommit(CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height).integral)
                }
            }
            self.close()
        }
    }

    private func close() {
        window.orderOut(nil)
        window.close()
        if RegionSelector.active === self { RegionSelector.active = nil }
    }
}

/// Borderless windows can't become key by default; this one must, to receive Return/Esc.
private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class RegionEditorView: NSView {
    enum Result { case region(CGRect), fullScreen, cancel }

    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2)
        static let bottom = Edges(rawValue: 4), top = Edges(rawValue: 8)
    }

    private enum Drag {
        case create(anchor: CGPoint)
        case move(start: CGPoint, original: CGRect)
        case resize(edges: Edges, start: CGPoint, original: CGRect)
    }

    var onFinish: ((Result) -> Void)?
    private var rect: CGRect
    private var drag: Drag?
    private let pixelScale: CGFloat
    private let handleSize: CGFloat = 9
    private let minSize: CGFloat = 16

    init(frame: CGRect, rect: CGRect, pixelScale: CGFloat) {
        self.rect = rect
        self.pixelScale = pixelScale
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Dim everything outside the region.
        let shade = NSBezierPath(rect: bounds)
        shade.append(NSBezierPath(rect: rect))
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        shade.fill()

        let border = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        border.lineWidth = 2
        NSColor.systemYellow.setStroke()
        border.stroke()

        for (_, handle) in handles() {
            NSColor.white.setFill()
            NSBezierPath(rect: handle).fill()
            NSColor.black.withAlphaComponent(0.6).setStroke()
            NSBezierPath(rect: handle).stroke()
        }

        // Size of the capture in pixels, next to the region's top-left corner.
        let size = "\(Int((rect.width * pixelScale).rounded()))×\(Int((rect.height * pixelScale).rounded())) px"
        let labelY = rect.maxY + 6 + 20 < bounds.maxY ? rect.maxY + 6 : rect.maxY - 26
        drawLabel(size, at: CGPoint(x: rect.minX, y: labelY), font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold))

        let help = "Drag to select  ·  drag inside to move  ·  drag handles to resize  ·  ↩ apply  ·  F whole screen  ·  esc cancel"
        let helpSize = (help as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)])
        drawLabel(help, at: CGPoint(x: bounds.midX - helpSize.width / 2 - 10, y: bounds.maxY - 80),
                  font: .systemFont(ofSize: 13, weight: .medium))
    }

    private func drawLabel(_ text: String, at origin: CGPoint, font: NSFont) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let box = CGRect(x: origin.x, y: origin.y, width: size.width + 20, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: CGPoint(x: box.minX + 10, y: box.minY + 4), withAttributes: attrs)
    }

    private func handles() -> [(Edges, CGRect)] {
        let r = rect, s = handleSize
        let points: [(Edges, CGPoint)] = [
            ([.left, .bottom], CGPoint(x: r.minX, y: r.minY)), ([.right, .bottom], CGPoint(x: r.maxX, y: r.minY)),
            ([.left, .top], CGPoint(x: r.minX, y: r.maxY)), ([.right, .top], CGPoint(x: r.maxX, y: r.maxY)),
            ([.left], CGPoint(x: r.minX, y: r.midY)), ([.right], CGPoint(x: r.maxX, y: r.midY)),
            ([.bottom], CGPoint(x: r.midX, y: r.minY)), ([.top], CGPoint(x: r.midX, y: r.maxY)),
        ]
        return points.map { ($0.0, CGRect(x: $0.1.x - s / 2, y: $0.1.y - s / 2, width: s, height: s)) }
    }

    // MARK: Mouse

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        addCursorRect(rect.insetBy(dx: handleSize, dy: handleSize), cursor: .openHand)
        for (edges, handle) in handles() {
            let cursor: NSCursor = edges == [.left] || edges == [.right] ? .resizeLeftRight
                : edges == [.top] || edges == [.bottom] ? .resizeUpDown : .crosshair
            addCursorRect(handle.insetBy(dx: -4, dy: -4), cursor: cursor)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let (edges, _) = handles().first(where: { $0.1.insetBy(dx: -5, dy: -5).contains(p) }) {
            drag = .resize(edges: edges, start: p, original: rect)
        } else if rect.contains(p) {
            drag = .move(start: p, original: rect)
            NSCursor.closedHand.set()
        } else {
            drag = .create(anchor: p)
            rect = CGRect(origin: p, size: .zero)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clamp(convert(event.locationInWindow, from: nil))
        switch drag {
        case .create(let anchor):
            rect = CGRect(x: min(anchor.x, p.x), y: min(anchor.y, p.y),
                          width: abs(p.x - anchor.x), height: abs(p.y - anchor.y))
        case .move(let start, let original):
            var r = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
            r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
            rect = r
        case .resize(let edges, let start, let original):
            var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
            let dx = p.x - start.x, dy = p.y - start.y
            if edges.contains(.left) { minX = min(original.minX + dx, maxX - minSize) }
            if edges.contains(.right) { maxX = max(original.maxX + dx, minX + minSize) }
            if edges.contains(.bottom) { minY = min(original.minY + dy, maxY - minSize) }
            if edges.contains(.top) { maxY = max(original.maxY + dy, minY + minSize) }
            rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(bounds)
        case nil:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .create = drag, rect.width < minSize || rect.height < minSize {
            // A click without a real drag: treat it as "whole screen" rather than a sliver.
            rect = bounds
        }
        drag = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onFinish?(.region(rect.integral)) // return / enter
        case 53: onFinish?(.cancel)                    // esc
        default:
            if event.charactersIgnoringModifiers?.lowercased() == "f" { onFinish?(.fullScreen) }
            else { super.keyDown(with: event) }
        }
    }
}
