import XCTest
import AppKit
@testable import ImageSmith

final class AnnotationGeometryTests: XCTestCase {

    private func rectAnnotation() -> Annotation {
        Annotation(kind: .rectangle, start: CGPoint(x: 10, y: 20),
                   end: CGPoint(x: 110, y: 80), color: .red, strokeWidth: 4)
    }

    func testBoundsAreOrientationIndependent() {
        let a = Annotation(kind: .rectangle, start: CGPoint(x: 110, y: 80),
                           end: CGPoint(x: 10, y: 20), color: .red, strokeWidth: 4)
        XCTAssertEqual(a.bounds, CGRect(x: 10, y: 20, width: 100, height: 60))
    }

    func testTranslateMovesBothEndsAndFreehandPoints() {
        let a = Annotation(kind: .pen, start: .zero, end: .zero, color: .red, strokeWidth: 2)
        a.points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)]
        a.translate(by: CGPoint(x: 5, y: -3))
        XCTAssertEqual(a.points[0], CGPoint(x: 5, y: -3))
        XCTAssertEqual(a.points[1], CGPoint(x: 15, y: 7))
    }

    func testStrokedRectangleIsHitOnItsEdgeButNotItsHollowCentre() {
        let a = rectAnnotation()
        XCTAssertTrue(a.hitTest(CGPoint(x: 10, y: 50), tolerance: 4), "left edge should hit")
        XCTAssertFalse(a.hitTest(CGPoint(x: 60, y: 50), tolerance: 4), "hollow centre should miss")
    }

    func testFilledRectangleIsHitInItsCentre() {
        let a = rectAnnotation()
        a.filled = true
        XCTAssertTrue(a.hitTest(CGPoint(x: 60, y: 50), tolerance: 4))
    }

    func testLineHitTestUsesPerpendicularDistance() {
        let a = Annotation(kind: .line, start: .zero, end: CGPoint(x: 100, y: 0),
                           color: .red, strokeWidth: 2)
        XCTAssertTrue(a.hitTest(CGPoint(x: 50, y: 3), tolerance: 4))
        XCTAssertFalse(a.hitTest(CGPoint(x: 50, y: 40), tolerance: 4))
    }

    func testResizingFromTopLeftKeepsOppositeCornerPinned() {
        let a = rectAnnotation()
        a.resize(handle: .topLeft, to: CGPoint(x: 30, y: 40))
        XCTAssertEqual(a.bounds, CGRect(x: 30, y: 40, width: 80, height: 40))
    }

    func testResizingALineMovesOnlyThatEndpoint() {
        let a = Annotation(kind: .arrow, start: CGPoint(x: 0, y: 0),
                           end: CGPoint(x: 50, y: 50), color: .red, strokeWidth: 3)
        a.resize(handle: .endPoint, to: CGPoint(x: 90, y: 10))
        XCTAssertEqual(a.start, .zero)
        XCTAssertEqual(a.end, CGPoint(x: 90, y: 10))
    }

    func testDegenerateShapesAreDiscarded() {
        let a = Annotation(kind: .rectangle, start: .zero, end: CGPoint(x: 1, y: 1),
                           color: .red, strokeWidth: 2)
        XCTAssertTrue(a.isDegenerate)
        let text = Annotation(kind: .text, start: .zero, end: .zero, color: .red, strokeWidth: 1)
        XCTAssertTrue(text.isDegenerate)
        text.text = "hi"
        XCTAssertFalse(text.isDegenerate)
    }

    func testCopyIsIndependentOfTheOriginal() {
        let a = rectAnnotation()
        let b = a.copy()
        b.translate(by: CGPoint(x: 100, y: 100))
        XCTAssertEqual(a.bounds.origin, CGPoint(x: 10, y: 20))
        XCTAssertEqual(b.bounds.origin, CGPoint(x: 110, y: 120))
    }
}

final class ScreenGeometryTests: XCTestCase {
    func testCocoaToCGRectFlipsAroundTheGlobalHeight() {
        let h = ScreenGeometry.globalHeight
        let cocoa = NSRect(x: 100, y: 200, width: 300, height: 400)
        let cg = ScreenGeometry.cgRect(fromCocoa: cocoa)
        XCTAssertEqual(cg.minX, 100)
        XCTAssertEqual(cg.minY, h - 600)
        XCTAssertEqual(ScreenGeometry.cocoaRect(fromCG: cg), cocoa)
    }
}
