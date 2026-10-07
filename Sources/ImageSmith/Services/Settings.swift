import AppKit
import Combine
import Carbon.HIToolbox

/// A keyboard shortcut expressed in Carbon virtual key-code + modifier-mask terms,
/// which is what `RegisterEventHotKey` speaks.
struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let none = HotKeyCombo(keyCode: 0, carbonModifiers: 0)
    var isEmpty: Bool { keyCode == 0 && carbonModifiers == 0 }

    /// The PC "Print Screen" key arrives on macOS as F13 (virtual key 105).
    static let printScreen = HotKeyCombo(keyCode: UInt32(kVK_F13), carbonModifiers: 0)
    static let shiftPrintScreen = HotKeyCombo(keyCode: UInt32(kVK_F13), carbonModifiers: UInt32(shiftKey))
    static let commandPrintScreen = HotKeyCombo(keyCode: UInt32(kVK_F13), carbonModifiers: UInt32(cmdKey))
    static let optionPrintScreen = HotKeyCombo(keyCode: UInt32(kVK_F13), carbonModifiers: UInt32(optionKey))
    static let controlPrintScreen = HotKeyCombo(keyCode: UInt32(kVK_F13), carbonModifiers: UInt32(controlKey))

    var displayString: String {
        guard !isEmpty else { return "—" }
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + KeyCodeNames.name(for: keyCode)
    }

    var cocoaModifiers: NSEvent.ModifierFlags {
        var f = NSEvent.ModifierFlags()
        if carbonModifiers & UInt32(controlKey) != 0 { f.insert(.control) }
        if carbonModifiers & UInt32(optionKey) != 0 { f.insert(.option) }
        if carbonModifiers & UInt32(shiftKey) != 0 { f.insert(.shift) }
        if carbonModifiers & UInt32(cmdKey) != 0 { f.insert(.command) }
        return f
    }

    static func from(event: NSEvent) -> HotKeyCombo {
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        return HotKeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
    }
}

enum KeyCodeNames {
    private static let table: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13 (PrtSc)", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/"
    ]
    static func name(for code: UInt32) -> String {
        table[Int(code)] ?? "Key \(code)"
    }
}

enum AfterCaptureAction: String, Codable, CaseIterable {
    case clipboardOnly
    case clipboardAndFile
    case clipboardFileAndEditor

    var title: String {
        switch self {
        case .clipboardOnly: return "Copy to clipboard"
        case .clipboardAndFile: return "Copy to clipboard and save a file"
        case .clipboardFileAndEditor: return "Copy, save, and open the editor"
        }
    }
}

enum ClipboardPayload: String, Codable, CaseIterable {
    case image
    case imageAndPath
    case pathOnly

    var title: String {
        switch self {
        case .image: return "Image only"
        case .imageAndPath: return "Image (file also on pasteboard)"
        case .pathOnly: return "File path as text"
        }
    }
}

/// Everything the user can tune. Persisted as JSON in UserDefaults so that adding
/// fields later never orphans an old plist key.
struct Preferences: Codable {
    /// Bumped when a default changes meaning; `SettingsStore` migrates older stores.
    static let currentSchemaVersion = 2
    var schemaVersion = Preferences.currentSchemaVersion

    /// Print Screen alone captures the front window; ⇧ Print Screen the whole screen.
    var fullScreenHotKey = HotKeyCombo.shiftPrintScreen
    var windowHotKey = HotKeyCombo.printScreen
    var regionHotKey = HotKeyCombo.commandPrintScreen
    var ocrHotKey = HotKeyCombo.optionPrintScreen
    var pinHotKey = HotKeyCombo.controlPrintScreen
    var repeatHotKey = HotKeyCombo.none
    var recordScreenHotKey = HotKeyCombo.none
    var recordWindowHotKey = HotKeyCombo.none
    var recordRegionHotKey = HotKeyCombo.none

    /// Pressing a capture hotkey again inside this window re-opens the last shot
    /// in the editor instead of taking a new one.
    var editorReopenWindow: Double = 2.0

    var afterCapture: AfterCaptureAction = .clipboardAndFile
    var clipboardPayload: ClipboardPayload = .image

