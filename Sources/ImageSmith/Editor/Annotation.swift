import AppKit

enum ToolKind: String, CaseIterable {
    case select
    case arrow
    case rectangle
    case ellipse
    case line
    case pen
    case highlighter
    case text
    case step
    case blur
    case pixelate
    case redact
    case spotlight
    case crop

    var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .line: return "Line"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .text: return "Text"
        case .step: return "Step number"
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .redact: return "Redact"
        case .spotlight: return "Spotlight"
        case .crop: return "Crop"
        }
    }

    /// Single-key shortcut shown in the toolbar tooltip.
    var shortcut: String {
        switch self {
        case .select: return "V"
        case .arrow: return "A"
        case .rectangle: return "R"
        case .ellipse: return "E"
        case .line: return "L"
        case .pen: return "P"
        case .highlighter: return "H"
        case .text: return "T"
        case .step: return "N"
        case .blur: return "B"
        case .pixelate: return "X"
        case .redact: return "D"
        case .spotlight: return "S"
        case .crop: return "C"
        }
    }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .step: return "1.circle.fill"
        case .blur: return "drop.fill"
        case .pixelate: return "squareshape.split.3x3"
        case .redact: return "rectangle.fill"
        case .spotlight: return "circle.dashed"
        case .crop: return "crop"
        }
    }

    var usesStroke: Bool {
        switch self {
        case .arrow, .rectangle, .ellipse, .line, .pen, .highlighter: return true
        default: return false
        }
    }

    var usesColor: Bool {
        switch self {
        case .blur, .pixelate, .crop, .select, .spotlight: return false
        default: return true
        }
    }

    var isObscuring: Bool {
        switch self {
        case .blur, .pixelate, .redact: return true
        default: return false
        }
    }
}

/// A single mark on the canvas. Geometry is stored in *image point space* with a
/// top-left origin, so it survives zooming and exports unchanged.
final class Annotation {
    let id = UUID()
    var kind: ToolKind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []          // pen / highlighter
    var color: NSColor
    var strokeWidth: CGFloat
    var filled: Bool = false
    var text: String = ""
    var fontSize: CGFloat = 28
    var stepNumber: Int = 1
    var intensity: CGFloat = 1          // blur radius / pixel block multiplier

    init(kind: ToolKind, start: CGPoint, end: CGPoint, color: NSColor, strokeWidth: CGFloat) {
        self.kind = kind
        self.start = start
        self.end = end
        self.color = color
        self.strokeWidth = strokeWidth
    }

