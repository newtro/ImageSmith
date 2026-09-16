#!/usr/bin/env swift
// Renders ImageSmith's app icon (a capture reticle over a warm "forge" gradient)
// into an .iconset and converts it with iconutil.
import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let s = size
        let inset = s * 0.06
        let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let radius = s * 0.22

        let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
        NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.45, blue: 0.20, alpha: 1),
                            NSColor(srgbRed: 0.78, green: 0.16, blue: 0.36, alpha: 1)])?
            .draw(in: path, angle: -60)

        // Reticle
        let r = s * 0.27
        let center = NSPoint(x: body.midX, y: body.midY)
        NSColor.white.withAlphaComponent(0.95).setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        ring.lineWidth = s * 0.055
        ring.stroke()

        let inner = NSBezierPath(ovalIn: NSRect(x: center.x - r * 0.34, y: center.y - r * 0.34,
                                                width: r * 0.68, height: r * 0.68))
        NSColor.white.setFill()
        inner.fill()

        // Corner brackets
        let bracket = NSBezierPath()
        let m = s * 0.20, len = s * 0.13
        let corners: [(NSPoint, CGFloat, CGFloat)] = [
            (NSPoint(x: body.minX + m, y: body.minY + m), 1, 1),
            (NSPoint(x: body.maxX - m, y: body.minY + m), -1, 1),
            (NSPoint(x: body.minX + m, y: body.maxY - m), 1, -1),
            (NSPoint(x: body.maxX - m, y: body.maxY - m), -1, -1)
        ]
        for (p, dx, dy) in corners {
            bracket.move(to: NSPoint(x: p.x + dx * len, y: p.y))
            bracket.line(to: p)
            bracket.line(to: NSPoint(x: p.x, y: p.y + dy * len))
        }
        bracket.lineWidth = s * 0.045
        bracket.lineCapStyle = .round
        bracket.lineJoinStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke()
        bracket.stroke()
        return true
    }
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./ImageSmith.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let specs: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"),
    (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x")
]

for (px, name) in specs {
    let image = drawIcon(size: CGFloat(px))
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { continue }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    }
}
print("wrote \(outDir)")
