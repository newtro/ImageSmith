import XCTest
import AppKit
import Carbon.HIToolbox
@testable import ImageSmith

final class FileNamingTests: XCTestCase {
    private let reference: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 3; c.day = 7; c.hour = 9; c.minute = 5; c.second = 3
        c.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    func testTokensExpand() {
        let out = CaptureStore.shared.expand(template: "Shot {date} at {time}", date: reference)
        XCTAssertTrue(out.hasPrefix("Shot 2026-03-07 at "), out)
        XCTAssertFalse(out.contains("{"))
    }

    func testPathSeparatorsAndColonsAreNeutralised() {
        let out = CaptureStore.shared.expand(template: "a/b:c", date: reference)
        XCTAssertEqual(out, "a-b.c")
    }

    func testEpochToken() {
        let out = CaptureStore.shared.expand(template: "{epoch}", date: reference)
        XCTAssertEqual(out, String(Int(reference.timeIntervalSince1970)))
    }
}

final class HotKeyComboTests: XCTestCase {
    func testPrintScreenDefaultIsF13WithNoModifiers() {
        XCTAssertEqual(HotKeyCombo.printScreen.keyCode, UInt32(kVK_F13))
        XCTAssertEqual(HotKeyCombo.printScreen.carbonModifiers, 0)
    }

    func testDisplayStringOrdersModifiersLikeMacOS() {
        let combo = HotKeyCombo(keyCode: UInt32(kVK_ANSI_S),
                                carbonModifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        XCTAssertEqual(combo.displayString, "⌃⌥⇧⌘S")
    }

    func testEmptyComboRendersAsADash() {
        XCTAssertEqual(HotKeyCombo.none.displayString, "—")
        XCTAssertTrue(HotKeyCombo.none.isEmpty)
    }

    func testCocoaModifiersMirrorCarbonFlags() {
        XCTAssertTrue(HotKeyCombo.shiftPrintScreen.cocoaModifiers.contains(.shift))
        XCTAssertFalse(HotKeyCombo.shiftPrintScreen.cocoaModifiers.contains(.command))
    }
}

final class ReopenWindowTests: XCTestCase {
    func testASecondTapInsideTheWindowCountsAsEdit() {
        let store = CaptureStore.shared
        store.clearHistory()
        SettingsStore.shared.prefs.editorReopenWindow = 2

        let image = NSImage(size: NSSize(width: 10, height: 10))
        store.record(Capture(image: image, sourceDescription: "test"))

        XCTAssertTrue(store.isWithinReopenWindow())
        XCTAssertFalse(store.isWithinReopenWindow(now: Date().addingTimeInterval(5)))

        store.invalidateReopenWindow()
        XCTAssertFalse(store.isWithinReopenWindow(), "a consumed tap must not re-trigger")
    }

    func testHistoryIsCappedAndNewestFirst() {
        let store = CaptureStore.shared
        store.clearHistory()
        SettingsStore.shared.prefs.historyLimit = 3
        for i in 0..<5 {
            store.record(Capture(image: NSImage(size: NSSize(width: 10, height: 10)),
                                 sourceDescription: "shot \(i)"))
        }
        XCTAssertEqual(store.history.count, 3)
        XCTAssertEqual(store.latest?.sourceDescription, "shot 4")
    }
}

final class ColorHexTests: XCTestCase {
    func testHexRoundTrip() {
        let c = NSColor(hex: "#FF3B30")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.hexString, "#FF3B30")
        XCTAssertNil(NSColor(hex: "nope"))
    }
}
