import XCTest
import AppKit
@testable import ImageSmith

final class ImagePipelineTests: XCTestCase {

    /// A 2×-scale image: 200×100 points backed by 400×200 pixels, like a Retina capture.
    private func retinaImage(pointWidth: CGFloat = 200, pointHeight: CGFloat = 100,
                             scale: CGFloat = 2, fill: NSColor = .white) -> NSImage {
        let pw = Int(pointWidth * scale), ph = Int(pointHeight * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pointWidth, height: pointHeight)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        fill.setFill()
        NSRect(x: 0, y: 0, width: pointWidth, height: pointHeight).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: pointWidth, height: pointHeight))
        image.addRepresentation(rep)
        return image
    }

    private func color(of image: NSImage, atPixel p: CGPoint) -> NSColor? {
        guard let cg = ImageUtilities.cgImage(from: image),
              let crop = cg.cropping(to: CGRect(x: p.x, y: p.y, width: 1, height: 1))
        else { return nil }
        return NSBitmapImageRep(cgImage: crop).colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)
    }

    func testFlattenPreservesFullPixelResolution() {
        let base = retinaImage()
        let out = AnnotationRenderer.flatten(base: base, annotations: [], obscure: nil)
        XCTAssertEqual(out.size, NSSize(width: 200, height: 100))
        XCTAssertEqual(out.representations.first?.pixelsWide, 400)
        XCTAssertEqual(out.representations.first?.pixelsHigh, 200)
    }

    func testFlattenDrawsAnnotationsWithATopLeftOrigin() {
        let base = retinaImage()
        // A filled black box over the TOP-LEFT quarter in image point space.
        let a = Annotation(kind: .redact, start: .zero, end: CGPoint(x: 100, y: 50),
                           color: .black, strokeWidth: 1)
        let out = AnnotationRenderer.flatten(base: base, annotations: [a], obscure: nil)

        // CGImage pixel space is also top-left, so pixel (20,20) is inside the box.
        let inside = color(of: out, atPixel: CGPoint(x: 20, y: 20))
        let outside = color(of: out, atPixel: CGPoint(x: 380, y: 180))
        XCTAssertNotNil(inside)
        XCTAssertLessThan(inside!.brightnessComponent, 0.1, "top-left quarter should be redacted")
        XCTAssertGreaterThan(outside!.brightnessComponent, 0.9, "bottom-right should be untouched")
    }

    func testTextAnnotationLandsInsideItsOwnBounds() {
        let base = retinaImage(pointWidth: 300, pointHeight: 120, scale: 1)
        let a = Annotation(kind: .text, start: CGPoint(x: 10, y: 10), end: .zero,
                           color: .black, strokeWidth: 1)
        a.text = "HELLO"
        a.fontSize = 48
        let out = AnnotationRenderer.flatten(base: base, annotations: [a], obscure: nil)

        // Something dark must appear inside the reported bounds…
        var foundDark = false
        let b = a.bounds
        for x in stride(from: b.minX + 2, to: b.maxX - 2, by: 2) {
            for y in stride(from: b.minY + 2, to: b.maxY - 2, by: 2) {
                if let c = color(of: out, atPixel: CGPoint(x: x, y: y)), c.brightnessComponent < 0.5 {
                    foundDark = true; break
                }
            }
            if foundDark { break }
        }
        XCTAssertTrue(foundDark, "text should render inside its bounds")
        // …and the far corner must stay clean, which catches a vertical flip.
        XCTAssertGreaterThan(color(of: out, atPixel: CGPoint(x: 290, y: 110))!.brightnessComponent, 0.9)
    }

    func testCropClampsToTheImageAndReturnsIntegralPixels() {
        let cg = ImageUtilities.cgImage(from: retinaImage())!
        let cropped = ImageUtilities.crop(cg, toPixelRect: CGRect(x: -50, y: -50, width: 200, height: 200))
        XCTAssertEqual(cropped?.width, 150)
        XCTAssertEqual(cropped?.height, 150)
        XCTAssertNil(ImageUtilities.crop(cg, toPixelRect: CGRect(x: 1000, y: 1000, width: 10, height: 10)))
    }

    func testDownscaleHalvesARetinaCapture() {
        let cg = ImageUtilities.cgImage(from: retinaImage())!
        let scaled = ImageUtilities.scale(cg, by: 0.5)
        XCTAssertEqual(scaled?.width, 200)
        XCTAssertEqual(scaled?.height, 100)
    }

    func testDecoratePadsOnEverySide() {
        let base = retinaImage()
        let out = ImageUtilities.decorate(base, padding: 20, shadow: false, background: .white)
        XCTAssertEqual(out.size, NSSize(width: 240, height: 140))
    }

    func testDecorateKeepsTheRetinaBackingScale() {
        let base = retinaImage()
        let out = ImageUtilities.decorate(base, padding: 20, shadow: false, background: .black)
        XCTAssertEqual(ImageUtilities.pixelSize(of: out), CGSize(width: 480, height: 280),
                       "padding must not silently rasterise a 2× capture at 1×")
    }

    func testDecorateBackgroundSurroundsTheImage() {
        let base = retinaImage(fill: .white)
        let out = ImageUtilities.decorate(base, padding: 20, shadow: false, background: .black)
        XCTAssertLessThan(color(of: out, atPixel: CGPoint(x: 5, y: 5))!.brightnessComponent, 0.1)
        XCTAssertGreaterThan(color(of: out, atPixel: CGPoint(x: 240, y: 140))!.brightnessComponent, 0.9)
    }

    func testFlattenIsIdempotentForTheSameAnnotations() {
        let base = retinaImage()
        let a = Annotation(kind: .redact, start: .zero, end: CGPoint(x: 100, y: 50),
                           color: .black, strokeWidth: 1)
        let once = AnnotationRenderer.flatten(base: base, annotations: [a], obscure: nil)
        let twice = AnnotationRenderer.flatten(base: base, annotations: [a], obscure: nil)
        XCTAssertEqual(ImageUtilities.pngData(from: once), ImageUtilities.pngData(from: twice))
    }

    func testPNGEncodingRoundTrips() {
        let data = ImageUtilities.pngData(from: retinaImage())
        XCTAssertNotNil(data)
        XCTAssertEqual(NSImage(data: data!)?.representations.first?.pixelsWide, 400)
    }
}
