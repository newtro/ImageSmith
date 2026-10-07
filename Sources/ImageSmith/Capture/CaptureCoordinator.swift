import AppKit

enum CaptureMode {
    case screen          // the display under the pointer
    case allDisplays     // every display stitched side by side
    case frontWindow     // frontmost window of the frontmost app
    case region          // interactive marquee
    case lastRegion      // repeat the previous region rect
}

/// Ties hotkeys to captures, the clipboard, the thumbnail and the editor —
/// including the "tap again within N seconds to edit" behaviour.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var editors: [EditorWindowController] = []
    private var videoEditors: [VideoEditorWindowController] = []
    private var lastMode: CaptureMode = .screen
    private var lastRegionRect: CGRect?
    private var busy = false
    private var recorder: ScreenRecorder?
    private var recordingFinishing = false
    private var stopCompletions: [() -> Void] = []
    private var recordingControl: RecordingControl?
    private var recordingSource = "Screen"
    var isRecording: Bool { recorder != nil || recordingFinishing }
    var isFinishingRecording: Bool { recordingFinishing }

    private init() {}

    // MARK: Hotkey entry point

    func handle(_ action: HotKeyManager.Action) {
        switch action {
        case .fullScreen:
            if consumeReopenTap() { return }
            capture(.screen)
        case .window:
            if consumeReopenTap() { return }
            capture(.frontWindow)
        case .region:
            if consumeReopenTap() { return }
            capture(.region)
        case .ocr:
            captureTextToClipboard()
        case .pin:
            captureAndPin()
        case .repeatLast:
            capture(lastRegionRect != nil ? .lastRegion : lastMode)
        case .recordScreen: toggleRecording(.screen)
        case .recordWindow: toggleRecording(.frontWindow)
        case .recordRegion: toggleRecording(.region)
        }
    }

    /// A second tap inside the reopen window means "edit what I just took"
    /// rather than "take another one".
    private func consumeReopenTap() -> Bool {
        guard CaptureStore.shared.isWithinReopenWindow(),
              let latest = CaptureStore.shared.latest else { return false }
        CaptureStore.shared.invalidateReopenWindow()
        ThumbnailOverlayController.dismissCurrent()
        openEditor(for: latest)
        return true
    }

    // MARK: Capture

    func capture(_ mode: CaptureMode) {
        guard !busy else { return }
        guard ensurePermission() else { return }
        lastMode = mode
        busy = true

        let delay = SettingsStore.shared.prefs.captureDelay
        Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            await self?.performCapture(mode)
            self?.busy = false
        }
    }

    private func ensurePermission() -> Bool {
        if ScreenCapturer.hasPermission() { return true }
        ScreenCapturer.requestPermission()
        Notifier.error(CaptureError.permissionDenied)
        return false
    }

    func toggleRecording(_ mode: CaptureMode) {
        if isRecording { stopRecording(); return }
        guard !busy, !recordingFinishing, ensurePermission() else { return }
        busy = true
        let delay = SettingsStore.shared.prefs.captureDelay
        Task { @MainActor [self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            do {
                if mode == .region {
                    let shots = await backdrops()
                    guard !shots.isEmpty else { busy = false; return }
                    RegionSelector.shared.begin(mode: .region, backdrops: shots,
                                                windowFrames: await windowFrames()) { [self] result in
                        guard let result else { self.busy = false; return }
                        self.lastRegionRect = result.rect
                        Task { @MainActor in
                            await self.beginRecording(.region(ScreenGeometry.displayID(of: result.screen),
                                                              result.screen.backingScaleFactor, result.rect,
                                                              screenFrame: result.screen.frame),
                                                      source: "Region")
                        }
                    }
                } else if mode == .frontWindow {
                    let info = try await ScreenCapturer.shared.frontmostWindow()
                    let screen = NSScreen.screens.first(where: { $0.frame.intersects(ScreenGeometry.cocoaRect(fromCG: info.frame)) })
                        ?? NSScreen.main!
                    await beginRecording(.window(info, screen.backingScaleFactor),
                                         source: info.title.isEmpty ? info.appName : "\(info.appName) — \(info.title)")
                } else {
                    let screen = ScreenGeometry.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main!
                    await beginRecording(.display(ScreenGeometry.displayID(of: screen), screen.backingScaleFactor),
                                         source: "Screen")
                }
            } catch {
                busy = false
                Notifier.error(error)
            }
        }
    }

    private func beginRecording(_ target: RecordingTarget, source: String) async {
        let date = Date()
        do {
            let url = try CaptureStore.shared.recordingURL(date: date)
            let prefs = SettingsStore.shared.prefs
            let options = RecordingOptions(includeCursor: prefs.includeCursor,
                                           systemAudio: prefs.recordSystemAudio,
                                           downscaleRetina: prefs.downscaleRetina,
                                           includeWindowShadow: prefs.includeWindowShadow)
            let recorder = try await ScreenRecorder.start(target: target, url: url, options: options)
            recorder.onUnexpectedStop = { [weak self] error in
                self?.stopRecording()
                Notifier.show(title: "Recording interrupted", body: error.localizedDescription)
            }
            self.recorder = recorder
            recordingSource = source
            recordingControl = RecordingControl { [weak self] in self?.stopRecording() }
            NotificationCenter.default.post(name: CaptureStore.didChange, object: nil)
        } catch {
            Notifier.error(error)
        }
        busy = false
    }

    func stopRecording(completion: (() -> Void)? = nil) {
        if let completion { stopCompletions.append(completion) }
        if recordingFinishing { return }
        guard let recorder else {
            stopCompletions.forEach { $0() }
            stopCompletions.removeAll()
            return
        }
        recordingFinishing = true
        self.recorder = nil
        let source = recordingSource
        recordingControl?.close()
        recordingControl = nil
        NotificationCenter.default.post(name: CaptureStore.didChange, object: nil)
        Task { @MainActor [self] in
            do {
                let poster = try await recorder.stop()
                CaptureStore.shared.updateLatestRecording(recorder.url)
                let capture = Capture(image: poster, sourceDescription: "Recording — \(source)",
                                      fileURL: recorder.url, isRecording: true)
                CaptureStore.shared.copyToPasteboard(capture)
                CaptureStore.shared.record(capture)
                Notifier.flashStatusItem()
                if SettingsStore.shared.prefs.afterCapture == .clipboardFileAndEditor {
                    openEditor(for: capture)
                } else if SettingsStore.shared.prefs.showThumbnail {
                    ThumbnailOverlayController.present(capture: capture) { [self] c in self.openEditor(for: c) }
                }
            } catch { Notifier.error(error) }
            recordingFinishing = false
            stopCompletions.forEach { $0() }
            stopCompletions.removeAll()
        }
    }

    private func performCapture(_ mode: CaptureMode) async {
        do {
            switch mode {
            case .screen:
                let screen = ScreenGeometry.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main!
                let cg = try await captureScreen(screen)
                finish(cgImage: cg, scale: screen.backingScaleFactor, source: "Screen")

            case .allDisplays:
                var images: [(NSScreen, CGImage)] = []
                for screen in NSScreen.screens {
                    images.append((screen, try await captureScreen(screen)))
                }
                if let stitched = stitch(images) {
                    finish(image: stitched, source: "All displays")
                }

            case .frontWindow:
                let info = try await ScreenCapturer.shared.frontmostWindow()
                let screen = ScreenGeometry.screen(containing: NSEvent.mouseLocation) ?? NSScreen.main!
                let cg = try await ScreenCapturer.shared.captureWindow(
                    info, scale: screen.backingScaleFactor,
                    showsCursor: SettingsStore.shared.prefs.includeCursor)
                let name = info.title.isEmpty ? info.appName : "\(info.appName) — \(info.title)"
                finish(cgImage: cg, scale: screen.backingScaleFactor, source: name)

            case .region:
                await beginRegionCapture()

            case .lastRegion:
                guard let rect = lastRegionRect else { await beginRegionCapture(); return }
                let screen = ScreenGeometry.screen(containing: NSPoint(x: rect.midX, y: rect.midY)) ?? NSScreen.main!
                let cg = try await captureScreen(screen)
                let scale = screen.backingScaleFactor
                let local = CGRect(x: (rect.minX - screen.frame.minX) * scale,
                                   y: (screen.frame.maxY - rect.maxY) * scale,
                                   width: rect.width * scale, height: rect.height * scale)
                if let cropped = ImageUtilities.crop(cg, toPixelRect: local) {
                    finish(cgImage: cropped, scale: scale, source: "Region (repeat)")
                }
            }
        } catch {
            Notifier.error(error)
        }
    }

    private func captureScreen(_ screen: NSScreen) async throws -> CGImage {
        try await ScreenCapturer.shared.captureDisplay(
            ScreenGeometry.displayID(of: screen),
            scale: screen.backingScaleFactor,
            showsCursor: SettingsStore.shared.prefs.includeCursor)
    }

    private func stitch(_ images: [(NSScreen, CGImage)]) -> NSImage? {
        guard !images.isEmpty else { return nil }
        var union = NSRect.zero
        for (screen, _) in images { union = union.isEmpty ? screen.frame : union.union(screen.frame) }
        // Render at the highest backing scale in play so no display is softened.
        let scale = images.map { $0.0.backingScaleFactor }.max() ?? 1
        let pixels = CGSize(width: union.width * scale, height: union.height * scale)
        return ImageUtilities.renderBitmap(pointSize: union.size, pixelSize: pixels) {
            NSColor.black.setFill()
            NSRect(origin: .zero, size: union.size).fill()
            for (screen, cg) in images {
                // Flip each screen's origin into the union's top-left space.
                let rect = NSRect(x: screen.frame.minX - union.minX,
                                  y: union.maxY - screen.frame.maxY,
                                  width: screen.frame.width, height: screen.frame.height)
                NSImage(cgImage: cg, size: screen.frame.size).draw(in: rect)
            }
        }
    }

    // MARK: Region / picker flows

    private func backdrops() async -> [(NSScreen, CGImage)] {
        var result: [(NSScreen, CGImage)] = []
        for screen in NSScreen.screens {
            if let cg = try? await captureScreen(screen) { result.append((screen, cg)) }
        }
        return result
    }

    private func windowFrames() async -> [(CGRect, String)] {
        guard let windows = try? await ScreenCapturer.shared.capturableWindows() else { return [] }
        return windows.map { ($0.frame, $0.appName) }
    }

    private func beginRegionCapture() async {
        let shots = await backdrops()
        let frames = await windowFrames()
        guard !shots.isEmpty else { return }
        RegionSelector.shared.begin(mode: .region, backdrops: shots, windowFrames: frames) { [weak self] result in
            guard let self else { return }
            guard let result, let cg = result.image else { return }
            self.lastRegionRect = result.rect
            self.finish(cgImage: cg, scale: result.screen.backingScaleFactor, source: "Region")
        }
    }

    private func captureTextToClipboard() {
        guard ensurePermission() else { return }
        Task { @MainActor in
            let shots = await backdrops()
            guard !shots.isEmpty else { return }
            RegionSelector.shared.begin(mode: .region, backdrops: shots, windowFrames: await windowFrames()) { result in
                guard let result, let cg = result.image else { return }
                let image = ImageUtilities.nsImage(from: cg, scale: result.screen.backingScaleFactor)
                Task { @MainActor in
                    let text = await OCRService.recognizeText(in: image)
                    let codes = await OCRService.detectBarcodes(in: image)
                    let payload = codes.isEmpty ? text : (text.isEmpty ? codes.joined(separator: "\n")
                                                          : text + "\n" + codes.joined(separator: "\n"))
                    guard !payload.isEmpty else {
                        Notifier.show(title: "No text found", body: nil)
                        return
                    }
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(payload, forType: .string)
                    Notifier.playShutter()
                    Notifier.show(title: "Text copied", body: String(payload.prefix(120)))
                }
            }
        }
    }

    private func captureAndPin() {
        guard ensurePermission() else { return }
        Task { @MainActor in
            let shots = await backdrops()
            guard !shots.isEmpty else { return }
            RegionSelector.shared.begin(mode: .region, backdrops: shots, windowFrames: await windowFrames()) { result in
                guard let result, let cg = result.image else { return }
                let image = ImageUtilities.nsImage(from: cg, scale: result.screen.backingScaleFactor)
                PinnedWindowController.pin(image: image)
            }
        }
    }

    func pickColor() {
        guard ensurePermission() else { return }
        Task { @MainActor in
            let shots = await backdrops()
            guard !shots.isEmpty else { return }
            RegionSelector.shared.begin(mode: .colorPicker, backdrops: shots) { result in
                guard let color = result?.color else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(color.hexString, forType: .string)
                Notifier.show(title: "Colour copied", body: color.hexString)
            }
        }
    }

    // MARK: Post-processing

    private func finish(cgImage: CGImage, scale: CGFloat, source: String) {
        var working = cgImage
        var effectiveScale = scale
        if SettingsStore.shared.prefs.downscaleRetina, scale > 1,
           let scaled = ImageUtilities.scale(cgImage, by: 1 / scale) {
            working = scaled
            effectiveScale = 1
        }
        finish(image: ImageUtilities.nsImage(from: working, scale: effectiveScale), source: source)
    }

    private func finish(image: NSImage, source: String) {
        let prefs = SettingsStore.shared.prefs
        let decorated = ImageUtilities.decorate(image,
                                                padding: CGFloat(prefs.windowPadding),
                                                shadow: prefs.includeWindowShadow,
                                                background: prefs.backgroundStyle)
        let capture = Capture(image: decorated, sourceDescription: source)

        if prefs.afterCapture != .clipboardOnly {
            CaptureStore.shared.writeToDisk(capture)
        }
        CaptureStore.shared.copyToPasteboard(capture)
        CaptureStore.shared.record(capture)

        Notifier.playShutter()
        Notifier.flashScreens()
        Notifier.flashStatusItem()

        if prefs.afterCapture == .clipboardFileAndEditor {
            openEditor(for: capture)
        } else if prefs.showThumbnail {
            ThumbnailOverlayController.present(capture: capture) { [weak self] c in
                self?.openEditor(for: c)
            }
        }
    }

    // MARK: Editor

    func openEditor(for capture: Capture) {
        if capture.isRecording {
            openVideoEditor(for: capture)
            return
        }
        if let existing = editors.first(where: { $0.capture === capture }) {
            NSApp.activate(ignoringOtherApps: true)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = EditorWindowController(capture: capture)
        controller.onClose = { [weak self] c in
            self?.editors.removeAll { $0 === c }
            if self?.editors.isEmpty == true && self?.videoEditors.isEmpty == true {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        editors.append(controller)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func openVideoEditor(for capture: Capture) {
        if let existing = videoEditors.first(where: { $0.capture === capture }) {
            NSApp.activate(ignoringOtherApps: true)
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let controller = VideoEditorWindowController(capture: capture) else { return }
        controller.onClose = { [weak self] c in
            self?.videoEditors.removeAll { $0 === c }
            if self?.editors.isEmpty == true && self?.videoEditors.isEmpty == true {
                NSApp.setActivationPolicy(.accessory)
            }
        }
        videoEditors.append(controller)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func openVideoFile(_ url: URL) {
        let image = VideoEditExporter.poster(for: url)
            ?? NSImage(systemSymbolName: "video", accessibilityDescription: "Recording")!
        let capture = Capture(image: image, sourceDescription: url.lastPathComponent,
                              fileURL: url, isRecording: true)
        CaptureStore.shared.record(capture)
        openEditor(for: capture)
    }

    func openEditorForLatest() {
        guard let latest = CaptureStore.shared.latest else { return }
        openEditor(for: latest)
    }

    func openImageFile(_ url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        let capture = Capture(image: image, sourceDescription: url.lastPathComponent, fileURL: url)
        CaptureStore.shared.record(capture)
        openEditor(for: capture)
    }

    func editClipboardImage() {
        let pb = NSPasteboard.general
        guard let image = NSImage(pasteboard: pb) else {
            Notifier.show(title: "No image on the clipboard", body: nil)
            return
        }
        let capture = Capture(image: image, sourceDescription: "Clipboard")
        CaptureStore.shared.record(capture)
        openEditor(for: capture)
    }
}
