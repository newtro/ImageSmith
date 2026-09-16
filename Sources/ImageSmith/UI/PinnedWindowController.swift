import AppKit

/// A floating, always-on-top copy of a capture — useful for keeping a reference
/// visible while you type a prompt somewhere else.
final class PinnedWindowController: NSWindowController {
    private static var pinned: [PinnedWindowController] = []

    static func pin(image: NSImage) {
        let c = PinnedWindowController(image: image)
        pinned.append(c)
        c.showWindow(nil)
    }

    static func closeAll() {
        pinned.forEach { $0.close() }
        pinned.removeAll()
    }

    private let imageView = NSImageView()

    init(image: NSImage) {
        let maxSide: CGFloat = 640
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
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
        container.autoresizingMask = [.width, .height]
        window.contentView = container
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }
}

private final class PinnedContainerView: NSView {
    var onClose: (() -> Void)?
    var onDoubleClick: (() -> Void)?

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
