import AppKit
import Carbon.HIToolbox

/// Registers system-wide hotkeys through Carbon's `RegisterEventHotKey`, which works
/// without Accessibility permission and fires even while another app is frontmost.
final class HotKeyManager {
    enum Action: UInt32, CaseIterable {
        case fullScreen = 1
        case window = 2
        case region = 3
        case ocr = 4
        case pin = 5
        case repeatLast = 6
    }

    static let shared = HotKeyManager()

    private var refs: [Action: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x494D5348 // 'IMSH'

    var onAction: ((Action) -> Void)?

    private init() {}

    func start() {
        installHandlerIfNeeded()
        reload()
    }

    func reload() {
        unregisterAll()
        let p = SettingsStore.shared.prefs
        register(.fullScreen, p.fullScreenHotKey)
        register(.window, p.windowHotKey)
        register(.region, p.regionHotKey)
        register(.ocr, p.ocrHotKey)
        register(.pin, p.pinHotKey)
        register(.repeatLast, p.repeatHotKey)
    }

    /// Temporarily drop registrations so a shortcut recorder can see the raw keys.
    func suspend() { unregisterAll() }
    func resume() { reload() }

    private func register(_ action: Action, _ combo: HotKeyCombo) {
        guard !combo.isEmpty else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: action.rawValue)
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[action] = ref
        } else {
            NSLog("ImageSmith: could not register hotkey \(combo.displayString) (status \(status))")
        }
    }

    private func unregisterAll() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard err == noErr, let action = HotKeyManager.Action(rawValue: id.id) else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { HotKeyManager.shared.onAction?(action) }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
