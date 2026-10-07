import AppKit

/// The small preview that slides in after a capture. Click it to edit, drag it into
/// any app to drop the file, or dismiss it with the corner button.
final class ThumbnailOverlayController: NSWindowController {
    private static var current: ThumbnailOverlayController?

    private let capture: Capture
    private var dismissTimer: Timer?
    private let onEdit: (Capture) -> Void

    static func present(capture: Capture, onEdit: @escaping (Capture) -> Void) {
        current?.dismiss()
        let c = ThumbnailOverlayController(capture: capture, onEdit: onEdit)
        current = c
        c.showWindow(nil)
    }

    static func dismissCurrent() {
        current?.dismiss()
        current = nil
    }

    private init(capture: Capture, onEdit: @escaping (Capture) -> Void) {
        self.capture = capture
        self.onEdit = onEdit

        let maxSide: CGFloat = 220
        let image = capture.image
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = NSSize(width: max(90, image.size.width * scale),
                          height: max(60, image.size.height * scale))

        let screen = ScreenGeometry.screen(containing: NSEvent.mouseLocation)
            ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = NSRect(x: screen.visibleFrame.maxX - size.width - 24,
                           y: screen.visibleFrame.minY + 24,
                           width: size.width, height: size.height)

        let window = NSWindow(contentRect: frame, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        super.init(window: window)

        let view = ThumbnailView(frame: NSRect(origin: .zero, size: size))
        view.capture = capture
        view.onClick = { [weak self] in
            guard let self else { return }
            self.dismiss()
            self.onEdit(self.capture)
        }
        view.onClose = { [weak self] in self?.dismiss() }
        window.contentView = view
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 1
        }

        let seconds = SettingsStore.shared.prefs.thumbnailSeconds
        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        guard let window else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
            if ThumbnailOverlayController.current === self { ThumbnailOverlayController.current = nil }
        }
    }
}

private final class ThumbnailView: NSView, NSDraggingSource {
    var capture: Capture?
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    private var mouseInside = false
    private var dragOrigin: NSPoint?

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 3, dy: 3)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NSColor.white.setFill()
        path.fill()
        path.setClip()
        capture?.image.draw(in: rect.insetBy(dx: 3, dy: 3))
        if capture?.isRecording == true {
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 18, y: rect.midY - 18, width: 36, height: 36)).fill()
            let play = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play recording")
            play?.draw(in: NSRect(x: rect.midX - 7, y: rect.midY - 8, width: 16, height: 16))
        }

        NSColor(white: 0, alpha: 0.25).setStroke()
        let border = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        border.lineWidth = 1
        border.stroke()

        if mouseInside {
            NSColor.black.withAlphaComponent(0.45).setFill()
            let badge = NSRect(x: rect.maxX - 22, y: rect.maxY - 22, width: 18, height: 18)
            NSBezierPath(ovalIn: badge).fill()
            let x = "✕" as NSString
            x.draw(at: NSPoint(x: badge.minX + 4, y: badge.minY + 2),
                   withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold),
                                    .foregroundColor: NSColor.white])

            let hint = "Click to edit · drag to drop" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let size = hint.size(withAttributes: attrs)
            let box = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: size.height + 6)
            NSColor.black.withAlphaComponent(0.55).setFill()
            box.fill()
            hint.draw(at: NSPoint(x: box.midX - size.width / 2, y: box.minY + 3), withAttributes: attrs)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { mouseInside = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { mouseInside = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        dragOrigin = convert(event.locationInWindow, from: nil)
        let rect = bounds.insetBy(dx: 3, dy: 3)
        let closeBox = NSRect(x: rect.maxX - 24, y: rect.maxY - 24, width: 22, height: 22)
        if let p = dragOrigin, closeBox.contains(p) { onClose?() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let capture else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard hypot(p.x - origin.x, p.y - origin.y) > 6 else { return }
        dragOrigin = nil

        let url = capture.fileURL ?? writeTemporaryFile(for: capture)
        guard let url else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: capture.image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragOrigin != nil else { return }
        let rect = bounds.insetBy(dx: 3, dy: 3)
        let closeBox = NSRect(x: rect.maxX - 24, y: rect.maxY - 24, width: 22, height: 22)
        let p = convert(event.locationInWindow, from: nil)
        if !closeBox.contains(p) { onClick?() }
        dragOrigin = nil
    }

    private func writeTemporaryFile(for capture: Capture) -> URL? {
        guard let data = ImageUtilities.pngData(from: capture.image) else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageSmith-\(UUID().uuidString.prefix(8)).png")
        try? data.write(to: url)
        return url
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
