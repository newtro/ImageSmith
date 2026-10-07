import AppKit

protocol CanvasViewDelegate: AnyObject {
    func canvasDidChangeAnnotations(_ canvas: CanvasView)
    func canvasDidChangeSelection(_ canvas: CanvasView)
    func canvasRequestsCrop(_ canvas: CanvasView, rect: CGRect)
    func canvasDidPickColor(_ canvas: CanvasView, color: NSColor)
    /// ⌃-wheel or a trackpad pinch: `factor` multiplies the zoom, anchored at `viewPoint`
    /// (canvas coordinates) so the pixel under the pointer stays put.
    func canvasRequestsZoom(_ canvas: CanvasView, factor: CGFloat, at viewPoint: NSPoint)
    /// Middle-button drag: move the visible area by `delta` in canvas points.
    func canvasRequestsPan(_ canvas: CanvasView, by delta: NSPoint)
}

/// The interactive drawing surface. Its frame is `imageSize * zoom`; all annotation
/// geometry lives in image point space with a top-left origin.
final class CanvasView: NSView {
    weak var delegate: CanvasViewDelegate?

    private(set) var baseImage: NSImage
    private(set) var obscure: ObscureSource
    var annotations: [Annotation] = [] { didSet { needsDisplay = true } }

    var currentTool: ToolKind = .arrow {
        didSet {
            if currentTool != .select { selection = nil }
            cropRect = nil
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var currentColor: NSColor = .systemRed
    var currentStrokeWidth: CGFloat = 4
    var currentFontSize: CGFloat = 28
    var fillShapes = false
    var nextStepNumber = 1

    var zoom: CGFloat = 1 { didSet { resizeToImage() } }

    private(set) var selection: Annotation? {
        didSet { delegate?.canvasDidChangeSelection(self); needsDisplay = true }
    }
    private var draft: Annotation?
    private var dragMode: DragMode = .none
    private var dragOrigin: CGPoint = .zero
    private var dragStartGeometry: (CGPoint, CGPoint)?
    private var activeHandle: Annotation.Handle?
    private(set) var cropRect: CGRect?
    private var textEditor: NSTextField?
    private var editingAnnotation: Annotation?

    private enum DragMode { case none, creating, moving, resizing, cropping }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(image: NSImage) {
        self.baseImage = image
        self.obscure = ObscureSource(base: image)
        super.init(frame: CGRect(origin: .zero, size: image.size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    // MARK: Image lifecycle

    func replaceImage(_ image: NSImage) {
        baseImage = image
        obscure = ObscureSource(base: image)
        resizeToImage()
        needsDisplay = true
    }

    func resizeToImage() {
        setFrameSize(NSSize(width: baseImage.size.width * zoom,
                            height: baseImage.size.height * zoom))
        needsDisplay = true
    }

    var imageSize: CGSize { baseImage.size }

    // MARK: Coordinate conversion

    func imagePoint(from viewPoint: NSPoint) -> CGPoint {
        CGPoint(x: viewPoint.x / zoom, y: viewPoint.y / zoom)
    }

    func viewPoint(from imagePoint: CGPoint) -> NSPoint {
        NSPoint(x: imagePoint.x * zoom, y: imagePoint.y * zoom)
    }

    func viewRect(from imageRect: CGRect) -> NSRect {
        NSRect(x: imageRect.minX * zoom, y: imageRect.minY * zoom,
               width: imageRect.width * zoom, height: imageRect.height * zoom)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.12, alpha: 1).setFill()
        dirtyRect.fill()

        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        ctx.cgContext.scaleBy(x: zoom, y: zoom)
        ctx.imageInterpolation = zoom > 1.5 ? .none : .high

        baseImage.draw(in: CGRect(origin: .zero, size: imageSize))
        var toDraw = annotations
        if let draft { toDraw.append(draft) }
        AnnotationRenderer.draw(toDraw, imageSize: imageSize, obscure: obscure)
        ctx.restoreGraphicsState()

        if let crop = cropRect { drawCropOverlay(crop) }
        if let sel = selection, textEditor == nil { drawSelection(sel) }
    }

    private func drawSelection(_ a: Annotation) {
        let r = viewRect(from: a.bounds).insetBy(dx: -3, dy: -3)
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: r)
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.stroke()

        for (_, p) in a.handles() {
            let v = viewPoint(from: p)
            let box = NSRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8)
            NSColor.white.setFill()
            NSBezierPath(ovalIn: box).fill()
            NSColor.controlAccentColor.setStroke()
            let ring = NSBezierPath(ovalIn: box)
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }

    private func drawCropOverlay(_ rect: CGRect) {
        let full = NSBezierPath(rect: bounds)
        full.append(NSBezierPath(rect: viewRect(from: rect)).reversed)
        full.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        full.fill()

        NSColor.white.setStroke()
        let outline = NSBezierPath(rect: viewRect(from: rect))
        outline.lineWidth = 1
        outline.stroke()

        let label = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))  ⏎ to crop" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let vr = viewRect(from: rect)
        let size = label.size(withAttributes: attrs)
        let bg = NSRect(x: vr.minX, y: max(0, vr.minY - size.height - 6),
                        width: size.width + 10, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        label.draw(at: NSPoint(x: bg.minX + 5, y: bg.minY + 2), withAttributes: attrs)
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch currentTool {
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        case .crop: cursor = .crosshair
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitTextEditing()

        let p = imagePoint(from: convert(event.locationInWindow, from: nil))
        dragOrigin = p

        if event.modifierFlags.contains(.command) || currentTool == .select {
            if handleSelectionMouseDown(at: p) { return }
        }

        switch currentTool {
        case .select:
            selection = nil
            dragMode = .none

        case .crop:
            cropRect = CGRect(origin: p, size: .zero)
            dragMode = .cropping

        case .text:
            let a = makeAnnotation(kind: .text, at: p)
            a.fontSize = currentFontSize
            annotations.append(a)
            selection = a
            beginTextEditing(a)
            dragMode = .none
            delegate?.canvasDidChangeAnnotations(self)

        case .step:
            let a = makeAnnotation(kind: .step, at: p)
            a.fontSize = currentFontSize
            a.stepNumber = nextStepNumber
            nextStepNumber += 1
            annotations.append(a)
            selection = a
            dragMode = .none
            delegate?.canvasDidChangeAnnotations(self)

        default:
            let a = makeAnnotation(kind: currentTool, at: p)
            if currentTool == .pen || currentTool == .highlighter { a.points = [p] }
            draft = a
            dragMode = .creating
        }
        needsDisplay = true
    }

    private func handleSelectionMouseDown(at p: CGPoint) -> Bool {
        let tol = 8 / zoom
        if let sel = selection {
            for (handle, hp) in sel.handles() where hypot(hp.x - p.x, hp.y - p.y) <= tol {
                activeHandle = handle
                dragMode = .resizing
                dragStartGeometry = (sel.start, sel.end)
                return true
            }
        }
        if let hit = annotations.reversed().first(where: { $0.hitTest(p, tolerance: tol) }) {
            selection = hit
            dragMode = .moving
            dragStartGeometry = (hit.start, hit.end)
            return true
        }
        return false
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(from: convert(event.locationInWindow, from: nil))
        let shift = event.modifierFlags.contains(.shift)

        switch dragMode {
        case .creating:
            guard let draft else { return }
            if draft.kind == .pen || draft.kind == .highlighter {
                draft.points.append(p)
            } else {
                draft.end = shift ? constrain(from: draft.start, to: p) : p
            }
            needsDisplay = true

        case .moving:
            guard let sel = selection else { return }
            sel.translate(by: CGPoint(x: p.x - dragOrigin.x, y: p.y - dragOrigin.y))
            dragOrigin = p
            needsDisplay = true

        case .resizing:
            guard let sel = selection, let handle = activeHandle else { return }
            sel.resize(handle: handle, to: p)
            needsDisplay = true

        case .cropping:
            cropRect = CGRect(x: min(dragOrigin.x, p.x), y: min(dragOrigin.y, p.y),
                              width: abs(p.x - dragOrigin.x), height: abs(p.y - dragOrigin.y))
                .intersection(CGRect(origin: .zero, size: imageSize))
            needsDisplay = true

        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        switch dragMode {
        case .creating:
            if let draft, !draft.isDegenerate {
                addAnnotation(draft)
                if currentTool != .pen && currentTool != .highlighter {
                    selection = nil
                }
            }
            draft = nil

        case .moving, .resizing:
            delegate?.canvasDidChangeAnnotations(self)

        case .cropping, .none:
            break
        }
        dragMode = .none
        activeHandle = nil
        needsDisplay = true
    }

    /// Shift-drag constrains lines to 15° increments and boxes to squares.
    private func constrain(from a: CGPoint, to b: CGPoint) -> CGPoint {
        switch currentTool {
        case .line, .arrow:
            let angle = atan2(b.y - a.y, b.x - a.x)
            let step = CGFloat.pi / 12
            let snapped = (angle / step).rounded() * step
            let r = hypot(b.x - a.x, b.y - a.y)
            return CGPoint(x: a.x + cos(snapped) * r, y: a.y + sin(snapped) * r)
        default:
            let side = max(abs(b.x - a.x), abs(b.y - a.y))
            return CGPoint(x: a.x + (b.x < a.x ? -side : side),
                           y: a.y + (b.y < a.y ? -side : side))
        }
    }

    private func makeAnnotation(kind: ToolKind, at p: CGPoint) -> Annotation {
        let a = Annotation(kind: kind, start: p, end: p,
                           color: kind == .redact ? .black : currentColor,
                           strokeWidth: currentStrokeWidth)
        a.filled = fillShapes
        a.fontSize = currentFontSize
        return a
    }

    // MARK: Mutation with undo

    func addAnnotation(_ a: Annotation) {
        annotations.append(a)
        undoManager?.registerUndo(withTarget: self) { $0.removeAnnotation(a) }
        undoManager?.setActionName("Add \(a.kind.title)")
        delegate?.canvasDidChangeAnnotations(self)
    }

    func removeAnnotation(_ a: Annotation) {
        guard let idx = annotations.firstIndex(where: { $0 === a }) else { return }
        annotations.remove(at: idx)
        if selection === a { selection = nil }
        undoManager?.registerUndo(withTarget: self) { $0.insertAnnotation(a, at: idx) }
        undoManager?.setActionName("Delete \(a.kind.title)")
        delegate?.canvasDidChangeAnnotations(self)
    }

    func insertAnnotation(_ a: Annotation, at index: Int) {
        annotations.insert(a, at: min(index, annotations.count))
        undoManager?.registerUndo(withTarget: self) { $0.removeAnnotation(a) }
        delegate?.canvasDidChangeAnnotations(self)
    }

    func deleteSelection() {
        guard let sel = selection else { return }
        removeAnnotation(sel)
    }

    func duplicateSelection() {
        guard let sel = selection else { return }
        let copy = sel.copy()
        copy.translate(by: CGPoint(x: 16, y: 16))
        addAnnotation(copy)
        selection = copy
    }

    func clearAll() {
        let old = annotations
        annotations = []
        selection = nil
        undoManager?.registerUndo(withTarget: self) { target in
            target.annotations = old
            target.delegate?.canvasDidChangeAnnotations(target)
        }
        undoManager?.setActionName("Clear Annotations")
        delegate?.canvasDidChangeAnnotations(self)
    }

    func applyStyleToSelection() {
        guard let sel = selection else { return }
        if sel.kind.usesColor && sel.kind != .redact { sel.color = currentColor }
        sel.strokeWidth = currentStrokeWidth
        sel.fontSize = currentFontSize
        sel.filled = fillShapes
        needsDisplay = true
        delegate?.canvasDidChangeAnnotations(self)
    }

    func select(_ a: Annotation?) { selection = a }

    // MARK: Crop

    func confirmCrop() {
        guard let rect = cropRect, rect.width > 4, rect.height > 4 else { return }
        cropRect = nil
        delegate?.canvasRequestsCrop(self, rect: rect)
    }

    func cancelCrop() {
        cropRect = nil
        needsDisplay = true
    }

    func offsetAllAnnotations(by delta: CGPoint) {
        for a in annotations { a.translate(by: delta) }
    }

    // MARK: Text editing

    private func beginTextEditing(_ a: Annotation) {
        let field = NSTextField(frame: .zero)
        field.stringValue = a.text
        field.font = NSFont.systemFont(ofSize: max(11, a.fontSize * zoom), weight: .semibold)
        field.textColor = a.color
        field.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        field.drawsBackground = true
        field.isBordered = false
        field.focusRingType = .none
        field.target = self
        field.action = #selector(textFieldCommitted(_:))
        field.delegate = self

        let origin = viewPoint(from: a.start)
        let width = max(180, a.textSize().width * zoom)
        field.frame = NSRect(x: origin.x, y: origin.y,
                             width: width, height: max(20, a.fontSize * zoom + 8))
        addSubview(field)
        window?.makeFirstResponder(field)
        textEditor = field
        editingAnnotation = a
    }

    @objc private func textFieldCommitted(_ sender: NSTextField) {
        commitTextEditing()
    }

    func commitTextEditing() {
        guard let field = textEditor, let a = editingAnnotation else { return }
        a.text = field.stringValue
        field.removeFromSuperview()
        textEditor = nil
        editingAnnotation = nil
        if a.text.isEmpty {
            if let idx = annotations.firstIndex(where: { $0 === a }) { annotations.remove(at: idx) }
            selection = nil
        } else {
            undoManager?.registerUndo(withTarget: self) { $0.removeAnnotation(a) }
            undoManager?.setActionName("Add Text")
        }
        delegate?.canvasDidChangeAnnotations(self)
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    var isEditingText: Bool { textEditor != nil }

    // MARK: Colour sampling

    func colorAt(viewPoint p: NSPoint) -> NSColor? {
        let img = imagePoint(from: p)
        guard let rep = baseImage.representations.first as? NSBitmapImageRep else { return nil }
        let sx = CGFloat(rep.pixelsWide) / imageSize.width
        let sy = CGFloat(rep.pixelsHigh) / imageSize.height
        let x = Int(img.x * sx), y = Int(img.y * sy)
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
        return rep.colorAt(x: x, y: y)
    }

    // MARK: Zoom and pan gestures

    /// ⌃ + scroll wheel zooms about the pointer; plain scrolling still scrolls.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.control) else { super.scrollWheel(with: event); return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 40 : event.scrollingDeltaY / 3
        guard delta != 0 else { return }
        let factor = pow(1.25, min(1, max(-1, delta)))
        delegate?.canvasRequestsZoom(self, factor: factor, at: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        guard event.magnification != 0 else { return }
        delegate?.canvasRequestsZoom(self, factor: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    }

    private var panLastWindowPoint: NSPoint?

    /// Middle button (button 2) drags the view around.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        panLastWindowPoint = event.locationInWindow
        NSCursor.closedHand.push()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2, let last = panLastWindowPoint else { super.otherMouseDragged(with: event); return }
        let now = event.locationInWindow
        // Window coordinates are unflipped; the canvas is flipped, so invert y.
        delegate?.canvasRequestsPan(self, by: NSPoint(x: now.x - last.x, y: -(now.y - last.y)))
        panLastWindowPoint = now
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseUp(with: event); return }
        panLastWindowPoint = nil
        NSCursor.pop()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // delete / forward delete
            deleteSelection()
        case 53: // escape — cancel the crop, then drop the selection, then bubble up
            if cropRect != nil { cancelCrop() }
            else if selection != nil { selection = nil }
            else { super.keyDown(with: event) }
        case 36, 76: // return / enter
            if cropRect != nil { confirmCrop() } else { super.keyDown(with: event) }
        case 123: nudge(dx: -1, dy: 0, event: event)
        case 124: nudge(dx: 1, dy: 0, event: event)
        case 125: nudge(dx: 0, dy: 1, event: event)
        case 126: nudge(dx: 0, dy: -1, event: event)
        default:
            super.keyDown(with: event)
        }
    }

    private func nudge(dx: CGFloat, dy: CGFloat, event: NSEvent) {
        guard let sel = selection else { super.keyDown(with: event); return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        sel.translate(by: CGPoint(x: dx * step, y: dy * step))
        needsDisplay = true
        delegate?.canvasDidChangeAnnotations(self)
    }
}

extension CanvasView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextEditing()
    }
}
