import AppKit
import XCTest
@testable import ImageSmith

@MainActor
final class PinnedWindowTests: XCTestCase {
    private func pinnedWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.level == .floating && $0.isVisible }
    }

    func testPinCanTakeKeyAndEscClosesIt() throws {
        _ = NSApplication.shared
        PinnedWindowController.closeAll()
        PinnedWindowController.pin(image: NSImage(size: NSSize(width: 200, height: 100), flipped: false) { r in
            NSColor.red.setFill(); r.fill(); return true
        })
        let window = try XCTUnwrap(pinnedWindows().first)
        // A borderless window that can't become key never receives Esc.
        XCTAssertTrue(window.canBecomeKey)

        let esc = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: window.windowNumber,
                                                 context: nil, characters: "\u{1b}",
                                                 charactersIgnoringModifiers: "\u{1b}",
                                                 isARepeat: false, keyCode: 53))
        window.contentView?.keyDown(with: esc)
        XCTAssertFalse(window.isVisible)
        PinnedWindowController.closeAll()
    }

    func testPinHasCloseButton() throws {
        _ = NSApplication.shared
        PinnedWindowController.closeAll()
        PinnedWindowController.pin(image: NSImage(size: NSSize(width: 200, height: 100)))
        let window = try XCTUnwrap(pinnedWindows().first)
        let button = try XCTUnwrap(window.contentView?.subviews.compactMap { $0 as? NSButton }.first)
        button.performClick(nil)
        XCTAssertFalse(window.isVisible)
        PinnedWindowController.closeAll()
    }
}
