import AppKit
import CoreImage
import UniformTypeIdentifiers

/// Geometry helpers for moving between AppKit's bottom-left global space and
/// CoreGraphics' top-left global space.
enum ScreenGeometry {
    static var globalHeight: CGFloat {
        // The primary screen defines y = 0 in CG space.
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
    }

    static func cgPoint(fromCocoa p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: globalHeight - p.y)
    }

    static func cgRect(fromCocoa r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: globalHeight - r.maxY, width: r.width, height: r.height)
    }

    static func cocoaRect(fromCG r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: globalHeight - r.maxY, width: r.width, height: r.height)
    }

    static func screen(containing cocoaPoint: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(cocoaPoint) } ?? NSScreen.main
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
    }
}

enum ImageUtilities {
    static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// The pixel dimensions behind an NSImage, which is what we must preserve —
    /// `NSImage.size` is in points and a Retina capture has twice as many pixels.
    static func pixelSize(of image: NSImage) -> CGSize {
        if let rep = image.representations.first, rep.pixelsWide > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    /// Renders into an explicitly sized bitmap whose coordinate system is flipped
    /// (top-left origin) and measured in *points*, so drawing code never has to
    /// think about the backing scale. Building the CGContext by hand avoids the
    /// implicit scaling that `NSGraphicsContext(bitmapImageRep:)` applies.
    static func renderBitmap(pointSize: CGSize,
                             pixelSize: CGSize,
                             _ draw: () -> Void) -> NSImage? {
        let pw = max(1, Int(pixelSize.width.rounded()))
        let ph = max(1, Int(pixelSize.height.rounded()))
        guard pointSize.width > 0, pointSize.height > 0,
              let cg = CGContext(data: nil, width: pw, height: ph,
                                 bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        cg.translateBy(x: 0, y: CGFloat(ph))
        cg.scaleBy(x: CGFloat(pw) / pointSize.width, y: -CGFloat(ph) / pointSize.height)
        cg.interpolationQuality = .high

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        draw()
        NSGraphicsContext.current = previous

        guard let out = cg.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: out)
        rep.size = pointSize
        let image = NSImage(size: pointSize)
        image.addRepresentation(rep)
        return image
    }

    // MARK: Conversion

    static func nsImage(from cgImage: CGImage, scale: CGFloat) -> NSImage {
        let pointSize = NSSize(width: CGFloat(cgImage.width) / scale,
                               height: CGFloat(cgImage.height) / scale)
        let image = NSImage(size: pointSize)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = pointSize
        image.addRepresentation(rep)
        return image
    }

    static func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    // MARK: Pixel operations

    static func crop(_ image: CGImage, toPixelRect rect: CGRect) -> CGImage? {
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard clamped.width >= 1, clamped.height >= 1 else { return nil }
        return image.cropping(to: clamped.integral)
    }

    static func scale(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        guard factor != 1 else { return image }
        let w = Int((CGFloat(image.width) * factor).rounded())
        let h = Int((CGFloat(image.height) * factor).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func blurred(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: image)
        // Clamp first so the blur does not eat away transparent edges.
        let clamped = ci.clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(clamped, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let out = filter.outputImage else { return nil }
        return ciContext.createCGImage(out, from: ci.extent)
    }

    static func pixelated(_ image: CGImage, blockSize: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(ci.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(max(2, blockSize), forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: ci.extent.midX, y: ci.extent.midY), forKey: kCIInputCenterKey)
        guard let out = filter.outputImage else { return nil }
        return ciContext.createCGImage(out, from: ci.extent)
    }

    // MARK: Presentation (padding, shadow, background)

    static func decorate(_ image: NSImage,
                         padding: CGFloat,
                         shadow: Bool,
                         background: BackgroundStyle) -> NSImage {
        guard padding > 0 || shadow || background != .none else { return image }
        let pad = max(padding, shadow ? 24 : 0)
        let pointSize = NSSize(width: image.size.width + pad * 2, height: image.size.height + pad * 2)
        let scale = pixelSize(of: image).width / max(image.size.width, 1)
        let pixels = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)

        let result = renderBitmap(pointSize: pointSize, pixelSize: pixels) {
            let full = NSRect(origin: .zero, size: pointSize)
            drawBackground(background, in: full)
            let imageRect = NSRect(x: pad, y: pad, width: image.size.width, height: image.size.height)
            NSGraphicsContext.current?.saveGraphicsState()
            if shadow {
                let s = NSShadow()
                s.shadowBlurRadius = 24
                s.shadowOffset = NSSize(width: 0, height: -8)
                s.shadowColor = NSColor.black.withAlphaComponent(0.45)
                s.set()
            }
            image.draw(in: imageRect)
            NSGraphicsContext.current?.restoreGraphicsState()
        }
        return result ?? image
    }

    static func drawBackground(_ style: BackgroundStyle, in rect: NSRect) {
        switch style {
        case .none:
            NSColor.clear.setFill()
            rect.fill()
        case .white:
            NSColor.white.setFill(); rect.fill()
        case .black:
            NSColor.black.setFill(); rect.fill()
        case .gradientBlue:
            NSGradient(colors: [NSColor(srgbRed: 0.35, green: 0.47, blue: 0.95, alpha: 1),
                                NSColor(srgbRed: 0.55, green: 0.29, blue: 0.85, alpha: 1)])?
                .draw(in: rect, angle: 45)
        case .gradientWarm:
            NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.62, blue: 0.35, alpha: 1),
                                NSColor(srgbRed: 0.95, green: 0.35, blue: 0.45, alpha: 1)])?
                .draw(in: rect, angle: 45)
        case .checkerboard:
            NSColor(white: 0.92, alpha: 1).setFill(); rect.fill()
            NSColor(white: 0.82, alpha: 1).setFill()
            let s: CGFloat = 12
            var y = rect.minY, row = 0
            while y < rect.maxY {
                var x = rect.minX + (row % 2 == 0 ? 0 : s)
                while x < rect.maxX {
                    NSRect(x: x, y: y, width: s, height: s).fill()
                    x += s * 2
                }
                y += s; row += 1
            }
        }
    }

    // MARK: Encoding

    static func pngData(from image: NSImage) -> Data? {
        guard let cg = cgImage(from: image) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = image.size
        return rep.representation(using: .png, properties: [:])
    }

    static func jpegData(from image: NSImage, quality: CGFloat) -> Data? {
        guard let cg = cgImage(from: image) else { return nil }
        // JPEG has no alpha; composite onto white so transparent padding is not black.
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flat = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: flat)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
