import XCTest
@testable import ImageSmith

final class VideoEditPlanTests: XCTestCase {
    func testTrimMapsEditedTimeBackToSource() {
        var plan = VideoEditPlan(duration: 20)
        plan.cut(from: 5, to: 10)
        plan.trim(from: 3, to: 8)
        XCTAssertEqual(plan.segments, [VideoSegment(start: 3, end: 5),
                                       VideoSegment(start: 10, end: 13)])
        XCTAssertEqual(plan.duration, 5)
    }

    func testMiddleCutAndSecondCut() {
        var plan = VideoEditPlan(duration: 20)
        plan.cut(from: 5, to: 10)
        plan.cut(from: 3, to: 7)
        XCTAssertEqual(plan.segments, [VideoSegment(start: 0, end: 3),
                                       VideoSegment(start: 12, end: 20)])
        XCTAssertEqual(plan.duration, 11)
    }

    func testCannotRemoveEntireClip() {
        var plan = VideoEditPlan(duration: 10)
        plan.cut(from: 0, to: 10)
        XCTAssertEqual(plan.duration, 10)
    }

    func testSplitAndSpeedKeepCutsInSourceTime() {
        var plan = VideoEditPlan(duration: 10)
        plan.split(at: 4)
        XCTAssertEqual(plan.segments, [VideoSegment(start: 0, end: 4),
                                       VideoSegment(start: 4, end: 10)])
        plan.rate = 2
        XCTAssertEqual(plan.duration, 5)
        plan.cut(from: 1, to: 2)
        XCTAssertEqual(plan.segments, [VideoSegment(start: 0, end: 2),
                                       VideoSegment(start: 4, end: 10)])
        XCTAssertEqual(plan.duration, 4)
    }

    func testCutToEndAtOneAndAHalfSpeedDoesNotTrap() {
        // duration * 1.5 overshoots sourceTimelineDuration by an ulp for these
        // lengths, which used to build an inverted Range and crash.
        for duration in [0.8535, 1.1, 3.3, 7.7, 12.9] {
            var plan = VideoEditPlan(duration: duration)
            plan.rate = 1.5
            plan.cut(from: 0.2, to: plan.duration)
            XCTAssertEqual(plan.segments.count, 1)
            XCTAssertEqual(plan.segments[0].start, 0, accuracy: 1e-9)
            XCTAssertEqual(plan.segments[0].end, 0.3, accuracy: 1e-9)
        }
    }

    func testSlicesShorterThanOneTickAreDropped() {
        var plan = VideoEditPlan(duration: 10)
        plan.cut(from: 0.0005, to: 5)
        XCTAssertEqual(plan.segments, [VideoSegment(start: 5, end: 10)])
    }
}
