import AppKit

final class EditorWindow: NSWindow {
    weak var controller: EditorWindowController?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        if controller?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Centers the canvas when it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width {
            rect.origin.x = (doc.frame.width - rect.width) / 2
        }
        if rect.height > doc.frame.height {
            rect.origin.y = (doc.frame.height - rect.height) / 2
        }
        return rect
    }
}

final class EditorWindowController: NSWindowController {
    private(set) var capture: Capture
    private var canvas: CanvasView!
    private var scrollView: NSScrollView!
    private var statusLabel: NSTextField!
    private var toolButtons: [ToolKind: NSButton] = [:]
    private var colorButtons: [NSButton] = []
    private var widthSlider: NSSlider!
    private var fillToggle: NSButton!
    private var fontSizeSlider: NSSlider!
    private let editorUndoManager = UndoManager()

    var onClose: ((EditorWindowController) -> Void)?

    private static let palette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1), // red
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1), // orange
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1), // yellow
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), // green
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1), // blue
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1), // purple
        NSColor.white,
        NSColor.black
    ]

    private static let toolOrder: [ToolKind] = [
        .select, .arrow, .rectangle, .ellipse, .line, .pen, .highlighter,
        .text, .step, .blur, .pixelate, .redact, .spotlight, .crop
    ]

    init(capture: Capture) {
        self.capture = capture
        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        window.title = "ImageSmith — \(capture.sourceDescription)"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.controller = self
        window.delegate = self
        buildUI()
        sizeToFitImage()
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    // MARK: UI construction

    private func buildUI() {
        let prefs = SettingsStore.shared.prefs
        let content = NSView()

        canvas = CanvasView(image: capture.image)
        canvas.delegate = self
        canvas.currentColor = NSColor(hex: prefs.defaultColorHex) ?? .systemRed
        canvas.currentStrokeWidth = CGFloat(prefs.defaultStrokeWidth)
        canvas.currentFontSize = CGFloat(prefs.defaultFontSize)
        canvas.currentTool = .arrow

        scrollView = NSScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(white: 0.12, alpha: 1)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = buildToolbar()
        let statusBar = buildStatusBar()

        content.addSubview(toolbar)
        content.addSubview(scrollView)
        content.addSubview(statusBar)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            statusBar.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 28)
        ])

        window?.contentView = content
        updateStatus()
    }

    private func buildToolbar() -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.translatesAutoresizingMaskIntoConstraints = false

        let tools = NSStackView()
        tools.orientation = .horizontal
        tools.spacing = 2
        for tool in Self.toolOrder {
            let b = iconButton(symbol: tool.symbolName,
                               tooltip: "\(tool.title) (\(tool.shortcut))",
                               action: #selector(toolButtonTapped(_:)))
            b.setButtonType(.pushOnPushOff)
            b.tag = Self.toolOrder.firstIndex(of: tool) ?? 0
            toolButtons[tool] = b
            tools.addArrangedSubview(b)
        }

        let colors = NSStackView()
        colors.orientation = .horizontal
        colors.spacing = 3
        for (i, c) in Self.palette.enumerated() {
            let b = NSButton(frame: .zero)
            b.title = ""
            b.bezelStyle = .shadowlessSquare
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = c.cgColor
            b.layer?.cornerRadius = 9
            b.layer?.borderWidth = 2
            b.layer?.borderColor = NSColor.clear.cgColor
            b.tag = i
            b.target = self
            b.action = #selector(colorButtonTapped(_:))
            b.toolTip = "Colour \(i + 1)"
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 18).isActive = true
            b.heightAnchor.constraint(equalToConstant: 18).isActive = true
            colorButtons.append(b)
            colors.addArrangedSubview(b)
        }
        let customColor = iconButton(symbol: "eyedropper",
                                     tooltip: "Custom colour",
                                     action: #selector(chooseCustomColor))
        colors.addArrangedSubview(customColor)

        widthSlider = NSSlider(value: SettingsStore.shared.prefs.defaultStrokeWidth,
                               minValue: 1, maxValue: 24,
                               target: self, action: #selector(widthChanged(_:)))
        widthSlider.toolTip = "Stroke width ([ and ])"
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 80).isActive = true

        fontSizeSlider = NSSlider(value: SettingsStore.shared.prefs.defaultFontSize,
                                  minValue: 10, maxValue: 96,
                                  target: self, action: #selector(fontSizeChanged(_:)))
        fontSizeSlider.toolTip = "Text / badge size"
        fontSizeSlider.translatesAutoresizingMaskIntoConstraints = false
        fontSizeSlider.widthAnchor.constraint(equalToConstant: 70).isActive = true

        fillToggle = NSButton(checkboxWithTitle: "Fill", target: self, action: #selector(fillToggled(_:)))
        fillToggle.toolTip = "Fill shapes (F)"

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 2
        actions.addArrangedSubview(iconButton(symbol: "arrow.uturn.backward", tooltip: "Undo (⌘Z)", action: #selector(undoAction)))
        actions.addArrangedSubview(iconButton(symbol: "arrow.uturn.forward", tooltip: "Redo (⇧⌘Z)", action: #selector(redoAction)))
        actions.addArrangedSubview(iconButton(symbol: "trash", tooltip: "Clear all marks", action: #selector(clearAll)))
        actions.addArrangedSubview(iconButton(symbol: "text.viewfinder", tooltip: "Copy text via OCR (⇧⌘O)", action: #selector(runOCR)))
        actions.addArrangedSubview(iconButton(symbol: "pin", tooltip: "Pin on top (⌘P)", action: #selector(pinImage)))
        actions.addArrangedSubview(iconButton(symbol: "square.and.arrow.down", tooltip: "Save as… (⌘S)", action: #selector(saveAs)))
        actions.addArrangedSubview(iconButton(symbol: "curlybraces", tooltip: "Copy file path (⇧⌘C)", action: #selector(copyPath)))

        let copyButton = NSButton(title: "Copy & Close", target: self, action: #selector(copyAndClose))
        copyButton.bezelStyle = .rounded
        copyButton.toolTip = "Flatten, copy to the clipboard and close (↩)"

        let stack = NSStackView(views: [tools, separator(), colors, widthSlider, fillToggle,
                                        fontSizeSlider, separator(), actions,
                                        NSView(), copyButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor)
        ])
        refreshToolButtons()
        refreshColorButtons()
        return bar
    }

    private func buildStatusBar() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        let zoomOut = iconButton(symbol: "minus.magnifyingglass", tooltip: "Zoom out (⌘-)", action: #selector(zoomOut))
        let zoomFit = NSButton(title: "Fit", target: self, action: #selector(zoomToFit))
        zoomFit.bezelStyle = .inline
        let zoomIn = iconButton(symbol: "plus.magnifyingglass", tooltip: "Zoom in (⌘+)", action: #selector(zoomIn))
        let zoomStack = NSStackView(views: [zoomOut, zoomFit, zoomIn])
        zoomStack.spacing = 2
        zoomStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(zoomStack)

        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            zoomStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            zoomStack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        return view
    }

    private func iconButton(symbol: String, tooltip: String, action: Selector) -> NSButton {
        let b = NSButton()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip) {
            b.image = image
        } else {
            b.title = String(tooltip.prefix(2))   // never show a placeholder glyph
        }
        b.imageScaling = .scaleProportionallyDown
        b.bezelStyle = .texturedRounded
        b.setButtonType(.momentaryPushIn)
        b.toolTip = tooltip
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    private func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    private func sizeToFitImage() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let maxSize = screen.visibleFrame.insetBy(dx: 40, dy: 40).size
        let imageSize = capture.image.size
        let chrome = NSSize(width: 0, height: 78)
        var target = NSSize(width: min(imageSize.width, maxSize.width - chrome.width),
                            height: min(imageSize.height + chrome.height, maxSize.height))
        target.width = max(target.width, 820)
        target.height = max(target.height, 460)
        window.setContentSize(target)
        window.center()
        DispatchQueue.main.async { [weak self] in self?.zoomToFit() }
    }

    // MARK: Status

    private func updateStatus() {
        let px = capture.pixelSize
        var parts = ["\(Int(px.width))×\(Int(px.height)) px",
                     "\(canvas.annotations.count) mark\(canvas.annotations.count == 1 ? "" : "s")",
                     "zoom \(Int((canvas.zoom * 100).rounded()))%"]
        if let url = capture.fileURL { parts.append(url.lastPathComponent) }
        statusLabel.stringValue = parts.joined(separator: "   ·   ")
    }

    private func refreshToolButtons() {
        for (tool, button) in toolButtons {
            button.contentTintColor = tool == canvas.currentTool ? .controlAccentColor : nil
            button.state = tool == canvas.currentTool ? .on : .off
        }
    }

    private func refreshColorButtons() {
        for (i, b) in colorButtons.enumerated() {
            let selected = Self.palette[i].isApproximately(canvas.currentColor)
            b.layer?.borderColor = selected ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        }
    }

    // MARK: Actions

    @objc private func toolButtonTapped(_ sender: NSButton) {
        let tool = Self.toolOrder[sender.tag]
        canvas.currentTool = tool
        refreshToolButtons()
    }

    @objc private func colorButtonTapped(_ sender: NSButton) {
        canvas.currentColor = Self.palette[sender.tag]
        canvas.applyStyleToSelection()
        refreshColorButtons()
    }

    @objc private func chooseCustomColor() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(customColorChanged(_:)))
        panel.color = canvas.currentColor
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func customColorChanged(_ sender: NSColorPanel) {
        canvas.currentColor = sender.color
        canvas.applyStyleToSelection()
        refreshColorButtons()
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        canvas.currentStrokeWidth = CGFloat(sender.doubleValue)
        canvas.applyStyleToSelection()
    }

    @objc private func fontSizeChanged(_ sender: NSSlider) {
        canvas.currentFontSize = CGFloat(sender.doubleValue)
        canvas.applyStyleToSelection()
    }

    @objc private func fillToggled(_ sender: NSButton) {
        canvas.fillShapes = sender.state == .on
        canvas.applyStyleToSelection()
    }

    @objc private func undoAction() { editorUndoManager.undo(); canvas.needsDisplay = true; updateStatus() }
    @objc private func redoAction() { editorUndoManager.redo(); canvas.needsDisplay = true; updateStatus() }
    @objc private func clearAll() { canvas.clearAll() }

    @objc func zoomIn() { setZoom(canvas.zoom * 1.25) }
    @objc func zoomOut() { setZoom(canvas.zoom / 1.25) }

    @objc func zoomToFit() {
        let visible = scrollView.contentView.bounds.size
        guard visible.width > 1, visible.height > 1 else { return }
        let size = canvas.imageSize
        let z = min(1.0, min(visible.width / size.width, visible.height / size.height))
        setZoom(z)
    }

    private func setZoom(_ z: CGFloat) {
        canvas.zoom = max(0.1, min(8, z))
        updateStatus()
    }

    @objc func copyAndClose() {
        canvas.commitTextEditing()
        flattenIntoCapture()
        if SettingsStore.shared.prefs.afterCapture != .clipboardOnly || capture.fileURL != nil {
            CaptureStore.shared.writeToDisk(capture)
        }
        CaptureStore.shared.copyToPasteboard(capture)
        Notifier.flashStatusItem()
        close()
    }

    @objc func saveAs() {
        canvas.commitTextEditing()
        flattenIntoCapture()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = capture.fileURL?.lastPathComponent
            ?? "\(CaptureStore.shared.expand(template: SettingsStore.shared.prefs.fileNameTemplate, date: capture.date)).png"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if let data = ImageUtilities.pngData(from: self.capture.image) {
                try? data.write(to: url)
                self.capture.fileURL = url
                self.updateStatus()
            }
        }
    }

    @objc func copyPath() {
        flattenIntoCapture()
        if capture.fileURL == nil { CaptureStore.shared.writeToDisk(capture) }
        CaptureStore.shared.copyPath(capture, markdown: false)
        updateStatus()
    }

    @objc func copyMarkdownPath() {
        flattenIntoCapture()
        if capture.fileURL == nil { CaptureStore.shared.writeToDisk(capture) }
        CaptureStore.shared.copyPath(capture, markdown: true)
        updateStatus()
    }

    @objc func runOCR() {
        flattenIntoCapture()
        let image = capture.image
        Task {
            let text = await OCRService.recognizeText(in: image)
            await MainActor.run {
                guard !text.isEmpty else { Notifier.show(title: "No text found", body: nil); return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                Notifier.show(title: "Text copied", body: "\(text.count) characters")
            }
        }
    }

    @objc func pinImage() {
        flattenIntoCapture()
        PinnedWindowController.pin(image: capture.image)
    }

    private func flattenIntoCapture() {
        capture.image = AnnotationRenderer.flatten(base: canvas.baseImage,
                                                   annotations: canvas.annotations,
                                                   obscure: canvas.obscure)
    }

    // MARK: Keyboard

    func handleKey(_ event: NSEvent) -> Bool {
        if canvas.isEditingText { return false }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if mods.contains(.command) {
            switch chars {
            case "z":
                mods.contains(.shift) ? redoAction() : undoAction(); return true
            case "s": saveAs(); return true
            case "c" where mods.contains(.shift): copyPath(); return true
            case "m" where mods.contains(.shift): copyMarkdownPath(); return true
            case "o" where mods.contains(.shift): runOCR(); return true
            case "p": pinImage(); return true
            case "d": canvas.duplicateSelection(); return true
            case "+", "=": zoomIn(); return true
            case "-": zoomOut(); return true
            case "0": zoomToFit(); return true
            default: return false
            }
        }
        guard mods.isEmpty || mods == .shift else { return false }

        switch chars {
        case "\u{1b}": close(); return true                        // esc
        case "\r", "\u{3}": copyAndClose(); return true            // return / enter
        case "[": adjustWidth(-1); return true
        case "]": adjustWidth(+1); return true
        case "f": fillToggle.state = fillToggle.state == .on ? .off : .on
                  fillToggled(fillToggle); return true
        default: break
        }

        if let tool = Self.toolOrder.first(where: { $0.shortcut.lowercased() == chars }) {
            canvas.currentTool = tool
            refreshToolButtons()
            return true
        }
        return false
    }

    private func adjustWidth(_ delta: Double) {
        widthSlider.doubleValue = max(1, min(24, widthSlider.doubleValue + delta))
        widthChanged(widthSlider)
    }
}

extension EditorWindowController: CanvasViewDelegate {
    func canvasDidChangeAnnotations(_ canvas: CanvasView) { updateStatus() }
    func canvasDidChangeSelection(_ canvas: CanvasView) {}
    func canvasDidPickColor(_ canvas: CanvasView, color: NSColor) {
        canvas.currentColor = color
        refreshColorButtons()
    }

    func canvasRequestsCrop(_ canvas: CanvasView, rect: CGRect) {
        let scale = (capture.pixelSize.width) / max(capture.image.size.width, 1)
        guard let cg = ImageUtilities.cgImage(from: canvas.baseImage) else { return }
        let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                               width: rect.width * scale, height: rect.height * scale)
        guard let cropped = ImageUtilities.crop(cg, toPixelRect: pixelRect) else { return }
        let newImage = ImageUtilities.nsImage(from: cropped, scale: scale)

        let oldImage = canvas.baseImage
        let delta = CGPoint(x: -rect.minX, y: -rect.minY)
        canvas.replaceImage(newImage)
        canvas.offsetAllAnnotations(by: delta)
        capture.image = newImage
        editorUndoManager.registerUndo(withTarget: self) { target in
            target.canvas.replaceImage(oldImage)
            target.canvas.offsetAllAnnotations(by: CGPoint(x: -delta.x, y: -delta.y))
            target.capture.image = oldImage
            target.updateStatus()
        }
        editorUndoManager.setActionName("Crop")
        canvas.currentTool = .select
        refreshToolButtons()
        zoomToFit()
        updateStatus()
    }
}

extension EditorWindowController: NSWindowDelegate {
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { editorUndoManager }
    func windowWillClose(_ notification: Notification) { onClose?(self) }
    func windowDidResize(_ notification: Notification) { updateStatus() }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#FF3B30" }
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    func isApproximately(_ other: NSColor) -> Bool {
        guard let a = usingColorSpace(.sRGB), let b = other.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.02
            && abs(a.greenComponent - b.greenComponent) < 0.02
            && abs(a.blueComponent - b.blueComponent) < 0.02
    }
}
