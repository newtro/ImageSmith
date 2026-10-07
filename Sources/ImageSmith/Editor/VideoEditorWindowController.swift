import AppKit
@preconcurrency import AVFoundation
import AVKit
import UniformTypeIdentifiers

@MainActor
final class VideoEditorWindowController: NSWindowController, NSWindowDelegate {
    let capture: Capture
    var onClose: ((VideoEditorWindowController) -> Void)?

    private let sourceURL: URL
    private let asset: AVURLAsset
    private let player = AVPlayer()
    private let playerView = AVPlayerView()
    private let timeline = VideoTimelineView()
    private let seekSlider = NSSlider()
    private let timeLabel = NSTextField(labelWithString: "00:00.0")
    private let durationLabel = NSTextField(labelWithString: "00:00.0")
    private let inTimeLabel = NSTextField(labelWithString: "00:00.0")
    private let outTimeLabel = NSTextField(labelWithString: "00:00.0")
    private let selectionLabel = NSTextField(labelWithString: "Full clip selected")
    private let statusLabel = NSTextField(labelWithString: "Loading recording…")
    private let playButton = NSButton(title: "", target: nil, action: nil)
    private let trimButton = NSButton(title: "Trim", target: nil, action: nil)
    private let cutButton = NSButton(title: "Cut", target: nil, action: nil)
    private let splitButton = NSButton(title: "Split", target: nil, action: nil)
    private let undoButton = NSButton(title: "", target: nil, action: nil)
    private let redoButton = NSButton(title: "", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export…", target: nil, action: nil)
    private let muteButton = NSButton(checkboxWithTitle: "Mute audio", target: nil, action: nil)
    private let ratePopup = NSPopUpButton()
    private let fileLabel = NSTextField(labelWithString: "")
    private let teal = NSColor(srgbRed: 0.29, green: 0.78, blue: 0.80, alpha: 1)
    private var plan = VideoEditPlan(duration: 0)
    private var undoStack: [VideoEditPlan] = []
    private var redoStack: [VideoEditPlan] = []
    private var selection: ClosedRange<Double> = 0...0
    private var timeObserver: Any?
    private var previewGeneration = 0
    private var exporting = false
    private var loaded = false

    init?(capture: Capture) {
        guard let url = capture.fileURL else { return nil }
        self.capture = capture
        sourceURL = url
        asset = AVURLAsset(url: url)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "ImageSmith — \(url.lastPathComponent)"
        window.center()
        window.minSize = NSSize(width: 1000, height: 620)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildUI()
        Task { await loadRecording() }
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    private func buildUI() {
        guard let window else { return }
        let background = NSColor(srgbRed: 0.105, green: 0.115, blue: 0.135, alpha: 1)
        let surface = NSColor(srgbRed: 0.145, green: 0.16, blue: 0.18, alpha: 1)
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = background.cgColor
        window.contentView = container

        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        // Command bar: the file and the primary output action stay visible.
        let header = NSView()
        header.wantsLayer = true
        header.layer?.backgroundColor = surface.cgColor
        header.heightAnchor.constraint(equalToConstant: 66).isActive = true
        let headerRow = row(spacing: 12)
        pin(headerRow, to: header, insets: NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 20))
        let filmIcon = NSImageView(image: NSImage(systemSymbolName: "film.stack", accessibilityDescription: "Recording") ?? NSImage())
        filmIcon.contentTintColor = teal
        filmIcon.widthAnchor.constraint(equalToConstant: 25).isActive = true
        filmIcon.heightAnchor.constraint(equalToConstant: 25).isActive = true
        headerRow.addArrangedSubview(filmIcon)
        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.spacing = 1
        let sectionTitle = label("Recording editor", size: 14, weight: .semibold)
        fileLabel.stringValue = sourceURL.lastPathComponent
        fileLabel.font = .systemFont(ofSize: 11)
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle
        titleStack.addArrangedSubview(sectionTitle)
        titleStack.addArrangedSubview(fileLabel)
        headerRow.addArrangedSubview(titleStack)
        headerRow.addArrangedSubview(flexibleSpace())
        configure(undoButton, action: #selector(undoEdit), symbol: "arrow.uturn.backward", help: "Undo edit")
        configure(redoButton, action: #selector(redoEdit), symbol: "arrow.uturn.forward", help: "Redo edit")
        undoButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        redoButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
        headerRow.addArrangedSubview(undoButton)
        headerRow.addArrangedSubview(redoButton)
        let divider = NSBox()
        divider.boxType = .separator
        divider.heightAnchor.constraint(equalToConstant: 24).isActive = true
        headerRow.addArrangedSubview(divider)
        configure(exportButton, action: #selector(exportVideo), symbol: "square.and.arrow.up", help: "Export a new MP4")
        exportButton.bezelStyle = .rounded
        exportButton.contentTintColor = teal
        exportButton.keyEquivalent = "e"
        exportButton.keyEquivalentModifierMask = .command
        headerRow.addArrangedSubview(exportButton)
        root.addArrangedSubview(header)

        // A dark stage gives the recording priority; controls sit beside it.
        let workArea = NSView()
        workArea.translatesAutoresizingMaskIntoConstraints = false
        workArea.setContentHuggingPriority(.defaultLow, for: .vertical)
        let stage = NSView()
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor.black.cgColor
        stage.layer?.cornerRadius = 8
        stage.layer?.masksToBounds = true
        stage.translatesAutoresizingMaskIntoConstraints = false
        workArea.addSubview(stage)
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: stage.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: stage.bottomAnchor)
        ])

        let inspector = NSView()
        inspector.wantsLayer = true
        inspector.layer?.backgroundColor = surface.cgColor
        inspector.layer?.cornerRadius = 8
        inspector.translatesAutoresizingMaskIntoConstraints = false
        workArea.addSubview(inspector)
        let inspectorStack = NSStackView()
        inspectorStack.orientation = .vertical
        inspectorStack.alignment = .leading
        inspectorStack.spacing = 14
        pin(inspectorStack, to: inspector, insets: NSEdgeInsets(top: 18, left: 17, bottom: 18, right: 17), bottom: false)
        inspectorStack.addArrangedSubview(label("Clip settings", size: 14, weight: .semibold))
        inspectorStack.addArrangedSubview(rule())
        inspectorStack.addArrangedSubview(label("Selection", size: 12, weight: .medium, color: .secondaryLabelColor))
        let inButton = NSButton(title: "Set In", target: self, action: #selector(setIn))
        let outButton = NSButton(title: "Set Out", target: self, action: #selector(setOut))
        inButton.toolTip = "Set selection start at playhead"
        outButton.toolTip = "Set selection end at playhead"
        inspectorStack.addArrangedSubview(inspectorField("In", value: inTimeLabel, button: inButton))
        inspectorStack.addArrangedSubview(inspectorField("Out", value: outTimeLabel, button: outButton))
        let fullButton = NSButton(title: "Select full clip", target: self, action: #selector(selectEntireClip))
        fullButton.bezelStyle = .inline
        fullButton.contentTintColor = teal
        inspectorStack.addArrangedSubview(fullButton)
        inspectorStack.addArrangedSubview(rule())
        inspectorStack.addArrangedSubview(label("Playback speed", size: 12, weight: .medium, color: .secondaryLabelColor))
        for rate in [0.5, 1.0, 1.5, 2.0] {
            ratePopup.addItem(withTitle: "\(rate.formatted())×")
            ratePopup.lastItem?.tag = Int(rate * 100)
        }
        ratePopup.selectItem(withTag: 100)
        ratePopup.target = self
        ratePopup.action = #selector(rateChanged)
        ratePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        inspectorStack.addArrangedSubview(ratePopup)
        ratePopup.widthAnchor.constraint(equalTo: inspectorStack.widthAnchor).isActive = true
        inspectorStack.addArrangedSubview(rule())
        muteButton.target = self
        muteButton.action = #selector(muteChanged)
        inspectorStack.addArrangedSubview(muteButton)
        NSLayoutConstraint.activate([
            stage.leadingAnchor.constraint(equalTo: workArea.leadingAnchor, constant: 18),
            stage.topAnchor.constraint(equalTo: workArea.topAnchor, constant: 18),
            stage.bottomAnchor.constraint(equalTo: workArea.bottomAnchor, constant: -18),
            inspector.leadingAnchor.constraint(equalTo: stage.trailingAnchor, constant: 16),
            inspector.trailingAnchor.constraint(equalTo: workArea.trailingAnchor, constant: -18),
            inspector.topAnchor.constraint(equalTo: stage.topAnchor),
            inspector.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            inspector.widthAnchor.constraint(equalToConstant: 242),
            stage.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
        root.addArrangedSubview(workArea)

        let transport = NSView()
        transport.wantsLayer = true
        transport.layer?.backgroundColor = surface.cgColor
        transport.heightAnchor.constraint(equalToConstant: 54).isActive = true
        let transportRow = row(spacing: 12)
        pin(transportRow, to: transport, insets: NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 22))
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        timeLabel.textColor = teal
        timeLabel.alignment = .right
        timeLabel.widthAnchor.constraint(equalToConstant: 63).isActive = true
        transportRow.addArrangedSubview(timeLabel)
        configure(playButton, action: #selector(togglePlayback), symbol: "play.fill", help: "Play or pause")
        playButton.bezelStyle = .circular
        playButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        playButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        transportRow.addArrangedSubview(playButton)
        seekSlider.minValue = 0
        seekSlider.maxValue = 1
        seekSlider.target = self
        seekSlider.action = #selector(seekChanged)
        seekSlider.isContinuous = true
        transportRow.addArrangedSubview(seekSlider)
        seekSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        durationLabel.textColor = .secondaryLabelColor
        durationLabel.widthAnchor.constraint(equalToConstant: 63).isActive = true
        transportRow.addArrangedSubview(durationLabel)
        root.addArrangedSubview(transport)

        let timelinePanel = NSView()
        timelinePanel.wantsLayer = true
        timelinePanel.layer?.backgroundColor = NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1).cgColor
        timelinePanel.heightAnchor.constraint(equalToConstant: 190).isActive = true
        let timelineStack = NSStackView()
        timelineStack.orientation = .vertical
        timelineStack.spacing = 8
        pin(timelineStack, to: timelinePanel, insets: NSEdgeInsets(top: 12, left: 20, bottom: 10, right: 20))
        let timelineHeader = row(spacing: 8)
        timelineHeader.addArrangedSubview(label("Timeline", size: 13, weight: .semibold))
        timelineHeader.addArrangedSubview(flexibleSpace())
        selectionLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        selectionLabel.textColor = .secondaryLabelColor
        timelineHeader.addArrangedSubview(selectionLabel)
        timelineStack.addArrangedSubview(timelineHeader)
        timeline.translatesAutoresizingMaskIntoConstraints = false
        timeline.heightAnchor.constraint(equalToConstant: 95).isActive = true
        timeline.onSelect = { [weak self] start, end in self?.setSelection(start...end) }
        timeline.onSeek = { [weak self] time in self?.seek(to: time) }
        timelineStack.addArrangedSubview(timeline)
        let edits = row(spacing: 8)
        configure(trimButton, action: #selector(trimSelection), symbol: "crop", help: "Keep the selected range")
        configure(cutButton, action: #selector(cutSelection), symbol: "scissors", help: "Remove the selected range")
        configure(splitButton, action: #selector(splitAtPlayhead), symbol: "rectangle.split.2x1", help: "Split at playhead")
        [trimButton, cutButton, splitButton].forEach(edits.addArrangedSubview)
        edits.addArrangedSubview(flexibleSpace())
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        edits.addArrangedSubview(statusLabel)
        timelineStack.addArrangedSubview(edits)
        root.addArrangedSubview(timelinePanel)

        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            Task { @MainActor in self?.updatePlayhead(time.seconds) }
        }
        updateControls()
    }

    private func row(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func pin(_ child: NSView, to parent: NSView, insets: NSEdgeInsets, bottom: Bool = true) {
        child.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(child)
        var constraints = [
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top)
        ]
        if bottom { constraints.append(child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom)) }
        NSLayoutConstraint.activate(constraints)
    }

    private func flexibleSpace() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 4).isActive = true
        return view
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func rule() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        box.widthAnchor.constraint(equalToConstant: 208).isActive = true
        return box
    }

    private func inspectorField(_ name: String, value: NSTextField, button: NSButton) -> NSStackView {
        let stack = row(spacing: 8)
        let nameLabel = label(name, size: 12, weight: .regular, color: .secondaryLabelColor)
        nameLabel.widthAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(nameLabel)
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        stack.addArrangedSubview(value)
        stack.addArrangedSubview(flexibleSpace())
        button.bezelStyle = .inline
        button.contentTintColor = teal
        stack.addArrangedSubview(button)
        return stack
    }

    private func configure(_ button: NSButton, action: Selector, symbol: String, help: String) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.imagePosition = button.title.isEmpty ? .imageOnly : .imageLeading
        button.toolTip = help
        button.setAccessibilityLabel(help)
    }

    private func loadRecording() async {
        do {
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration >= 0.05 else { throw VideoEditError.invalidDuration }
            plan = VideoEditPlan(duration: duration)
            loaded = true
            setSelection(0...duration)
            await rebuildPreview()
            statusLabel.stringValue = "Drag to select  ·  Click to seek"
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    private func loadThumbnails(for editedAsset: AVAsset, duration: Double, generation: Int) {
        guard duration.isFinite, duration > 0 else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let generator = AVAssetImageGenerator(asset: editedAsset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 220, height: 130)
            let images: [NSImage] = (0..<12).compactMap { index in
                let time = CMTime(seconds: duration * (Double(index) + 0.5) / 12, preferredTimescale: 600)
                guard let image = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
                return NSImage(cgImage: image, size: .zero)
            }
            DispatchQueue.main.async {
                guard let self, self.previewGeneration == generation else { return }
                self.timeline.thumbnails = images
            }
        }
    }

    private func rebuildPreview() async {
        previewGeneration += 1
        let generation = previewGeneration
        player.pause()
        do {
            let composition = try await VideoEditExporter.composition(asset: asset, plan: plan)
            guard generation == previewGeneration else { return }
            // AVMutableComposition is not thread-safe; the player (main) and the
            // thumbnail generator (background) each get their own immutable copy.
            player.replaceCurrentItem(with: AVPlayerItem(asset: composition.copy() as! AVComposition))
            player.pause()
            player.isMuted = plan.muted
            seek(to: 0)
            updateControls()
            loadThumbnails(for: composition.copy() as! AVComposition, duration: plan.duration, generation: generation)
        } catch { statusLabel.stringValue = error.localizedDescription }
    }

    private func setSelection(_ range: ClosedRange<Double>) {
        let start = max(0, min(plan.duration, range.lowerBound))
        let end = max(start, min(plan.duration, range.upperBound))
        selection = start...end
        timeline.duration = max(plan.duration, 0.001)
        timeline.selection = selection
        inTimeLabel.stringValue = format(start)
        outTimeLabel.stringValue = format(end)
        selectionLabel.stringValue = start <= 0.01 && end >= plan.duration - 0.01
            ? "Full clip selected" : "Selected \(format(start))–\(format(end))"
        updateControls()
    }

    private func updateControls() {
        seekSlider.maxValue = max(plan.duration, 0.001)
        timeline.duration = max(plan.duration, 0.001)
        var elapsed = 0.0
        timeline.segmentBoundaries = plan.segments.dropLast().map { segment in
            elapsed += segment.duration
            return elapsed / plan.rate
        }
        let usable = loaded && selection.upperBound - selection.lowerBound >= 0.05 && !exporting
        trimButton.isEnabled = usable
        cutButton.isEnabled = usable && plan.duration - (selection.upperBound - selection.lowerBound) >= 0.05
        splitButton.isEnabled = loaded && !exporting && seekSlider.doubleValue > 0.05
            && seekSlider.doubleValue < plan.duration - 0.05
        undoButton.isEnabled = !undoStack.isEmpty && !exporting
        redoButton.isEnabled = !redoStack.isEmpty && !exporting
        exportButton.isEnabled = loaded && !exporting
        ratePopup.isEnabled = loaded && !exporting
        muteButton.isEnabled = loaded && !exporting
        playButton.isEnabled = loaded
        timeLabel.stringValue = format(player.currentTime().seconds)
        durationLabel.stringValue = format(plan.duration)
    }

    private func updatePlayhead(_ seconds: Double) {
        guard loaded, seconds.isFinite else { return }
        let time = min(plan.duration, max(0, seconds))
        seekSlider.doubleValue = time
        timeline.playhead = time
        timeLabel.stringValue = format(time)
        if time >= plan.duration - 0.01 && player.rate != 0 { player.pause() }
        playButton.image = NSImage(systemSymbolName: player.rate == 0 ? "play.fill" : "pause.fill", accessibilityDescription: "Play or pause")
        splitButton.isEnabled = !exporting && time > 0.05 && time < plan.duration - 0.05
    }

    private func format(_ time: Double) -> String {
        guard time.isFinite else { return "00:00.0" }
        let tenths = Int((max(0, time) * 10).rounded())
        return String(format: "%02d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }

    private func seek(to seconds: Double) {
        let clamped = min(plan.duration, max(0, seconds))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        updatePlayhead(clamped)
    }

    @objc private func togglePlayback() {
        if player.rate == 0 {
            if player.currentTime().seconds >= plan.duration - 0.05 { seek(to: 0) }
            player.play()
        } else { player.pause() }
        playButton.image = NSImage(systemSymbolName: player.rate == 0 ? "play.fill" : "pause.fill", accessibilityDescription: "Play or pause")
    }

    @objc private func seekChanged() { seek(to: seekSlider.doubleValue) }
    @objc private func setIn() { setSelection(min(seekSlider.doubleValue, selection.upperBound)...selection.upperBound) }
    @objc private func setOut() { setSelection(selection.lowerBound...max(seekSlider.doubleValue, selection.lowerBound)) }
    @objc private func selectEntireClip() { setSelection(0...plan.duration) }

    private func apply(_ change: (inout VideoEditPlan) -> Void) {
        guard loaded, !exporting else { return }
        let old = plan
        change(&plan)
        guard old != plan else { return }
        undoStack.append(old)
        redoStack.removeAll()
        setSelection(0...plan.duration)
        Task { await rebuildPreview() }
    }

    @objc private func trimSelection() {
        let range = selection
        apply { $0.trim(from: range.lowerBound, to: range.upperBound) }
    }

    @objc private func cutSelection() {
        let range = selection
        apply { $0.cut(from: range.lowerBound, to: range.upperBound) }
    }

    @objc private func splitAtPlayhead() {
        let time = seekSlider.doubleValue
        apply { $0.split(at: time) }
    }

    @objc private func rateChanged() {
        let rate = Double(ratePopup.selectedItem?.tag ?? 100) / 100
        apply { $0.rate = rate }
    }

    @objc private func muteChanged() {
        let muted = muteButton.state == .on
        apply { $0.muted = muted }
        player.isMuted = muted
    }

    @objc private func undoEdit() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(plan)
        plan = previous
        muteButton.state = plan.muted ? .on : .off
        ratePopup.selectItem(withTag: Int(plan.rate * 100))
        setSelection(0...plan.duration)
        Task { await rebuildPreview() }
    }

    @objc private func redoEdit() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(plan)
        plan = next
        muteButton.state = plan.muted ? .on : .off
        ratePopup.selectItem(withTag: Int(plan.rate * 100))
        setSelection(0...plan.duration)
        Task { await rebuildPreview() }
    }

    @objc private func exportVideo() {
        guard loaded, !exporting, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.directoryURL = SettingsStore.shared.saveDirectory
        panel.nameFieldStringValue = "Edited \(sourceURL.deletingPathExtension().lastPathComponent).mp4"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in await self?.save(to: url) }
        }
    }

    private func save(to url: URL) async {
        guard url.standardizedFileURL != sourceURL.standardizedFileURL else {
            statusLabel.stringValue = "Choose a new file name to preserve the original recording."
            return
        }
        exporting = true
        statusLabel.stringValue = "Exporting edited MP4…"
        updateControls()
        do {
            try await VideoEditExporter.export(asset: asset, plan: plan, to: url)
            capture.fileURL = url
            capture.image = VideoEditExporter.poster(for: url) ?? capture.image
            CaptureStore.shared.updateLatestRecording(url)
            CaptureStore.shared.copyToPasteboard(capture)
            NotificationCenter.default.post(name: CaptureStore.didChange, object: nil)
            window?.title = "ImageSmith — \(url.lastPathComponent)"
            fileLabel.stringValue = url.lastPathComponent
            statusLabel.stringValue = "Saved \(url.lastPathComponent) and copied its file to the clipboard."
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
        exporting = false
        updateControls()
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        onClose?(self)
    }
}
