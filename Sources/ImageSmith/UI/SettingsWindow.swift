import AppKit
import SwiftUI
import ServiceManagement

final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    static func show() {
        if shared == nil {
            let controller = SettingsWindowController()
            shared = controller
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "ImageSmith Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 520))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }
}

struct SettingsView: View {
    @ObservedObject private var store = SettingsStore.shared

    var body: some View {
        TabView {
            ShortcutsTab(store: store).tabItem { Label("Shortcuts", systemImage: "keyboard") }
            CaptureTab(store: store).tabItem { Label("Capture", systemImage: "camera") }
            OutputTab(store: store).tabItem { Label("Output", systemImage: "folder") }
            EditorTab(store: store).tabItem { Label("Editor", systemImage: "pencil.tip") }
            GeneralTab(store: store).tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560, height: 520)
        .onChange(of: store.prefs.fullScreenHotKey) { HotKeyManager.shared.reload() }
        .onChange(of: store.prefs.windowHotKey) { HotKeyManager.shared.reload() }
        .onChange(of: store.prefs.regionHotKey) { HotKeyManager.shared.reload() }
        .onChange(of: store.prefs.ocrHotKey) { HotKeyManager.shared.reload() }
        .onChange(of: store.prefs.pinHotKey) { HotKeyManager.shared.reload() }
        .onChange(of: store.prefs.repeatHotKey) { HotKeyManager.shared.reload() }
    }
}

private struct ShortcutsTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                row("Capture screen", $store.prefs.fullScreenHotKey)
                row("Capture front window", $store.prefs.windowHotKey)
                row("Capture region", $store.prefs.regionHotKey)
                row("Capture text (OCR)", $store.prefs.ocrHotKey)
                row("Capture and pin", $store.prefs.pinHotKey)
                row("Repeat last capture", $store.prefs.repeatHotKey)
            } header: {
                Text("Global shortcuts").font(.headline)
            } footer: {
                Text("A PC keyboard's Print Screen key arrives on macOS as F13, which is the default here. On a Mac keyboard without F13, pick something else — ⌃⇧4 is a good stand-in.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Press again within")
                    TextField("", value: $store.prefs.editorReopenWindow, format: .number)
                        .frame(width: 50)
                    Text("seconds to open the editor")
                }
                Text("Tapping any capture shortcut again inside this window opens the shot you just took in the editor instead of taking a new one.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Double-tap to edit").font(.headline)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ label: String, _ binding: Binding<HotKeyCombo>) -> some View {
        HStack {
            Text(label)
            Spacer()
            ShortcutRecorder(combo: binding).frame(width: 150, height: 24)
        }
    }
}

