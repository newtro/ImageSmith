import AppKit
import UserNotifications

enum Notifier {
    private static var authorized = false

    static func prepare() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            authorized = granted
        }
    }

    static func show(title: String, body: String?) {
        guard authorized else {
            NSLog("ImageSmith: \(title) \(body ?? "")")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func error(_ error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "ImageSmith"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            if case CaptureError.permissionDenied = error {
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                    NSWorkspace.shared.open(url)
                }
                return
            }
            alert.runModal()
        }
    }

    static func playShutter() {
        guard SettingsStore.shared.prefs.playSound else { return }
        NSSound(named: "Grab")?.play()
    }

    /// Brief white flash over each screen, like the system screenshot tool.
    static func flashScreens() {
        guard SettingsStore.shared.prefs.showFlash else { return }
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.level = .screenSaver
            window.backgroundColor = .white
            window.alphaValue = 0.45
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                window.animator().alphaValue = 0
            } completionHandler: {
                window.orderOut(nil)
            }
        }
    }

    static var statusItemFlash: (() -> Void)?
    static func flashStatusItem() { statusItemFlash?() }
}
