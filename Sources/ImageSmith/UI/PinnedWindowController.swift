import AppKit

/// Borderless windows refuse key status by default, so a pin could never
/// receive Esc and stayed stuck on screen.
private final class PinnedWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// A floating, always-on-top copy of a capture — useful for keeping a reference
/// visible while you type a prompt somewhere else.
final class PinnedWindowController: NSWindowController {
    private static var pinned: [PinnedWindowController] = []

    static func pin(image: NSImage) {
        let c = PinnedWindowController(image: image)
        pinned.append(c)
        c.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        c.window?.makeKeyAndOrderFront(nil)
    }

    static func closeAll() {
        pinned.forEach { $0.close() }
    }

    /// Drop the controller with its window, or every closed pin keeps its
    /// full-resolution image alive until "Close All".
    override func close() {
        super.close()
        Self.pinned.removeAll { $0 === self }
    }

    private let imageView = NSImageView()

    init(image: NSImage) {
        let maxSide: CGFloat = 640
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let window = PinnedWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless, .resizable],
                              backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        super.init(window: window)

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(origin: .zero, size: size)
        imageView.autoresizingMask = [.width, .height]
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true

        let container = PinnedContainerView(frame: imageView.frame)
        container.onClose = { [weak self] in self?.close() }
        container.onDoubleClick = { [weak self] in
            guard let self, let image = self.imageView.image else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            if let png = ImageUtilities.pngData(from: image) { pb.setData(png, forType: .png) }
        }
        container.addSubview(imageView)
        container.addCloseButton()
        container.autoresizingMask = [.width, .height]
        window.contentView = container
        window.initialFirstResponder = container
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }
}

private final class PinnedContainerView: NSView {
    var onClose: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private let closeButton = NSButton()
    private var trackingArea: NSTrackingArea?

    /// A close control that appears on hover, so a pin can be dismissed without
    /// knowing about Esc or the context menu.
    func addCloseButton() {
        let image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular)
                .applying(.init(paletteColors: [.white, NSColor.black.withAlphaComponent(0.6)])))
        closeButton.image = image
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closeWindow)
        closeButton.toolTip = "Close (esc)"
        closeButton.frame = NSRect(x: 6, y: bounds.height - 28, width: 22, height: 22)
        closeButton.autoresizingMask = [.maxXMargin, .minYMargin]
        closeButton.isHidden = true
        addSubview(closeButton)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { closeButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { closeButton.isHidden = true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() } else { super.keyDown(with: event) }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy Image", action: #selector(copyImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Close", action: #selector(closeWindow), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func copyImage() { onDoubleClick?() }
    @objc private func closeWindow() { onClose?() }
    override var acceptsFirstResponder: Bool { true }
}
