import AppKit
import ArchiveKit
import SwiftUI

/// "New Archive" window: every option for one compression job, starting from a preset.
@MainActor
struct CreateArchiveView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var preset = Preset.defaults[0]
    @State private var name = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var rememberPassword = true
    @State private var splitMB = ""
    @State private var patterns = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            itemsSection
            Form {
                Picker("Start from preset:", selection: Binding(get: { preset.id }, set: { id in
                    if let chosen = state.presets.first(where: { $0.id == id }) { apply(chosen) }
                })) {
                    ForEach(state.presets) { Text($0.name).tag($0.id) }
                }
                TextField("Archive name:", text: $name)
                Picker("Format:", selection: $preset.format) {
                    ForEach(ArchiveFormat.creatable) { format in
                        Text(format.displayName + (ArchiveCreator.canCreate(format) ? "" : " (needs helper tool)"))
                            .tag(format)
                    }
                }
                .onChange(of: preset.format) { _, _ in updateNameExtension() }
                if preset.format.supportsCompressionLevel {
                    LabeledContent("Compression:") {
                        HStack {
                            Text("Store")
                            Slider(value: Binding(get: { Double(preset.compressionLevel) }, set: { preset.compressionLevel = Int($0) }), in: 0...9, step: 1)
                            Text("Max")
                        }
                    }
                }
                if preset.format.supportsEncryption {
                    Toggle("Encrypt with AES-256", isOn: $preset.encrypt)
                    if preset.encrypt {
                        SecureField("Password:", text: $password)
                        SecureField("Verify:", text: $confirmPassword)
                        HStack {
                            Toggle("Remember in password vault", isOn: $rememberPassword)
                            Spacer()
                            Button("Generate") {
                                let generated = GeneratorSettings.load().generate()
                                password = generated
                                confirmPassword = generated
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(generated, forType: .string)
                            }
                            .help("Generate a strong password and copy it to the clipboard")
                        }
                        if preset.format == .sevenZip {
                            Toggle("Also encrypt file names", isOn: $preset.encryptFileNames)
                        }
                    }
                }
                Section("Leave out") {
                    Toggle("macOS clutter (.DS_Store, ._ files, __MACOSX…)", isOn: $preset.filter.excludeMacJunk)
                    Toggle("Windows clutter (Thumbs.db, desktop.ini)", isOn: $preset.filter.excludeWindowsJunk)
                    Toggle("Version control (.git, .svn, .hg)", isOn: $preset.filter.excludeVersionControl)
                    Toggle("Build artifacts (node_modules, .build, DerivedData…)", isOn: $preset.filter.excludeBuildArtifacts)
                    Toggle("All hidden files", isOn: $preset.filter.excludeHiddenFiles)
                    TextField("Patterns:", text: $patterns, prompt: Text("*.log, *.tmp, secrets/*"))
                }
                TextField("Split into parts of (MB):", text: $splitMB, prompt: Text("no splitting"))
                Picker("Afterwards:", selection: $preset.afterCreating) {
                    ForEach(Preset.AfterCreating.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Save as Preset…") { saveAsPreset() }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create…") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.pendingCompression.isEmpty || name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear { apply(state.defaultPreset) }
        .onChange(of: state.pendingCompression) { _, _ in updateNameExtension(reset: true) }
        .dropDestination(for: URL.self) { urls, _ in
            state.pendingCompression.append(contentsOf: urls.filter { !state.pendingCompression.contains($0) })
            return true
        }
    }

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(state.pendingCompression.isEmpty ? "No files selected" : "\(state.pendingCompression.count) item\(state.pendingCompression.count == 1 ? "" : "s") to compress")
                    .font(.headline)
                Spacer()
                Button("Add…") {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = true
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK { state.pendingCompression.append(contentsOf: panel.urls) }
                }
                Button("Clear") { state.pendingCompression.removeAll() }
                    .disabled(state.pendingCompression.isEmpty)
            }
            Text(state.pendingCompression.map(\.lastPathComponent).joined(separator: ", "))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }

    private func apply(_ chosen: Preset) {
        preset = chosen
        splitMB = chosen.volumeSize.map { String($0 / (1024 * 1024)) } ?? ""
        patterns = chosen.filter.customPatterns.joined(separator: ", ")
        updateNameExtension(reset: true)
    }

    private func updateNameExtension(reset: Bool = false) {
        if reset || name.isEmpty {
            name = preset.outputName(for: state.pendingCompression)
            return
        }
        let base = ArchiveFormat.baseName(of: name)
        name = base + "." + preset.format.preferredExtension
    }

    private func effectivePreset() -> Preset {
        var result = preset
        result.filter.customPatterns = patterns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let mb = Double(splitMB.trimmingCharacters(in: .whitespaces)), mb > 0 {
            result.volumeSize = UInt64(mb * 1024 * 1024)
        } else {
            result.volumeSize = nil
        }
        return result
    }

    private func create() {
        let items = state.pendingCompression
        guard !items.isEmpty else { return }
        var job = effectivePreset()
        if job.encrypt && !job.format.supportsEncryption { job.encrypt = false }
        var jobPassword: String?
        if job.encrypt {
            guard !password.isEmpty else { return alert("Enter a password to encrypt the archive.") }
            guard password == confirmPassword else { return alert("The passwords don’t match.") }
            jobPassword = password
            if rememberPassword { PasswordVault.save(password, label: name) }
        }
        guard ArchiveCreator.canCreate(job.format, encrypted: job.encrypt) else {
            return alert("Creating \(job.format.displayName) archives\(job.encrypt ? " with encryption" : "") needs a helper tool that isn’t installed. See Settings › Helper Tools.")
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = items[0].deletingLastPathComponent()
        guard panel.runModal() == .OK, let output = panel.url else { return }
        job.destination = .ask
        state.compress(items, preset: job, password: jobPassword, outputOverride: output)
        password = ""
        confirmPassword = ""
        state.pendingCompression.removeAll()
        dismiss()
    }

    private func saveAsPreset() {
        guard let presetName = Prompts.askText(title: "Save Preset", message: "Name for this preset:", initial: preset.name, confirm: "Save") else { return }
        var newPreset = effectivePreset()
        newPreset.id = UUID()
        newPreset.name = presetName
        state.presets.append(newPreset)
        state.savePresets()
        preset = newPreset
    }

    private func alert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}
