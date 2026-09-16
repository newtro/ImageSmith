import AppKit

/// Lazily-built blurred / pixelated copies of the base image, used to fill
/// obscuring annotations without re-filtering on every redraw.
final class ObscureSource {
    private let base: NSImage
    private var blurCache: [Int: NSImage] = [:]
    private var pixelCache: [Int: NSImage] = [:]

    init(base: NSImage) { self.base = base }

    func blurred(radius: CGFloat) -> NSImage? {
        let key = Int(radius.rounded())
        if let c = blurCache[key] { return c }
        guard let cg = ImageUtilities.cgImage(from: base),
              let out = ImageUtilities.blurred(cg, radius: radius) else { return nil }
        let img = ImageUtilities.nsImage(from: out, scale: CGFloat(out.width) / base.size.width)
        img.size = base.size
        blurCache[key] = img
        return img
    }

    func pixelated(block: CGFloat) -> NSImage? {
        let key = Int(block.rounded())
        if let c = pixelCache[key] { return c }
        guard let cg = ImageUtilities.cgImage(from: base),
              let out = ImageUtilities.pixelated(cg, blockSize: block) else { return nil }
        let img = ImageUtilities.nsImage(from: out, scale: CGFloat(out.width) / base.size.width)
        img.size = base.size
        pixelCache[key] = img
        return img
    }

    func invalidate() {
        blurCache.removeAll()
        pixelCache.removeAll()
    }
}

enum AnnotationRenderer {

    /// Draws annotations into the *current* graphics context, which must already be
    /// flipped and scaled so that one unit equals one image point (top-left origin).
    static func draw(_ annotations: [Annotation],
                     imageSize: CGSize,
                     obscure: ObscureSource?) {
        for a in annotations {
            draw(a, imageSize: imageSize, obscure: obscure)
        }
    }

    static func draw(_ a: Annotation, imageSize: CGSize, obscure: ObscureSource?) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        defer { ctx.restoreGraphicsState() }

        switch a.kind {
        case .rectangle:
            let path = NSBezierPath(rect: a.bounds)
            path.lineWidth = a.strokeWidth
            if a.filled {
                a.color.withAlphaComponent(0.35).setFill()
                path.fill()
            }
            a.color.setStroke()
            path.stroke()

        case .ellipse:
            let path = NSBezierPath(ovalIn: a.bounds)
            path.lineWidth = a.strokeWidth
            if a.filled {
                a.color.withAlphaComponent(0.35).setFill()
                path.fill()
            }
            a.color.setStroke()
            path.stroke()

        case .line:
            let path = NSBezierPath()
            path.move(to: a.start)
            path.line(to: a.end)
            path.lineWidth = a.strokeWidth
            path.lineCapStyle = .round
            a.color.setStroke()
            path.stroke()

        case .arrow:
            drawArrow(from: a.start, to: a.end, width: a.strokeWidth, color: a.color)

        case .pen:
            let path = smoothPath(a.points)
            path.lineWidth = a.strokeWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            a.color.setStroke()
            path.stroke()

        case .highlighter:
            ctx.compositingOperation = .multiply
            let path = smoothPath(a.points)
            path.lineWidth = max(a.strokeWidth * 4, 16)
            path.lineCapStyle = .square
            path.lineJoinStyle = .round
            a.color.withAlphaComponent(0.4).setStroke()
            path.stroke()

        case .text:
            guard !a.text.isEmpty else { break }
            let s = a.text as NSString
            let box = CGRect(x: a.start.x + 4, y: a.start.y + 2,
                             width: a.textSize().width, height: a.textSize().height)
            s.draw(with: box, options: [.usesLineFragmentOrigin], attributes: a.attributes())

        case .step:
            let r = a.badgeRadius
            let rect = CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
            a.color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 3
            ring.stroke()
            let label = "\(a.stepNumber)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: r * 1.1, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                       withAttributes: attrs)

        case .blur:
            let rect = a.bounds
            guard let src = obscure?.blurred(radius: max(4, 12 * a.intensity)) else {
                NSColor.gray.setFill(); rect.fill(); break
            }
            NSBezierPath(rect: rect).setClip()
            src.draw(in: CGRect(origin: .zero, size: imageSize))

        case .pixelate:
            let rect = a.bounds
            guard let src = obscure?.pixelated(block: max(6, 14 * a.intensity)) else {
                NSColor.gray.setFill(); rect.fill(); break
            }
            NSBezierPath(rect: rect).setClip()
            src.draw(in: CGRect(origin: .zero, size: imageSize))

        case .redact:
            a.color.setFill()
            NSBezierPath(rect: a.bounds).fill()

        case .spotlight:
            let full = NSBezierPath(rect: CGRect(origin: .zero, size: imageSize))
            let hole = NSBezierPath(roundedRect: a.bounds, xRadius: 6, yRadius: 6)
            full.append(hole.reversed)
            full.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.55 * a.intensity).setFill()
            full.fill()

        case .select, .crop:
            break
        }
    }

    // MARK: Helpers

    static func drawArrow(from start: CGPoint, to end: CGPoint, width: CGFloat, color: NSColor) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return }
        let angle = atan2(dy, dx)

        let headLength = min(length * 0.45, max(width * 4.2, 14))
        let tailWidth = max(width * 0.9, 2)

        // Body stops where the head begins so the tip stays crisp.
        let bodyEnd = CGPoint(x: end.x - cos(angle) * headLength * 0.85,
                              y: end.y - sin(angle) * headLength * 0.85)

        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: bodyEnd)
        path.lineWidth = tailWidth * 2
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()

        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: CGPoint(x: end.x - cos(angle - .pi / 7) * headLength,
                              y: end.y - sin(angle - .pi / 7) * headLength))
        head.line(to: CGPoint(x: end.x - cos(angle) * headLength * 0.72,
                              y: end.y - sin(angle) * headLength * 0.72))
        head.line(to: CGPoint(x: end.x - cos(angle + .pi / 7) * headLength,
                              y: end.y - sin(angle + .pi / 7) * headLength))
        head.close()
        color.setFill()
        head.fill()
    }

    /// Catmull-Rom-ish smoothing so freehand strokes do not look like polylines.
    static func smoothPath(_ pts: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count < 3 {
            for p in pts.dropFirst() { path.line(to: p) }
            return path
        }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2,
                              y: (pts[i].y + pts[i + 1].y) / 2)
            path.curve(to: mid, controlPoint1: pts[i], controlPoint2: pts[i])
        }
        path.line(to: pts[pts.count - 1])
        return path
    }

    /// Flattens the base image plus annotations into a new NSImage, preserving the
    /// original pixel resolution.
    static func flatten(base: NSImage, annotations: [Annotation], obscure: ObscureSource?) -> NSImage {
        let pointSize = base.size
        let pixels = ImageUtilities.pixelSize(of: base)
        let out = ImageUtilities.renderBitmap(pointSize: pointSize, pixelSize: pixels) {
            base.draw(in: CGRect(origin: .zero, size: pointSize))
            draw(annotations, imageSize: pointSize, obscure: obscure)
        }
        return out ?? base
    }
}
