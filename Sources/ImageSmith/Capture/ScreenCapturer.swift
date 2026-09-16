import AppKit
import ScreenCaptureKit
import CoreGraphics

enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplay
    case noWindow
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "ImageSmith needs Screen Recording permission. Open System Settings → Privacy & Security → Screen & System Audio Recording and enable ImageSmith."
        case .noDisplay: return "No display available to capture."
        case .noWindow: return "No capturable window is frontmost."
        case .failed(let m): return m
        }
    }
}

/// Describes a window we can point the capturer at.
struct WindowInfo {
    let id: CGWindowID
    let frame: CGRect          // global screen points, top-left origin (CoreGraphics space)
    let title: String
    let appName: String
    let pid: pid_t
    let scWindow: SCWindow
}

actor ScreenCapturer {
    static let shared = ScreenCapturer()

    // MARK: Permission

    nonisolated static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    nonisolated static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    // MARK: Content

    private func shareableContent() async throws -> SCShareableContent {
        guard ScreenCapturer.hasPermission() else { throw CaptureError.permissionDenied }
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.permissionDenied
        }
    }

    /// On-screen windows that are worth offering to the user, front-to-back.
    func capturableWindows() async throws -> [WindowInfo] {
        let content = try await shareableContent()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return content.windows.compactMap { w -> WindowInfo? in
            guard w.isOnScreen,
                  w.frame.width > 40, w.frame.height > 40,
                  let app = w.owningApplication,
                  app.processID != ownPID,
                  app.bundleIdentifier != "com.apple.dock" || (w.title ?? "").isEmpty == false
            else { return nil }
            return WindowInfo(id: w.windowID, frame: w.frame, title: w.title ?? "",
                              appName: app.applicationName, pid: app.processID, scWindow: w)
        }
    }

    func frontmostWindow() async throws -> WindowInfo {
        let windows = try await capturableWindows()
        let frontPID = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        if let pid = frontPID,
           let match = windows.first(where: { $0.pid == pid }) {
            return match
        }
        guard let first = windows.first else { throw CaptureError.noWindow }
        return first
    }

    func window(at point: CGPoint) async throws -> WindowInfo? {
        let windows = try await capturableWindows()
        return windows.first { $0.frame.contains(point) }
    }

    // MARK: Capture primitives

    private func configuration(width: Int, height: Int, showsCursor: Bool) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = max(1, width)
        config.height = max(1, height)
        config.showsCursor = showsCursor
        config.captureResolution = .best
        config.scalesToFit = false
        config.ignoreShadowsSingleWindow = !SettingsStore.shared.prefs.includeWindowShadow
        config.ignoreShadowsDisplay = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    /// Capture one whole display at native pixel resolution.
    func captureDisplay(_ displayID: CGDirectDisplayID, scale: CGFloat, showsCursor: Bool) async throws -> CGImage {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first else { throw CaptureError.noDisplay }

        // Exclude our own overlay/HUD windows so they never bleed into the shot.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excluded = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let config = configuration(width: Int(CGFloat(display.width) * scale),
                                   height: Int(CGFloat(display.height) * scale),
                                   showsCursor: showsCursor)
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CaptureError.failed(error.localizedDescription)
        }
    }

    func captureWindow(_ info: WindowInfo, scale: CGFloat, showsCursor: Bool) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: info.scWindow)
        let config = configuration(width: Int(info.frame.width * scale),
                                   height: Int(info.frame.height * scale),
                                   showsCursor: showsCursor)
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CaptureError.failed(error.localizedDescription)
        }
    }
}