    var bounds: CGRect {
        switch kind {
        case .pen, .highlighter:
            guard let first = points.first else { return .zero }
            var r = CGRect(origin: first, size: .zero)
            for p in points.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -strokeWidth, dy: -strokeWidth)
        case .text:
            let size = textSize()
            return CGRect(x: start.x, y: start.y, width: size.width, height: size.height)
        case .step:
            let r = badgeRadius
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        default:
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        }
    }

    var badgeRadius: CGFloat { max(14, fontSize * 0.85) }

    var isDegenerate: Bool {
        switch kind {
        case .pen, .highlighter: return points.count < 2
        case .text: return text.isEmpty
        case .step: return false
        default: return abs(end.x - start.x) < 3 && abs(end.y - start.y) < 3
        }
    }

    func translate(by delta: CGPoint) {
        start.x += delta.x; start.y += delta.y
        end.x += delta.x; end.y += delta.y
        for i in points.indices {
            points[i].x += delta.x
            points[i].y += delta.y
        }
    }

    func copy() -> Annotation {
        let a = Annotation(kind: kind, start: start, end: end, color: color, strokeWidth: strokeWidth)
        a.points = points
        a.filled = filled
        a.text = text
        a.fontSize = fontSize
        a.stepNumber = stepNumber
        a.intensity = intensity
        return a
    }

    // MARK: Text metrics

    func attributes() -> [NSAttributedString.Key: Any] {
        // A soft dark halo keeps light text readable over light screenshots.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = max(2, fontSize * 0.12)
        shadow.shadowOffset = .zero
        return [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: color,
                .shadow: shadow]
    }

    func textSize() -> CGSize {
        let s = (text.isEmpty ? " " : text) as NSString
        var size = s.boundingRect(with: CGSize(width: 10_000, height: 10_000),
                                  options: [.usesLineFragmentOrigin],
                                  attributes: attributes()).size
        size.width += 8
        size.height += 4
        return size
    }

    // MARK: Hit testing

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .pen, .highlighter:
            let t = max(tolerance, strokeWidth)
            for i in 0..<max(0, points.count - 1) {
                if Annotation.distance(from: p, toSegment: points[i], points[i + 1]) <= t { return true }
            }
            return false
        case .line, .arrow:
            return Annotation.distance(from: p, toSegment: start, end) <= max(tolerance, strokeWidth)
        case .ellipse:
            let b = bounds
            if filled { return b.insetBy(dx: -tolerance, dy: -tolerance).contains(p) }
            let outer = b.insetBy(dx: -tolerance, dy: -tolerance)
            let inner = b.insetBy(dx: tolerance + strokeWidth, dy: tolerance + strokeWidth)
            return Annotation.inEllipse(p, outer) && !Annotation.inEllipse(p, inner)
        case .rectangle:
            let b = bounds
            if filled { return b.insetBy(dx: -tolerance, dy: -tolerance).contains(p) }
            let outer = b.insetBy(dx: -tolerance - strokeWidth / 2, dy: -tolerance - strokeWidth / 2)
            let inner = b.insetBy(dx: tolerance + strokeWidth / 2, dy: tolerance + strokeWidth / 2)
            return outer.contains(p) && !inner.contains(p)
        default:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    static func inEllipse(_ p: CGPoint, _ r: CGRect) -> Bool {
        guard r.width > 0, r.height > 0 else { return false }
        let dx = (p.x - r.midX) / (r.width / 2)
        let dy = (p.y - r.midY) / (r.height / 2)
        return dx * dx + dy * dy <= 1
    }

    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSq = dx * dx + dy * dy
        if lengthSq == 0 { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSq
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: Resize handles

    enum Handle: Int, CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
        case startPoint, endPoint
    }

    /// Handles in image space for the current geometry.
    func handles() -> [(Handle, CGPoint)] {
        switch kind {
        case .line, .arrow:
            return [(.startPoint, start), (.endPoint, end)]
        case .pen, .highlighter, .step:
            return []
        default:
            let b = bounds
            return [
                (.topLeft, CGPoint(x: b.minX, y: b.minY)),
                (.top, CGPoint(x: b.midX, y: b.minY)),
                (.topRight, CGPoint(x: b.maxX, y: b.minY)),
                (.right, CGPoint(x: b.maxX, y: b.midY)),
                (.bottomRight, CGPoint(x: b.maxX, y: b.maxY)),
                (.bottom, CGPoint(x: b.midX, y: b.maxY)),
                (.bottomLeft, CGPoint(x: b.minX, y: b.maxY)),
                (.left, CGPoint(x: b.minX, y: b.midY))
            ]
        }
    }

    func resize(handle: Handle, to p: CGPoint) {
        switch handle {
        case .startPoint: start = p
        case .endPoint: end = p
        default:
            var b = bounds
            switch handle {
            case .topLeft: b = CGRect(x: p.x, y: p.y, width: b.maxX - p.x, height: b.maxY - p.y)
            case .top: b = CGRect(x: b.minX, y: p.y, width: b.width, height: b.maxY - p.y)
            case .topRight: b = CGRect(x: b.minX, y: p.y, width: p.x - b.minX, height: b.maxY - p.y)
            case .right: b = CGRect(x: b.minX, y: b.minY, width: p.x - b.minX, height: b.height)
            case .bottomRight: b = CGRect(x: b.minX, y: b.minY, width: p.x - b.minX, height: p.y - b.minY)
            case .bottom: b = CGRect(x: b.minX, y: b.minY, width: b.width, height: p.y - b.minY)
            case .bottomLeft: b = CGRect(x: p.x, y: b.minY, width: b.maxX - p.x, height: p.y - b.minY)
            case .left: b = CGRect(x: p.x, y: b.minY, width: b.maxX - p.x, height: b.height)
            default: break
            }
            if kind == .text {
                start = CGPoint(x: b.minX, y: b.minY)
                // Text scales with its box height rather than reflowing.
                fontSize = max(8, b.height - 4)
            } else {
                start = CGPoint(x: b.minX, y: b.minY)
                end = CGPoint(x: b.minX + b.width, y: b.minY + b.height)
            }
        }
    }
}
