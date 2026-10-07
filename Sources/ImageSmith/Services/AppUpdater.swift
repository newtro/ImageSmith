import AppKit
import Sparkle

/// Sparkle-driven updates: a daily background check plus "Check for Updates…".
/// The feed and EdDSA public key come from Info.plist (Scripts/build-app.sh), so
/// a bare `swift run` or test host has no feed and the updater stays off.
@MainActor
final class AppUpdater: NSObject, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()

    private var controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    func start() {
        guard controller == nil,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil, userDriverDelegate: self)
    }

    func checkForUpdates() {
        guard let controller else { return }
        // A menu-bar app has no Dock icon; without activating, Sparkle's window
        // can open behind whatever app is in front.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    // MARK: Scheduled checks in a menu-bar app
    // Sparkle's default alert for a background check would open behind the active
    // app. Opting into gentle reminders lets us bring it forward ourselves.

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }
}
