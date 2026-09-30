import AppKit
import ArchiveKit
import SwiftUI

@MainActor
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            PresetSettings().tabItem { Label("Presets", systemImage: "slider.horizontal.3") }
            VaultSettings().tabItem { Label("Passwords", systemImage: "key") }
            ToolSettings().tabItem { Label("Helper Tools", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 640, height: 480)
    }
}

@MainActor
private struct GeneralSettings: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(Defaults.extractDestinationMode) private var destinationMode = ExtractDestinationMode.sameFolder.rawValue
    @AppStorage(Defaults.extractFixedFolder) private var fixedFolder = ""
    @AppStorage(Defaults.revealAfterExtract) private var revealAfterExtract = false
    @AppStorage(Defaults.trashArchiveAfterExtract) private var trashArchive = false
    @AppStorage(Defaults.finderOpenAction) private var finderOpenAction = FinderOpenAction.browse.rawValue
    @AppStorage(Defaults.defaultPresetID) private var defaultPresetID = ""
    @AppStorage(Defaults.tryVaultPasswords) private var tryVault = true

    var body: some View {
        Form {
            Section("Extracting") {
                Picker("Extract to:", selection: $destinationMode) {
                    ForEach(ExtractDestinationMode.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                if destinationMode == ExtractDestinationMode.fixed.rawValue {
                    HStack {
                        Text(fixedFolder.isEmpty ? "No folder chosen" : fixedFolder).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = false
                            panel.canChooseDirectories = true
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url { fixedFolder = url.path }
                        }
                    }
                }
                Picker("Create a folder:", selection: Binding(get: { state.extractOptions.folderPolicy }, set: {
                    state.extractOptions.folderPolicy = $0
                    state.saveExtractOptions()
                })) {
                    ForEach(ExtractOptions.FolderPolicy.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Remove macOS/Windows clutter (__MACOSX, .DS_Store, Thumbs.db…)", isOn: Binding(get: { state.extractOptions.removeJunk }, set: {
                    state.extractOptions.removeJunk = $0
                    state.saveExtractOptions()
                }))
                Toggle("Reveal extracted items in Finder", isOn: $revealAfterExtract)
                Toggle("Move archive to Trash after extracting everything", isOn: $trashArchive)
            }
            Section("Opening from Finder and the Dock") {
                Picker("When opening an archive:", selection: $finderOpenAction) {
                    ForEach(FinderOpenAction.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                Picker("Default preset (Services, Dock):", selection: $defaultPresetID) {
                    ForEach(state.presets) { Text($0.name).tag($0.id.uuidString) }
                }
                Toggle("Try saved passwords automatically", isOn: $tryVault)
            }
            Section("Finder integration") {
                Text("Right-click files in Finder › Quick Actions (or Services) to compress, extract, browse or collect with MacItFree. If the items don’t appear, enable them in System Settings › Keyboard › Keyboard Shortcuts › Services, and make sure MacItFree.app is in /Applications.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Refresh Services Menu") { NSUpdateDynamicServices() }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if defaultPresetID.isEmpty { defaultPresetID = state.defaultPreset.id.uuidString }
        }
    }
}

@MainActor
private struct PresetSettings: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(state.presets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                    .onMove { from, to in
                        state.presets.move(fromOffsets: from, toOffset: to)
                        state.savePresets()
                    }
                }
                HStack(spacing: 0) {
                    Button { addPreset() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                    Button { removePreset() } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .disabled(selectedID == nil || state.presets.count <= 1)
                    Button { duplicatePreset() } label: { Image(systemName: "plus.square.on.square").frame(width: 24, height: 20) }
                        .disabled(selectedID == nil)
                    Spacer()
                    Button("Reset") {
                        if Prompts.confirm("Reset all presets?", message: "Your presets will be replaced by the built-in ones.", destructive: "Reset") {
                            state.presets = Preset.defaults
                            state.savePresets()
                            selectedID = state.presets.first?.id
                        }
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 220)
            Divider()
            if let index = state.presets.firstIndex(where: { $0.id == selectedID }) {
                PresetEditor(preset: Binding(get: { state.presets[index] }, set: { state.presets[index] = $0 }))
                    .id(state.presets[index].id)
            } else {
                Text("Select a preset").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selectedID == nil { selectedID = state.presets.first?.id } }
        .onDisappear { state.savePresets() }
    }

    private func addPreset() {
        let preset = Preset(name: "New Preset", format: .zip)
        state.presets.append(preset)
        selectedID = preset.id
        state.savePresets()
    }

    private func duplicatePreset() {
        guard let original = state.presets.first(where: { $0.id == selectedID }) else { return }
        var copy = original
        copy.id = UUID()
        copy.name += " copy"
        state.presets.append(copy)
        selectedID = copy.id
        state.savePresets()
    }

    private func removePreset() {
        guard state.presets.count > 1 else { return }
        state.presets.removeAll { $0.id == selectedID }
        selectedID = state.presets.first?.id
        state.savePresets()
    }
}

@MainActor
private struct PresetEditor: View {
    @Binding var preset: Preset
    @State private var patterns = ""
    @State private var splitMB = ""
    @State private var maxSizeMB = ""

    var body: some View {
        Form {
            TextField("Name:", text: $preset.name)
            Picker("Format:", selection: $preset.format) {
                ForEach(ArchiveFormat.creatable) { Text($0.displayName).tag($0) }
            }
            if preset.format.supportsCompressionLevel {
                Stepper("Compression level: \(preset.compressionLevel)\(preset.compressionLevel == 0 ? " (store)" : preset.compressionLevel == 9 ? " (max)" : "")",
                        value: $preset.compressionLevel, in: 0...9)
            }
            if preset.format.supportsEncryption {
                Toggle("Encrypt (asks for a password)", isOn: $preset.encrypt)
                if preset.format == .sevenZip && preset.encrypt {
                    Toggle("Encrypt file names", isOn: $preset.encryptFileNames)
                }
            }
            Section("Leave out") {
                Toggle("macOS clutter", isOn: $preset.filter.excludeMacJunk)
                Toggle("Windows clutter", isOn: $preset.filter.excludeWindowsJunk)
                Toggle("Version control folders", isOn: $preset.filter.excludeVersionControl)
                Toggle("Build artifacts & dependencies", isOn: $preset.filter.excludeBuildArtifacts)
                Toggle("Hidden files", isOn: $preset.filter.excludeHiddenFiles)
                TextField("Patterns:", text: $patterns, prompt: Text("*.log, *.tmp"))
                    .onChange(of: patterns) { _, value in
                        preset.filter.customPatterns = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                TextField("Skip files larger than (MB):", text: $maxSizeMB, prompt: Text("no limit"))
                    .onChange(of: maxSizeMB) { _, value in
                        preset.filter.maximumFileSize = Double(value).flatMap { $0 > 0 ? UInt64($0 * 1024 * 1024) : nil }
                    }
            }
            Section("Output") {
                TextField("Split into parts of (MB):", text: $splitMB, prompt: Text("no splitting"))
                    .onChange(of: splitMB) { _, value in
                        preset.volumeSize = Double(value).flatMap { $0 > 0 ? UInt64($0 * 1024 * 1024) : nil }
                    }
                Picker("Save to:", selection: destinationKind) {
                    Text("Same folder as the originals").tag(0)
                    Text("Ask every time").tag(1)
                    Text("A fixed folder").tag(2)
                }
                if case let .folder(path) = preset.destination {
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Picker("Afterwards:", selection: $preset.afterCreating) {
                    ForEach(Preset.AfterCreating.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            patterns = preset.filter.customPatterns.joined(separator: ", ")
            splitMB = preset.volumeSize.map { String($0 / (1024 * 1024)) } ?? ""
            maxSizeMB = preset.filter.maximumFileSize.map { String($0 / (1024 * 1024)) } ?? ""
        }
    }

    private var destinationKind: Binding<Int> {
        Binding(get: {
            switch preset.destination {
            case .sameFolder: return 0
            case .ask: return 1
            case .folder: return 2
            }
        }, set: { kind in
            switch kind {
            case 0: preset.destination = .sameFolder
            case 1: preset.destination = .ask
            default: chooseFolder()
            }
        })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { preset.destination = .folder(url.path) }
    }
}

@MainActor
private struct VaultSettings: View {
    @State private var items: [PasswordVault.Item] = []
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved passwords live in your macOS Keychain. When you open an encrypted archive, MacItFree tries them automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
            List(items, selection: $selection) { item in
                Label(item.label, systemImage: "key.fill").tag(item.id)
            }
            HStack {
                Button("Add…") { add() }
                Button("Remove") {
                    if let selection { PasswordVault.delete(label: selection) }
                    reload()
                }
                .disabled(selection == nil)
                Button("Copy Password") {
                    if let selection, let password = PasswordVault.password(for: selection) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(password, forType: .string)
                    }
                }
                .disabled(selection == nil)
                Spacer()
                Button("Open Password Generator") { AppState.shared.openWindow(id: "generator") }
            }
        }
        .padding()
        .onAppear { reload() }
    }

    private func reload() { items = PasswordVault.items() }

    private func add() {
        guard let answer = Prompts.askNewPassword(title: "Add a password to the vault"),
              let label = Prompts.askText(title: "Label", message: "A name to recognise this password by:", initial: "", confirm: "Save") else { return }
        PasswordVault.save(answer.password, label: label)
        reload()
    }
}

@MainActor
private struct ToolSettings: View {
    @State private var refresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MacItFree drives proven command-line archivers. The essentials ship with macOS; install the optional ones with Homebrew for extra formats (e.g. 7-Zip for creating .7z and reading RAR).")
                .font(.callout)
                .foregroundStyle(.secondary)
            Table(Tool.allCases.map(ToolRow.init)) {
                TableColumn("Tool") { (row: ToolRow) in Text(row.tool.rawValue).fontWeight(.medium) }
                    .width(70)
                TableColumn("Status") { (row: ToolRow) in
                    if let path = row.path {
                        Label(path, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1).truncationMode(.head)
                    } else {
                        Label(row.tool.installHint, systemImage: "circle.dashed").foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .id(refresh)
            HStack {
                Spacer()
                Button("Copy Homebrew Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install sevenzip xz zstd brotli lz4", forType: .string)
                }
                Button("Check Again") {
                    ToolLocator.resetCache()
                    refresh += 1
                }
            }
        }
        .padding()
    }
}

private struct ToolRow: Identifiable {
    let tool: Tool
    let path: String?
    var id: String { tool.rawValue }

    init(_ tool: Tool) {
        self.tool = tool
        self.path = ToolLocator.find(tool)?.path
    }
}
