import AppKit
import ServiceManagement
import SwiftUI

final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    @Published var shakeEnabled: Bool { didSet { defaults.set(shakeEnabled, forKey: "shakeEnabled") } }
    @Published var shakeSensitivity: Int { didSet { defaults.set(shakeSensitivity, forKey: "shakeSensitivity") } }
    @Published var notchEnabled: Bool { didSet { defaults.set(notchEnabled, forKey: "notchEnabled") } }
    @Published var collectScreenshots: Bool { didSet { defaults.set(collectScreenshots, forKey: "collectScreenshots") } }
    @Published var closeAfterDragAll: Bool { didSet { defaults.set(closeAfterDragAll, forKey: "closeAfterDragAll") } }
    @Published var watchedFolders: [String] { didSet { defaults.set(watchedFolders, forKey: "watchedFolders") } }
    @Published var dropFeedback: Bool { didSet { defaults.set(dropFeedback, forKey: "dropFeedback") } }
    @Published var clipboardHistory: Bool { didSet { defaults.set(clipboardHistory, forKey: "clipboardHistory") } }
    @Published var dropSound: String { didSet { defaults.set(dropSound, forKey: "dropSound") } }
    @Published var dropVolume: Double { didSet { defaults.set(dropVolume, forKey: "dropVolume") } }

    /// Built-in macOS alert sounds, softest first.
    static let softSounds = ["Pop", "Tink", "Bottle", "Purr", "Morse", "Glass"]
    static let otherSounds = ["Basso", "Blow", "Frog", "Funk", "Hero", "Ping", "Sosumi", "Submarine"]

    private init() {
        defaults.register(defaults: [
            "shakeEnabled": true, "shakeSensitivity": 1, "notchEnabled": true,
            "collectScreenshots": false, "closeAfterDragAll": true,
            "dropFeedback": true, "clipboardHistory": true,
            "dropSound": "Pop", "dropVolume": 0.6,
        ])
        shakeEnabled = defaults.bool(forKey: "shakeEnabled")
        shakeSensitivity = defaults.integer(forKey: "shakeSensitivity")
        notchEnabled = defaults.bool(forKey: "notchEnabled")
        collectScreenshots = defaults.bool(forKey: "collectScreenshots")
        closeAfterDragAll = defaults.bool(forKey: "closeAfterDragAll")
        watchedFolders = defaults.stringArray(forKey: "watchedFolders") ?? []
        dropFeedback = defaults.bool(forKey: "dropFeedback")
        clipboardHistory = defaults.bool(forKey: "clipboardHistory")
        dropSound = defaults.string(forKey: "dropSound") ?? "Pop"
        dropVolume = defaults.double(forKey: "dropVolume")
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shelfy").font(.headline)
                        Text("Shake the pointer while dragging, press ⌃⌥D, or drop onto the menu bar icon or notch to open a shelf.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Opening Shelves") {
                Toggle("Shake pointer while dragging to open a shelf", isOn: $settings.shakeEnabled)
                Picker("Shake sensitivity", selection: $settings.shakeSensitivity) {
                    Text("Low").tag(0)
                    Text("Medium").tag(1)
                    Text("High").tag(2)
                }
                .disabled(!settings.shakeEnabled)
                Toggle("Drop onto the MacBook notch to open a shelf", isOn: $settings.notchEnabled)
                LabeledContent("New shelf shortcut", value: "⌃⌥D")
            }

            Section("Shelves") {
                Toggle("Close shelf after dragging all items out", isOn: $settings.closeAfterDragAll)
                Toggle("Play a sound and haptic when items land", isOn: $settings.dropFeedback)
                HStack {
                    Picker("Drop sound", selection: $settings.dropSound) {
                        Section("Soft") {
                            ForEach(Settings.softSounds, id: \.self) { Text($0).tag($0) }
                        }
                        Section("Other") {
                            ForEach(Settings.otherSounds, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    .onChange(of: settings.dropSound) { Feedback.preview() }
                    Button { Feedback.preview() } label: { Image(systemName: "play.fill") }
                        .help("Preview")
                }
                .disabled(!settings.dropFeedback)
                LabeledContent("Volume") {
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $settings.dropVolume, in: 0.05...1) { editing in
                            if !editing { Feedback.preview() }
                        }
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.dropFeedback)
                Toggle("Launch at login", isOn: Binding(get: { settings.launchAtLogin },
                                                        set: { settings.launchAtLogin = $0 }))
            }

            Section {
                Toggle("Keep clipboard history", isOn: $settings.clipboardHistory)
                LabeledContent("Open Clipboard shelf", value: "⌃⌥V")
            } header: {
                Text("Clipboard")
            } footer: {
                Text("The last 60 things you copy. Content marked private by password managers is never recorded.")
            }

            Section {
                Toggle("Collect new screenshots", isOn: $settings.collectScreenshots)
                ForEach(settings.watchedFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text((path as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { settings.watchedFolders.removeAll { $0 == path } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("Add Watched Folder…") { addFolder() }
            } header: {
                Text("Automatic Collection")
            } footer: {
                Text("New files appear on a shelf named after the folder. Screenshots go to a “Screenshots” shelf.")
            }

            Section("On a Shelf") {
                Grid(alignment: .leading, verticalSpacing: 4) {
                    shortcut("Space", "Quick Look")
                    shortcut("⌘K", "Command Bar: search every action")
                    shortcut("⌘O", "Open")
                    shortcut("Return", "Rename (in the detail list)")
                    shortcut("⌫", "Remove from shelf")
                    shortcut("⌘A / ⌘C / ⌘V", "Select all / Copy / Paste onto shelf")
                    shortcut("⌘W", "Close shelf")
                    shortcut("Drag rows", "Reorder (in the detail list)")
                    shortcut("Hover the pile", "Fan out to peek at items")
                    shortcut("Drag to screen edge", "Dock the shelf")
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 780)
    }

    private func shortcut(_ key: String, _ what: String) -> some View {
        GridRow {
            Text(key).fontWeight(.medium)
            Text(what).foregroundStyle(.secondary)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.watchedFolders.contains(url.path) {
            settings.watchedFolders.append(url.path)
        }
    }
}
