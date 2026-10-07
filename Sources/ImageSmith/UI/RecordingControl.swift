import AppKit

/// A persistent stop button so a recording is obvious even with the menu closed.
@MainActor
final class RecordingControl: NSWindowController {
    private var timer: Timer?
    private let started = Date()
    private let elapsed = NSTextField(labelWithString: "00:00")
    private let buttonTarget: BlockTarget

    init(onStop: @escaping () -> Void) {
        buttonTarget = BlockTarget(onStop)
        let screen = ScreenGeometry.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main!
        let frame = NSRect(x: screen.visibleFrame.maxX - 186, y: screen.visibleFrame.maxY - 62,
                           width: 170, height: 46)
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = NSColor.windowBackgroundColor
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 9
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        let dot = NSImageView(image: NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")!)
        dot.contentTintColor = .systemRed
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 18).isActive = true
        elapsed.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let stop = NSButton(title: "Stop", target: nil, action: nil)
        stop.bezelStyle = .rounded
        stop.target = buttonTarget
        stop.action = #selector(BlockTarget.invoke)
        row.addArrangedSubview(dot)
        row.addArrangedSubview(elapsed)
        row.addArrangedSubview(stop)
        window.contentView = row
        window.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateElapsed() }
        }
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func close() {
        timer?.invalidate()
        timer = nil
        super.close()
    }

    private func updateElapsed() {
        let seconds = Int(Date().timeIntervalSince(started))
        elapsed.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private final class BlockTarget: NSObject {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func invoke() { block() }
}