    var saveDirectoryPath: String = (NSHomeDirectory() as NSString).appendingPathComponent("Pictures/ImageSmith")
    var fileNameTemplate: String = "Screenshot {date} at {time}"
    var recordingFileNameTemplate: String = "Recording {date} at {time}"
    var maintainLatestSymlink = true
    var recordSystemAudio = true

    var includeCursor = false
    var includeWindowShadow = false
    var windowPadding: Double = 0
    var backgroundStyle: BackgroundStyle = .none

    var playSound = true
    var showFlash = true
    var showThumbnail = true
    var thumbnailSeconds: Double = 5

    var captureDelay: Double = 0
    var downscaleRetina = false
    var jpegInsteadOfPNG = false
    var jpegQuality: Double = 0.9

    var defaultColorHex = "#FF3B30"
    var defaultStrokeWidth: Double = 4
    var defaultFontSize: Double = 28
    var copyAndCloseOnEnter = true

    var launchAtLogin = false
    var historyLimit: Int = 40

    /// The editor re-opens with whatever tool, colour, stroke, text size and fill the
    /// user had last time. `nil` means "never used yet"; the defaults above then apply.
    var rememberToolSettings = true
    var lastTool: String?
    var lastColorHex: String?
    var lastStrokeWidth: Double?
    var lastFontSize: Double?
    var lastFillShapes: Bool?

    init() {}

    /// Every field is optional on read so that adding a preference never throws the
    /// whole store away.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        fullScreenHotKey = try c.decodeIfPresent(HotKeyCombo.self, forKey: .fullScreenHotKey) ?? d.fullScreenHotKey
        windowHotKey = try c.decodeIfPresent(HotKeyCombo.self, forKey: .windowHotKey) ?? d.windowHotKey
        regionHotKey = try c.decodeIfPresent(HotKeyCombo.self, forKey: .regionHotKey) ?? d.regionHotKey
        ocrHotKey = try c.decodeIfPresent(HotKeyCombo.self, forKey: .ocrHotKey) ?? d.ocrHotKey
        pinHotKey = try c.decodeIfPresent(HotKeyCombo.self, forKey: .pinHotKey) ?? d.pinHotKey
        repeatHotKey = try c.decodeIfPresent(HotKeyCombo.self, forKey: .repeatHotKey) ?? d.repeatHotKey
        recordScreenHotKey = try c.decodeIfPresent(HotKeyCombo.self, forKey: .recordScreenHotKey) ?? d.recordScreenHotKey
        recordWindowHotKey = try c.decodeIfPresent(HotKeyCombo.self, forKey: .recordWindowHotKey) ?? d.recordWindowHotKey
        recordRegionHotKey = try c.decodeIfPresent(HotKeyCombo.self, forKey: .recordRegionHotKey) ?? d.recordRegionHotKey
        editorReopenWindow = try c.decodeIfPresent(Double.self, forKey: .editorReopenWindow) ?? d.editorReopenWindow
        afterCapture = try c.decodeIfPresent(AfterCaptureAction.self, forKey: .afterCapture) ?? d.afterCapture
        clipboardPayload = try c.decodeIfPresent(ClipboardPayload.self, forKey: .clipboardPayload) ?? d.clipboardPayload
        saveDirectoryPath = try c.decodeIfPresent(String.self, forKey: .saveDirectoryPath) ?? d.saveDirectoryPath
        fileNameTemplate = try c.decodeIfPresent(String.self, forKey: .fileNameTemplate) ?? d.fileNameTemplate
        recordingFileNameTemplate = try c.decodeIfPresent(String.self, forKey: .recordingFileNameTemplate) ?? d.recordingFileNameTemplate
        maintainLatestSymlink = try c.decodeIfPresent(Bool.self, forKey: .maintainLatestSymlink) ?? d.maintainLatestSymlink
        recordSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .recordSystemAudio) ?? d.recordSystemAudio
        includeCursor = try c.decodeIfPresent(Bool.self, forKey: .includeCursor) ?? d.includeCursor
        includeWindowShadow = try c.decodeIfPresent(Bool.self, forKey: .includeWindowShadow) ?? d.includeWindowShadow
        windowPadding = try c.decodeIfPresent(Double.self, forKey: .windowPadding) ?? d.windowPadding
        backgroundStyle = try c.decodeIfPresent(BackgroundStyle.self, forKey: .backgroundStyle) ?? d.backgroundStyle
        playSound = try c.decodeIfPresent(Bool.self, forKey: .playSound) ?? d.playSound
        showFlash = try c.decodeIfPresent(Bool.self, forKey: .showFlash) ?? d.showFlash
        showThumbnail = try c.decodeIfPresent(Bool.self, forKey: .showThumbnail) ?? d.showThumbnail
        thumbnailSeconds = try c.decodeIfPresent(Double.self, forKey: .thumbnailSeconds) ?? d.thumbnailSeconds
        captureDelay = try c.decodeIfPresent(Double.self, forKey: .captureDelay) ?? d.captureDelay
        downscaleRetina = try c.decodeIfPresent(Bool.self, forKey: .downscaleRetina) ?? d.downscaleRetina
        jpegInsteadOfPNG = try c.decodeIfPresent(Bool.self, forKey: .jpegInsteadOfPNG) ?? d.jpegInsteadOfPNG
        jpegQuality = try c.decodeIfPresent(Double.self, forKey: .jpegQuality) ?? d.jpegQuality
        defaultColorHex = try c.decodeIfPresent(String.self, forKey: .defaultColorHex) ?? d.defaultColorHex
        defaultStrokeWidth = try c.decodeIfPresent(Double.self, forKey: .defaultStrokeWidth) ?? d.defaultStrokeWidth
        defaultFontSize = try c.decodeIfPresent(Double.self, forKey: .defaultFontSize) ?? d.defaultFontSize
        copyAndCloseOnEnter = try c.decodeIfPresent(Bool.self, forKey: .copyAndCloseOnEnter) ?? d.copyAndCloseOnEnter
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        historyLimit = try c.decodeIfPresent(Int.self, forKey: .historyLimit) ?? d.historyLimit
        rememberToolSettings = try c.decodeIfPresent(Bool.self, forKey: .rememberToolSettings) ?? d.rememberToolSettings
        lastTool = try c.decodeIfPresent(String.self, forKey: .lastTool)
        lastColorHex = try c.decodeIfPresent(String.self, forKey: .lastColorHex)
        lastStrokeWidth = try c.decodeIfPresent(Double.self, forKey: .lastStrokeWidth)
        lastFontSize = try c.decodeIfPresent(Double.self, forKey: .lastFontSize)
        lastFillShapes = try c.decodeIfPresent(Bool.self, forKey: .lastFillShapes)
    }

    /// Schema 1 shipped Print Screen = screen, ⇧ Print Screen = window. Schema 2 swaps
    /// them, but only for stores still on those exact defaults so custom bindings survive.
    mutating func migrate() {
        if schemaVersion < 2 {
            if fullScreenHotKey == .printScreen && windowHotKey == .shiftPrintScreen {
                fullScreenHotKey = .shiftPrintScreen
                windowHotKey = .printScreen
            }
            schemaVersion = 2
        }
        schemaVersion = Preferences.currentSchemaVersion
    }
}

