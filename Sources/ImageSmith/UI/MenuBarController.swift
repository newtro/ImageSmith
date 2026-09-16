import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder",
                                           accessibilityDescription: "ImageSmith")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.toolTip = "ImageSmith"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        Notifier.statusItemFlash = { [weak self] in self?.flash() }
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild),
                                               name: CaptureStore.didChange, object: nil)
    }

    private func flash() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "camera.viewfinder.badge.checkmark",
                               accessibilityDescription: "Captured")
            ?? NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Captured")
        button.image?.isTemplate = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder",
                                                     accessibilityDescription: "ImageSmith")
            self?.statusItem.button?.image?.isTemplate = true
        }
    }

    @objc private func rebuild() {}

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.autoenablesItems = false
        menu.removeAllItems()
        let prefs = SettingsStore.shared.prefs

        add(menu, "Capture Screen", prefs.fullScreenHotKey) { CaptureCoordinator.shared.capture(.screen) }
        add(menu, "Capture Front Window", prefs.windowHotKey) { CaptureCoordinator.shared.capture(.frontWindow) }
        add(menu, "Capture Region…", prefs.regionHotKey) { CaptureCoordinator.shared.capture(.region) }
        add(menu, "Capture All Displays", nil) { CaptureCoordinator.shared.capture(.allDisplays) }
        add(menu, "Repeat Last Capture", prefs.repeatHotKey) { CaptureCoordinator.shared.capture(.lastRegion) }

        menu.addItem(.separator())
        add(menu, "Capture Text (OCR)…", prefs.ocrHotKey) { CaptureCoordinator.shared.handle(.ocr) }
        add(menu, "Capture and Pin…", prefs.pinHotKey) { CaptureCoordinator.shared.handle(.pin) }
        add(menu, "Pick a Colour…", nil) { CaptureCoordinator.shared.pickColor() }
        add(menu, "Close All Pinned Images", nil) { PinnedWindowController.closeAll() }

        menu.addItem(.separator())
        add(menu, "Edit Last Capture", nil, enabled: CaptureStore.shared.latest != nil) {
            CaptureCoordinator.shared.openEditorForLatest()
        }
        add(menu, "Edit Image on Clipboard", nil) { CaptureCoordinator.shared.editClipboardImage() }
        add(menu, "Open Image…", nil) { self.openImage() }

        if !CaptureStore.shared.history.isEmpty {
            let recent = NSMenu()
            for capture in CaptureStore.shared.history.prefix(15) {
                let item = NSMenuItem(title: Self.timeFormatter.string(from: capture.date)
                                        + "  " + capture.sourceDescription,
                                      action: #selector(openRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = capture
                let thumb = NSImage(size: NSSize(width: 44, height: 28), flipped: false) { rect in
                    capture.image.draw(in: rect)
                    return true
                }
                item.image = thumb
                recent.addItem(item)
            }
            recent.addItem(.separator())
            let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
            clear.target = self
            recent.addItem(clear)

            let recentItem = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
            recentItem.submenu = recent
            menu.addItem(recentItem)
        }

        menu.addItem(.separator())
        add(menu, "Copy Last File Path", nil, enabled: CaptureStore.shared.latest?.fileURL != nil) {
            if let c = CaptureStore.shared.latest { CaptureStore.shared.copyPath(c, markdown: false) }
        }
        add(menu, "Copy Last Path as Markdown", nil, enabled: CaptureStore.shared.latest?.fileURL != nil) {
            if let c = CaptureStore.shared.latest { CaptureStore.shared.copyPath(c, markdown: true) }
        }
        add(menu, "Open Save Folder", nil) {
            NSWorkspace.shared.open(SettingsStore.shared.saveDirectory)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        add(menu, "About ImageSmith", nil) {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        let quit = NSMenuItem(title: "Quit ImageSmith", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func add(_ menu: NSMenu, _ title: String, _ combo: HotKeyCombo?,
                     enabled: Bool = true, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(runBlock(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        item.representedObject = BlockBox(action)
        if let combo, !combo.isEmpty {
            let attr = NSMutableAttributedString(string: title)
            attr.append(NSAttributedString(
                string: "   \(combo.displayString)",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                             .font: NSFont.systemFont(ofSize: NSFont.systemFontSize - 1)]))
            item.attributedTitle = attr
        }
        menu.addItem(item)
    }

    @objc private func runBlock(_ sender: NSMenuItem) {
        (sender.representedObject as? BlockBox)?.block()
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let capture = sender.representedObject as? Capture else { return }
        CaptureCoordinator.shared.openEditor(for: capture)
    }

    @objc private func clearHistory() { CaptureStore.shared.clearHistory() }

    @objc private func openSettings() { SettingsWindowController.show() }

    private func openImage() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            CaptureCoordinator.shared.openImageFile(url)
        }
    }
}

final class BlockBox {
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
}
