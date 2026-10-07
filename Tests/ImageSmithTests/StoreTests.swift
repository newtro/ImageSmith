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

final class PreferenceDefaultTests: XCTestCase {
    func testPrintScreenCapturesTheWindowAndShiftCapturesTheScreen() {
        let p = Preferences()
        XCTAssertEqual(p.windowHotKey, .printScreen)
        XCTAssertEqual(p.fullScreenHotKey, .shiftPrintScreen)
    }

    func testSchemaOneDefaultsAreSwappedByMigration() throws {
        // A schema-1 store still on the old defaults (screen = F13, window = ⇧F13).
        let json = """
        {"fullScreenHotKey":{"keyCode":105,"carbonModifiers":0},
         "windowHotKey":{"keyCode":105,"carbonModifiers":512},
         "defaultStrokeWidth":7}
        """.data(using: .utf8)!
        var p = try JSONDecoder().decode(Preferences.self, from: json)
        XCTAssertEqual(p.schemaVersion, 1)
        XCTAssertEqual(p.defaultStrokeWidth, 7, "missing keys fall back to defaults without discarding the rest")
        p.migrate()
        XCTAssertEqual(p.windowHotKey, .printScreen)
        XCTAssertEqual(p.fullScreenHotKey, .shiftPrintScreen)
        XCTAssertEqual(p.schemaVersion, Preferences.currentSchemaVersion)
    }

    func testMigrationLeavesCustomBindingsAlone() throws {
        let json = """
        {"fullScreenHotKey":{"keyCode":21,"carbonModifiers":4352},
         "windowHotKey":{"keyCode":105,"carbonModifiers":512}}
        """.data(using: .utf8)!
        var p = try JSONDecoder().decode(Preferences.self, from: json)
        p.migrate()
        XCTAssertEqual(p.fullScreenHotKey, HotKeyCombo(keyCode: 21, carbonModifiers: 4352))
        XCTAssertEqual(p.windowHotKey, .shiftPrintScreen)
    }

    func testRememberedToolSettingsRoundTrip() throws {
        var p = Preferences()
        p.lastTool = ToolKind.rectangle.rawValue; p.lastColorHex = "#00FF00"; p.lastStrokeWidth = 9; p.lastFillShapes = true
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Preferences.self, from: data)
        XCTAssertEqual(back.lastTool, "rectangle"); XCTAssertEqual(back.lastColorHex, "#00FF00")
        XCTAssertEqual(back.lastStrokeWidth, 9); XCTAssertEqual(back.lastFillShapes, true); XCTAssertNil(back.lastFontSize)
    }

    func testRecordingPreferencesSurviveRoundTrip() throws {
        var p = Preferences()
        p.recordRegionHotKey = .controlPrintScreen
        p.recordingFileNameTemplate = "Clip {date}"
        p.recordSystemAudio = false
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(decoded.recordRegionHotKey, .controlPrintScreen)
        XCTAssertEqual(decoded.recordingFileNameTemplate, "Clip {date}")
        XCTAssertFalse(decoded.recordSystemAudio)
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
