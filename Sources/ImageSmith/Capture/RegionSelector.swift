import AppKit

/// Borderless windows refuse key status by default, which would swallow Space and
/// Return in the picker.
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Full-screen picker used for region capture, colour picking and "click a window".
/// It freezes the screen by displaying a screenshot taken before the overlay appears,
/// so the crop is instantaneous and the overlay can never appear in the result.
final class RegionSelector {
    enum Mode {
        case region        // returns a cropped image
        case colorPicker   // returns the colour under the cursor
    }

    struct Result {
        let image: CGImage?
        let rect: CGRect          // global Cocoa points
        let screen: NSScreen
        let color: NSColor?
    }

    static let shared = RegionSelector()
    private var windows: [NSWindow] = []
    private var completion: ((Result?) -> Void)?
    private var isActive = false
    private var monitor: Any?

    var windowFrames: [(CGRect, String)] = []   // CG space, for click-to-pick-window

    func begin(mode: Mode,
               backdrops: [(NSScreen, CGImage)],
               windowFrames: [(CGRect, String)] = [],
               completion: @escaping (Result?) -> Void) {
        guard !isActive else { return }
        isActive = true
        self.completion = completion
        self.windowFrames = windowFrames

        NSApp.activate(ignoringOtherApps: true)
        for (screen, image) in backdrops {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                                       backing: .buffered, defer: false)
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.acceptsMouseMovedEvents = true

            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.mode = mode
            view.backdrop = image
            view.screenRef = screen
            view.owner = self
            view.windowFrames = windowFrames
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            window.makeFirstResponder(view)
            windows.append(window)
        }
        windows.first?.makeKey()

        // A safety net: Esc anywhere cancels even if focus wanders.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.finish(nil); return nil }
            return event
        }
    }

    func finish(_ result: Result?) {
        guard isActive else { return }
        isActive = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        let c = completion
        completion = nil
        c?(result)
    }
}

private final class SelectionView: NSView {
    weak var owner: RegionSelector?
    var mode: RegionSelector.Mode = .region
    var backdrop: CGImage?
    var screenRef: NSScreen?
    var windowFrames: [(CGRect, String)] = []

    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var cursor: NSPoint = .zero
    private var hasDragged = false
    private var highlightedWindow: CGRect?
    private var trackingArea: NSTrackingArea?
    private var magnifierEnabled = true

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Seed the crosshair and loupe from where the pointer already is, rather
        // than leaving them parked at the origin until the first mouse move.
        guard let window else { return }
        cursor = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        if mode == .region { highlightedWindow = windowRectUnderCursor() }
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // This view is not flipped, so CGContext.draw already orients the image
        // correctly — an extra flip here would stand the screen on its head.
        if let backdrop {
            ctx.draw(backdrop, in: CGRect(origin: .zero, size: bounds.size))
        }

