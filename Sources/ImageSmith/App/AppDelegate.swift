import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuBar = MenuBarController()

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        menuBar.install()
        Notifier.prepare()

        HotKeyManager.shared.onAction = { action in
            Task { @MainActor in CaptureCoordinator.shared.handle(action) }
        }
        HotKeyManager.shared.start()
        AppUpdater.shared.start()

        if !ScreenCapturer.hasPermission() {
            ScreenCapturer.requestPermission()
            showFirstRunNoticeIfNeeded()
        } else {
            showFirstRunNoticeIfNeeded()
        }
    }

    @objc private func checkForUpdates() { AppUpdater.shared.checkForUpdates() }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard CaptureCoordinator.shared.isRecording else { return .terminateNow }
        CaptureCoordinator.shared.stopRecording {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: URL scheme — imagesmith://capture/region, imagesmith://edit/latest, …
    // This is what the `imagesmith` CLI shim drives, so scripts and agents can
    // trigger a capture without touching the keyboard.

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handle(url: url) }
    }

    private func handle(url: URL) {
        guard url.scheme?.lowercased() == "imagesmith" else { return }
        let verb = (url.host ?? "").lowercased()
        let arg = url.pathComponents.dropFirst().first?.lowercased() ?? ""

        switch (verb, arg) {
        case ("capture", "screen"), ("capture", ""):
            CaptureCoordinator.shared.capture(.screen)
        case ("capture", "window"):
            CaptureCoordinator.shared.capture(.frontWindow)
        case ("capture", "region"):
            CaptureCoordinator.shared.capture(.region)
        case ("capture", "alldisplays"), ("capture", "all"):
            CaptureCoordinator.shared.capture(.allDisplays)
        case ("capture", "repeat"):
            CaptureCoordinator.shared.capture(.lastRegion)
        case ("capture", "text"), ("capture", "ocr"):
            CaptureCoordinator.shared.handle(.ocr)
        case ("capture", "color"), ("capture", "colour"):
            CaptureCoordinator.shared.pickColor()
        case ("capture", "pin"):
            CaptureCoordinator.shared.handle(.pin)
        case ("record", "screen"), ("record", ""):
            CaptureCoordinator.shared.toggleRecording(.screen)
        case ("record", "window"):
            CaptureCoordinator.shared.toggleRecording(.frontWindow)
        case ("record", "region"):
            CaptureCoordinator.shared.toggleRecording(.region)
        case ("record", "stop"):
            CaptureCoordinator.shared.stopRecording()
        case ("edit", "latest"), ("edit", ""):
            CaptureCoordinator.shared.openEditorForLatest()
        case ("edit", "clipboard"):
            CaptureCoordinator.shared.editClipboardImage()
        case ("open", "movie"), ("open", "recording"):
            if let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "path" })?.value {
                CaptureCoordinator.shared.openVideoFile(URL(fileURLWithPath: path))
            }
        // `hotkey/...` goes through the same path as a real key press, so it honours
        // the tap-again-to-edit window. `capture/...` always takes a fresh shot,
        // which is what a script wants.
        case ("hotkey", "fullscreen"), ("hotkey", "screen"):
            CaptureCoordinator.shared.handle(.fullScreen)
        case ("hotkey", "window"):
            CaptureCoordinator.shared.handle(.window)
        case ("hotkey", "region"):
            CaptureCoordinator.shared.handle(.region)
        case ("hotkey", "text"), ("hotkey", "ocr"):
            CaptureCoordinator.shared.handle(.ocr)
        case ("hotkey", "pin"):
            CaptureCoordinator.shared.handle(.pin)
        case ("hotkey", "repeat"):
            CaptureCoordinator.shared.handle(.repeatLast)
        case ("login", "enable"):
            LoginItem.set(enabled: true)
        case ("login", "disable"):
            LoginItem.set(enabled: false)
        case ("login", "status"), ("login", ""):
            NSLog("ImageSmith: launch at login is \(LoginItem.statusDescription)")
        case ("settings", _):
            SettingsWindowController.show()
        default:
            NSLog("ImageSmith: unrecognised URL \(url)")
        }
    }

    private func showFirstRunNoticeIfNeeded() {
        let key = "didShowWelcome.v1"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        NSApp.activate(ignoringOtherApps: true)
        let prefs = SettingsStore.shared.prefs
        let alert = NSAlert()
        alert.messageText = "ImageSmith is running in the menu bar"
        alert.informativeText = """
        \(prefs.fullScreenHotKey.displayString) — capture the screen
        \(prefs.windowHotKey.displayString) — capture the front window
        \(prefs.regionHotKey.displayString) — capture a region

        Every capture lands on the clipboard and is saved to
        \(SettingsStore.shared.saveDirectory.path).

        Press a capture shortcut again within \(Int(prefs.editorReopenWindow)) seconds to open the
        markup editor on the shot you just took.

        On a PC keyboard, Print Screen is F13. Mac keyboards without F13 should
        rebind these in Settings.
        """
        alert.addButton(withTitle: "Got it")
        alert.addButton(withTitle: "Open Settings")
        if alert.runModal() == .alertSecondButtonReturn {
            SettingsWindowController.show()
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: Main menu (needed so the standard editing shortcuts work in windows)

    private func buildMainMenu() {
        let main = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About ImageSmith",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        appMenu.addItem(update)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide ImageSmith", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit ImageSmith", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        main.addItem(appMenuItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    @objc private func openSettings() { SettingsWindowController.show() }
}