enum BackgroundStyle: String, Codable, CaseIterable {
    case none, white, black, gradientBlue, gradientWarm, checkerboard

    var title: String {
        switch self {
        case .none: return "None (transparent)"
        case .white: return "White"
        case .black: return "Black"
        case .gradientBlue: return "Cool gradient"
        case .gradientWarm: return "Warm gradient"
        case .checkerboard: return "Checkerboard"
        }
    }
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    static let didChange = Notification.Name("ImageSmith.settingsDidChange")

    private let key = "preferences.v1"
    private var loading = true

    @Published var prefs: Preferences {
        didSet { if !loading { save() } }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           var decoded = try? JSONDecoder().decode(Preferences.self, from: data) {
            let before = decoded.schemaVersion
            decoded.migrate()
            prefs = decoded
            loading = false
            if before != decoded.schemaVersion { save() }
        } else {
            prefs = Preferences()
        }
        loading = false
    }

    func update(_ mutate: (inout Preferences) -> Void) {
        mutate(&prefs)
    }

    func save() {
        if let data = try? JSONEncoder().encode(prefs) {
            UserDefaults.standard.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: SettingsStore.didChange, object: nil)
    }

    func resetToDefaults() {
        prefs = Preferences()
        save()
    }

    var saveDirectory: URL {
        URL(fileURLWithPath: prefs.saveDirectoryPath, isDirectory: true)
    }
}