private struct CaptureTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("After a capture") {
                Picker("Do this", selection: $store.prefs.afterCapture) {
                    ForEach(AfterCaptureAction.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Put on the clipboard", selection: $store.prefs.clipboardPayload) {
                    ForEach(ClipboardPayload.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Show the preview thumbnail", isOn: $store.prefs.showThumbnail)
                if store.prefs.showThumbnail {
                    HStack {
                        Text("Dismiss after")
                        Slider(value: $store.prefs.thumbnailSeconds, in: 2...30, step: 1)
                        Text("\(Int(store.prefs.thumbnailSeconds))s").monospacedDigit()
                    }
                }
                Toggle("Play a shutter sound", isOn: $store.prefs.playSound)
                Toggle("Flash the screen", isOn: $store.prefs.showFlash)
            }

            Section("Image") {
                Toggle("Include the mouse cursor", isOn: $store.prefs.includeCursor)
                Toggle("Include a drop shadow around windows", isOn: $store.prefs.includeWindowShadow)
                HStack {
                    Text("Padding")
                    Slider(value: $store.prefs.windowPadding, in: 0...120, step: 4)
                    Text("\(Int(store.prefs.windowPadding))px").monospacedDigit()
                }
                Picker("Background", selection: $store.prefs.backgroundStyle) {
                    ForEach(BackgroundStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Downscale Retina captures to 1×", isOn: $store.prefs.downscaleRetina)
                HStack {
                    Text("Delay before capturing")
                    Slider(value: $store.prefs.captureDelay, in: 0...10, step: 0.5)
                    Text("\(store.prefs.captureDelay, specifier: "%.1f")s").monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct OutputTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Where captures are saved") {
                HStack {
                    TextField("Folder", text: $store.prefs.saveDirectoryPath)
                    Button("Choose…") { chooseFolder() }
                    Button("Reveal") {
                        NSWorkspace.shared.open(SettingsStore.shared.saveDirectory)
                    }
                }
                TextField("File name", text: $store.prefs.fileNameTemplate)
                Text("Tokens: {date} {time} {year} {month} {day} {hour} {minute} {second} {epoch}")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Keep a `latest.png` symlink pointing at the newest capture",
                       isOn: $store.prefs.maintainLatestSymlink)
                Text("Handy for agents: tell yours to read \(SettingsStore.shared.saveDirectory.path)/latest.png and it always gets the most recent shot.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Format") {
                Toggle("Save as JPEG instead of PNG", isOn: $store.prefs.jpegInsteadOfPNG)
                if store.prefs.jpegInsteadOfPNG {
                    HStack {
                        Text("Quality")
                        Slider(value: $store.prefs.jpegQuality, in: 0.4...1.0, step: 0.05)
                        Text("\(Int(store.prefs.jpegQuality * 100))%").monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = SettingsStore.shared.saveDirectory
        if panel.runModal() == .OK, let url = panel.url {
            store.prefs.saveDirectoryPath = url.path
        }
    }
}

private struct EditorTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section("Defaults") {
                ColorPicker("Annotation colour", selection: Binding(
                    get: { Color(nsColor: NSColor(hex: store.prefs.defaultColorHex) ?? .systemRed) },
                    set: { store.prefs.defaultColorHex = NSColor($0).hexString }))
                HStack {
                    Text("Stroke width")
                    Slider(value: $store.prefs.defaultStrokeWidth, in: 1...24, step: 1)
                    Text("\(Int(store.prefs.defaultStrokeWidth))").monospacedDigit()
                }
                HStack {
                    Text("Text size")
                    Slider(value: $store.prefs.defaultFontSize, in: 10...96, step: 1)
                    Text("\(Int(store.prefs.defaultFontSize))").monospacedDigit()
                }
            }
            Section("Keyboard") {
                Text(shortcutHelp).font(.callout).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private var shortcutHelp: String {
        """
        V select · A arrow · R rectangle · E ellipse · L line · P pen · H highlighter
        T text · N step number · B blur · X pixelate · D redact · S spotlight · C crop
        F toggle fill · [ / ] stroke width · ⇧-drag constrains angle or makes a square
        ⌘Z undo · ⇧⌘Z redo · ⌘D duplicate · ⌫ delete · arrows nudge (⇧ = 10px)
        ↩ copy & close · ⌘S save as · ⇧⌘C copy file path · ⇧⌘M copy markdown
        ⇧⌘O OCR to clipboard · ⌘P pin on top · ⌘0 fit · ⌘+ / ⌘- zoom
        """
    }
}

private struct GeneralTab: View {
    @ObservedObject var store: SettingsStore
    @State private var permissionGranted = ScreenCapturer.hasPermission()

    var body: some View {
        Form {
            Section("Permissions") {
                HStack {
                    Image(systemName: permissionGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(permissionGranted ? .green : .orange)
                    Text(permissionGranted ? "Screen Recording is granted."
                                           : "Screen Recording permission is required.")
                    Spacer()
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
                Button("Re-check") { permissionGranted = ScreenCapturer.hasPermission() }
            }

            Section("Startup") {
                Toggle("Launch ImageSmith at login", isOn: Binding(
                    get: { store.prefs.launchAtLogin },
                    set: { newValue in
                        store.prefs.launchAtLogin = newValue
                        LoginItem.set(enabled: newValue)
                    }))
            }

            Section("History") {
                Stepper("Keep the last \(store.prefs.historyLimit) captures",
                        value: $store.prefs.historyLimit, in: 5...200, step: 5)
                Button("Clear history now") { CaptureStore.shared.clearHistory() }
            }

            Section {
                Button("Reset all settings") {
                    SettingsStore.shared.resetToDefaults()
                    HotKeyManager.shared.reload()
                }
            }
        }
        .formStyle(.grouped)
    }
}

enum LoginItem {
    static func set(enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("ImageSmith: login item update failed: \(error)")
        }
    }
}