        let selection = currentSelection()
        NSColor.black.withAlphaComponent(0.42).setFill()
        if let selection {
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: selection).reversed)
            path.windingRule = .evenOdd
            path.fill()
        } else if let hl = highlightedWindow {
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: hl).reversed)
            path.windingRule = .evenOdd
            path.fill()
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: hl)
            outline.lineWidth = 2
            outline.stroke()
        } else {
            bounds.fill()
        }

        if let selection {
            NSColor.white.setStroke()
            let outline = NSBezierPath(rect: selection)
            outline.lineWidth = 1
            outline.stroke()
            drawSizeBadge(for: selection)
        } else {
            drawCrosshair()
            drawHint()
        }

        if magnifierEnabled { drawMagnifier() }
    }

    private func drawCrosshair() {
        NSColor.white.withAlphaComponent(0.6).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: cursor.x, y: 0)); path.line(to: NSPoint(x: cursor.x, y: bounds.height))
        path.move(to: NSPoint(x: 0, y: cursor.y)); path.line(to: NSPoint(x: bounds.width, y: cursor.y))
        path.lineWidth = 1
        path.stroke()
    }

    private func drawHint() {
        let text = mode == .colorPicker
            ? "Click to copy the colour   ·   esc to cancel"
            : "Drag to select   ·   click a window to grab it   ·   space toggles the loupe   ·   esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = NSRect(x: bounds.midX - size.width / 2 - 12,
                          y: bounds.height * 0.08,
                          width: size.width + 24, height: size.height + 12)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        (text as NSString).draw(at: NSPoint(x: rect.minX + 12, y: rect.minY + 6), withAttributes: attrs)
    }

    private func drawSizeBadge(for rect: NSRect) {
        let scale = screenRef?.backingScaleFactor ?? 1
        let label = "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded())) px" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = label.size(withAttributes: attrs)
        var origin = NSPoint(x: rect.minX, y: rect.maxY + 6)
        if origin.y + size.height + 8 > bounds.maxY { origin.y = rect.minY - size.height - 12 }
        let box = NSRect(x: origin.x, y: origin.y, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        label.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attrs)
    }

    /// Pixel loupe: 8× view of the backdrop around the cursor with a colour readout.
    private func drawMagnifier() {
        guard let backdrop, let screen = screenRef else { return }
        let scale = screen.backingScaleFactor
        let zoom: CGFloat = 8
        let side: CGFloat = 132
        let sampleSide = side / zoom

        let px = cursor.x * scale
        let py = (bounds.height - cursor.y) * scale
        let sampleRect = CGRect(x: px - sampleSide * scale / 2,
                                y: py - sampleSide * scale / 2,
                                width: sampleSide * scale, height: sampleSide * scale)
        guard let crop = backdrop.cropping(to: sampleRect.integral) else { return }

        var origin = NSPoint(x: cursor.x + 18, y: cursor.y - side - 18)
        if origin.x + side > bounds.maxX { origin.x = cursor.x - side - 18 }
        if origin.y < bounds.minY { origin.y = cursor.y + 18 }
        let frame = NSRect(x: origin.x, y: origin.y, width: side, height: side)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        let clip = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        clip.setClip()
        ctx.interpolationQuality = .none
        ctx.draw(crop, in: frame)

        // Pixel grid
        NSColor.white.withAlphaComponent(0.18).setStroke()
        let grid = NSBezierPath()
        var x = frame.minX
        while x < frame.maxX { grid.move(to: NSPoint(x: x, y: frame.minY)); grid.line(to: NSPoint(x: x, y: frame.maxY)); x += zoom }
        var y = frame.minY
        while y < frame.maxY { grid.move(to: NSPoint(x: frame.minX, y: y)); grid.line(to: NSPoint(x: frame.maxX, y: y)); y += zoom }
        grid.lineWidth = 0.5
        grid.stroke()

        NSColor.systemRed.setStroke()
        let center = NSBezierPath(rect: NSRect(x: frame.midX - zoom / 2, y: frame.midY - zoom / 2,
                                               width: zoom, height: zoom))
        center.lineWidth = 1.5
        center.stroke()
        ctx.restoreGState()

        NSColor.white.withAlphaComponent(0.8).setStroke()
        clip.lineWidth = 1
        clip.stroke()

        if let color = colorUnderCursor() {
            let hex = color.hexString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let label = hex as NSString
            let size = label.size(withAttributes: attrs)
            let box = NSRect(x: frame.minX, y: frame.minY - size.height - 8,
                             width: max(side, size.width + 16), height: size.height + 6)
            NSColor.black.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: box.minX + 5, y: box.minY + 5, width: 10, height: 10)).fill()
            label.draw(at: NSPoint(x: box.minX + 20, y: box.minY + 3), withAttributes: attrs)
        }
    }

    private func colorUnderCursor() -> NSColor? {
        guard let backdrop, let screen = screenRef else { return nil }
        let scale = screen.backingScaleFactor
        let x = Int(cursor.x * scale)
        let y = Int((bounds.height - cursor.y) * scale)
        guard x >= 0, y >= 0, x < backdrop.width, y < backdrop.height,
              let crop = backdrop.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))
        else { return nil }
        let rep = NSBitmapImageRep(cgImage: crop)
        return rep.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)
    }

    // MARK: Selection geometry

    private func currentSelection() -> NSRect? {
        guard let a = dragStart, let b = dragCurrent, hasDragged else { return nil }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y),
                      width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// The window under the cursor, expressed in this view's coordinates.
    private func windowRectUnderCursor() -> NSRect? {
        guard let screen = screenRef else { return nil }
        let globalCocoa = NSPoint(x: screen.frame.minX + cursor.x, y: screen.frame.minY + cursor.y)
        let cgPoint = ScreenGeometry.cgPoint(fromCocoa: globalCocoa)
        guard let match = windowFrames.first(where: { $0.0.contains(cgPoint) }) else { return nil }
        let cocoa = ScreenGeometry.cocoaRect(fromCG: match.0)
        return NSRect(x: cocoa.minX - screen.frame.minX, y: cocoa.minY - screen.frame.minY,
                      width: cocoa.width, height: cocoa.height)
            .intersection(bounds)
    }

    // MARK: Events

    override func mouseMoved(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        if mode == .region && dragStart == nil {
            highlightedWindow = windowRectUnderCursor()
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        if mode == .colorPicker {
            owner?.finish(.init(image: nil, rect: .zero, screen: screenRef ?? NSScreen.main!,
                                color: colorUnderCursor()))
            return
        }
        dragStart = cursor
        dragCurrent = cursor
        hasDragged = false
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        dragCurrent = cursor
        if let start = dragStart, hypot(cursor.x - start.x, cursor.y - start.y) > 3 { hasDragged = true }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        cursor = convert(event.locationInWindow, from: nil)
        if let rect = currentSelection(), rect.width > 2, rect.height > 2 {
            deliver(rect)
        } else if let windowRect = windowRectUnderCursor() {
            deliver(windowRect)
        } else {
            dragStart = nil; dragCurrent = nil; hasDragged = false
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: owner?.finish(nil)
        case 49: magnifierEnabled.toggle(); needsDisplay = true   // space
        case 36, 76:
            if let rect = currentSelection() { deliver(rect) }
        default: super.keyDown(with: event)
        }
    }

    private func deliver(_ viewRect: NSRect) {
        guard let backdrop, let screen = screenRef else { owner?.finish(nil); return }
        let scale = screen.backingScaleFactor
        let pixelRect = CGRect(x: viewRect.minX * scale,
                               y: (bounds.height - viewRect.maxY) * scale,
                               width: viewRect.width * scale,
                               height: viewRect.height * scale)
        let cropped = ImageUtilities.crop(backdrop, toPixelRect: pixelRect)
        let globalRect = NSRect(x: screen.frame.minX + viewRect.minX,
                                y: screen.frame.minY + viewRect.minY,
                                width: viewRect.width, height: viewRect.height)
        owner?.finish(.init(image: cropped, rect: globalRect, screen: screen,
                            color: colorUnderCursor()))
    }
}
