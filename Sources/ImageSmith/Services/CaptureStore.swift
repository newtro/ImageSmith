import AppKit

/// One capture, plus wherever it ended up on disk.
final class Capture: Identifiable {
    let id = UUID()
    let date: Date
    var image: NSImage
    var fileURL: URL?
    let sourceDescription: String
    let isRecording: Bool

    init(image: NSImage, sourceDescription: String, date: Date = Date(), fileURL: URL? = nil,
         isRecording: Bool = false) {
        self.image = image
        self.sourceDescription = sourceDescription
        self.date = date
        self.fileURL = fileURL
        self.isRecording = isRecording
    }

    var pixelSize: NSSize {
        guard let rep = image.representations.first else { return image.size }
        return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}

/// Owns the capture history, file writing, and the pasteboard.
final class CaptureStore {
    static let shared = CaptureStore()
    static let didChange = Notification.Name("ImageSmith.historyDidChange")

    private(set) var history: [Capture] = []
    private(set) var lastCaptureDate: Date?

    var latest: Capture? { history.first }

    private init() {}

    func record(_ capture: Capture) {
        history.insert(capture, at: 0)
        let limit = max(1, SettingsStore.shared.prefs.historyLimit)
        if history.count > limit { history.removeLast(history.count - limit) }
        lastCaptureDate = capture.isRecording ? nil : capture.date
        NotificationCenter.default.post(name: CaptureStore.didChange, object: nil)
    }

    func clearHistory() {
        history.removeAll()
        NotificationCenter.default.post(name: CaptureStore.didChange, object: nil)
    }

    /// True when the user is inside the "press again to edit" window.
    func isWithinReopenWindow(now: Date = Date()) -> Bool {
        guard let last = lastCaptureDate else { return false }
        return now.timeIntervalSince(last) <= SettingsStore.shared.prefs.editorReopenWindow
    }

    func invalidateReopenWindow() { lastCaptureDate = nil }

    // MARK: Files

    @discardableResult
    func writeToDisk(_ capture: Capture) -> URL? {
        guard !capture.isRecording else { return capture.fileURL }
        let prefs = SettingsStore.shared.prefs
        let dir = SettingsStore.shared.saveDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            NSLog("ImageSmith: cannot create save directory: \(error)")
            return nil
        }

        let ext = prefs.jpegInsteadOfPNG ? "jpg" : "png"
        var url: URL
        if let existing = capture.fileURL,
           existing.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL {
            // Re-saving after markup overwrites the shot it came from.
            url = existing
        } else {
            let base = expand(template: prefs.fileNameTemplate, date: capture.date)
            url = dir.appendingPathComponent("\(base).\(ext)")
            var counter = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = dir.appendingPathComponent("\(base) (\(counter)).\(ext)")
                counter += 1
            }
        }

        let data = prefs.jpegInsteadOfPNG
            ? ImageUtilities.jpegData(from: capture.image, quality: CGFloat(prefs.jpegQuality))
            : ImageUtilities.pngData(from: capture.image)
        guard let data else { return nil }
        do {
            try data.write(to: url)
            capture.fileURL = url
            if prefs.maintainLatestSymlink { updateLatestSymlink(to: url, in: dir, ext: ext) }
            return url
        } catch {
            NSLog("ImageSmith: write failed: \(error)")
            return nil
        }
    }

    /// `latest.png` always points at the newest capture — handy for telling an agent
    /// "read ~/Pictures/ImageSmith/latest.png" without pasting a fresh path each time.
    private func updateLatestSymlink(to url: URL, in dir: URL, ext: String) {
        let fm = FileManager.default
        for candidate in ["latest.png", "latest.jpg"] {
            let link = dir.appendingPathComponent(candidate)
            if let attrs = try? fm.attributesOfItem(atPath: link.path),
               attrs[.type] as? FileAttributeType == .typeSymbolicLink || fm.fileExists(atPath: link.path) {
                try? fm.removeItem(at: link)
            }
        }
        try? fm.createSymbolicLink(at: dir.appendingPathComponent("latest.\(ext)"), withDestinationURL: url)
    }

    func recordingURL(date: Date) throws -> URL {
        let dir = SettingsStore.shared.saveDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = expand(template: SettingsStore.shared.prefs.recordingFileNameTemplate, date: date)
        var url = dir.appendingPathComponent("\(base).mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) (\(counter)).mp4")
            counter += 1
        }
        return url
    }

    func updateLatestRecording(_ url: URL) {
        guard SettingsStore.shared.prefs.maintainLatestSymlink else { return }
        let link = SettingsStore.shared.saveDirectory.appendingPathComponent("latest.mp4")
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
    }

    func expand(template: String, date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        var out = template

        func replace(_ token: String, _ format: String) {
            guard out.contains(token) else { return }
            df.dateFormat = format
            out = out.replacingOccurrences(of: token, with: df.string(from: date))
        }
        replace("{date}", "yyyy-MM-dd")
        replace("{time}", "HH.mm.ss")
        replace("{year}", "yyyy")
        replace("{month}", "MM")
        replace("{day}", "dd")
        replace("{hour}", "HH")
        replace("{minute}", "mm")
        replace("{second}", "ss")
        out = out.replacingOccurrences(of: "{epoch}", with: String(Int(date.timeIntervalSince1970)))
        // Slashes would silently create subdirectories; colons break Finder display.
        return out.replacingOccurrences(of: "/", with: "-")
                  .replacingOccurrences(of: ":", with: ".")
    }

    // MARK: Pasteboard

    func copyToPasteboard(_ capture: Capture, payload: ClipboardPayload? = nil) {
        let mode = payload ?? SettingsStore.shared.prefs.clipboardPayload
        let pb = NSPasteboard.general
        pb.clearContents()

        if capture.isRecording {
            guard let url = capture.fileURL else { return }
            if mode == .pathOnly { pb.setString(url.path, forType: .string) }
            else { pb.writeObjects([url as NSURL]) }
            return
        }

        switch mode {
        case .image:
            writeImage(capture.image, to: pb)
        case .imageAndPath:
            if let url = capture.fileURL {
                pb.writeObjects([url as NSURL])
            }
            writeImage(capture.image, to: pb)
        case .pathOnly:
            if let url = capture.fileURL {
                pb.setString(url.path, forType: .string)
                pb.writeObjects([url as NSURL])
            } else {
                writeImage(capture.image, to: pb)
            }
        }
    }

    private func writeImage(_ image: NSImage, to pb: NSPasteboard) {
        // Put PNG on first: apps that understand it get lossless pixels with alpha.
        if let png = ImageUtilities.pngData(from: image) {
            pb.setData(png, forType: .png)
        }
        if let tiff = image.tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }

    func copyPath(_ capture: Capture, markdown: Bool) {
        guard let url = capture.fileURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let markup = capture.isRecording ? "[recording](\(url.path))" : "![screenshot](\(url.path))"
        pb.setString(markdown ? markup : url.path, forType: .string)
    }
}
