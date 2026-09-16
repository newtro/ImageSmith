import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Click, then press the combination you want. Registered hotkeys are suspended
/// while recording so the app does not swallow its own keystrokes.
final class ShortcutRecorderView: NSView {
    var combo: HotKeyCombo = .none { didSet { needsDisplay = true } }
    var onChange: ((HotKeyCombo) -> Void)?

    private var recording = false {
        didSet {
            needsDisplay = true
            recording ? HotKeyManager.shared.suspend() : HotKeyManager.shared.resume()
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                   : NSColor.controlBackgroundColor).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = 1
        path.stroke()

        let text = recording ? "Press keys…" : (combo.isEmpty ? "Click to set" : combo.displayString)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: recording ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                                withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        recording = true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; return }                 // esc cancels
        if event.keyCode == 51 { combo = .none; onChange?(combo); recording = false; return } // delete clears
        let new = HotKeyCombo.from(event: event)
        combo = new
        onChange?(new)
        recording = false
    }

    override func resignFirstResponder() -> Bool {
        if recording { recording = false }
        return true
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var combo: HotKeyCombo

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let v = ShortcutRecorderView()
        v.combo = combo
        v.onChange = { combo = $0 }
        return v
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.combo = combo
        nsView.onChange = { combo = $0 }
    }
}
