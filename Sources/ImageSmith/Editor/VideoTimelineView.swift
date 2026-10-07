import AppKit

/// Filmstrip timeline. Drag a range to select it; click to move the playhead.
final class VideoTimelineView: NSView {
    var duration: Double = 1 { didSet { needsDisplay = true } }
    var selection: ClosedRange<Double> = 0...1 { didSet { needsDisplay = true } }
    var playhead: Double = 0 { didSet { needsDisplay = true } }
    var segmentBoundaries: [Double] = [] { didSet { needsDisplay = true } }
    var thumbnails: [NSImage] = [] { didSet { needsDisplay = true } }
    var onSelect: ((Double, Double) -> Void)?
    var onSeek: ((Double) -> Void)?
    private var dragStart: CGFloat?
    private let accent = NSColor(srgbRed: 0.29, green: 0.78, blue: 0.80, alpha: 1)

    override var isFlipped: Bool { true }

    private var track: NSRect { NSRect(x: 8, y: 22, width: max(1, bounds.width - 16), height: max(1, bounds.height - 37)) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = track
        NSColor(srgbRed: 0.07, green: 0.08, blue: 0.09, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        if !thumbnails.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 3, yRadius: 3).addClip()
            let frameWidth = rect.width / CGFloat(thumbnails.count)
            for (index, image) in thumbnails.enumerated() {
                let frame = NSRect(x: rect.minX + CGFloat(index) * frameWidth, y: rect.minY,
                                   width: frameWidth + 1, height: rect.height)
                image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 0.85)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        let lower = x(for: selection.lowerBound, in: rect)
        let upper = x(for: selection.upperBound, in: rect)
        NSColor.black.withAlphaComponent(0.48).setFill()
        if lower > rect.minX { NSRect(x: rect.minX, y: rect.minY, width: lower - rect.minX, height: rect.height).fill() }
        if upper < rect.maxX { NSRect(x: upper, y: rect.minY, width: rect.maxX - upper, height: rect.height).fill() }
        accent.setStroke()
        let outline = NSBezierPath(roundedRect: NSRect(x: lower, y: rect.minY, width: max(2, upper - lower), height: rect.height), xRadius: 3, yRadius: 3)
        outline.lineWidth = 2
        outline.stroke()
        accent.setFill()
        for handle in [lower, upper] {
            NSBezierPath(roundedRect: NSRect(x: handle - 3, y: rect.midY - 10, width: 6, height: 20), xRadius: 3, yRadius: 3).fill()
        }
        NSColor.white.withAlphaComponent(0.65).setStroke()
        for boundary in segmentBoundaries {
            let x = x(for: boundary, in: rect)
            let path = NSBezierPath()
            path.lineWidth = 1.5
            path.move(to: NSPoint(x: x, y: rect.minY))
            path.line(to: NSPoint(x: x, y: rect.maxY))
            path.stroke()
        }
        let headX = x(for: playhead, in: rect)
        NSColor.systemOrange.setFill()
        NSRect(x: headX - 1, y: 7, width: 2, height: rect.maxY - 7 + 7).fill()
        let marker = NSBezierPath()
        marker.move(to: NSPoint(x: headX - 5, y: 7))
        marker.line(to: NSPoint(x: headX + 5, y: 7))
        marker.line(to: NSPoint(x: headX, y: 14))
        marker.close()
        marker.fill()
        let tickCount = min(10, max(1, Int(duration)), max(1, Int(rect.width / 85)))
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        for index in 0...tickCount {
            let fraction = Double(index) / Double(tickCount)
            let time = duration * fraction
            let seconds = Int(time.rounded())
            let text = String(format: "%02d:%02d", seconds / 60, seconds % 60) as NSString
            let x = rect.minX + rect.width * CGFloat(fraction)
            let textWidth = text.size(withAttributes: [.font: font]).width
            text.draw(at: NSPoint(x: min(rect.maxX - textWidth, max(rect.minX, x - textWidth / 2)), y: 0),
                      withAttributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    override func mouseDown(with event: NSEvent) { dragStart = convert(event.locationInWindow, from: nil).x }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil).x
        let a = time(for: start), b = time(for: end)
        onSelect?(min(a, b), max(a, b))
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        let end = convert(event.locationInWindow, from: nil).x
        if abs(end - start) < 3 { onSeek?(time(for: end)) }
        dragStart = nil
    }

    private func x(for time: Double, in rect: NSRect) -> CGFloat {
        rect.minX + rect.width * CGFloat(max(0, min(1, time / max(duration, 0.001))))
    }

    private func time(for x: CGFloat) -> Double {
        let rect = track
        return max(0, min(duration, Double((x - rect.minX) / max(rect.width, 1)) * duration))
    }
}
