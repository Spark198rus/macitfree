import AppKit
import ArchiveKit
import SwiftUI

/// Collect mode: gather files from anywhere over time, then compress them together.
@MainActor
struct CollectView: View {
    @EnvironmentObject private var state: AppState
    @State private var selection = Set<URL>()
    @State private var presetID: UUID?
    @State private var targeted = false

    private var preset: Preset { state.presets.first { $0.id == presetID } ?? state.defaultPreset }

    var body: some View {
        VStack(spacing: 10) {
            if state.basket.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 36, weight: .light))
                    Text("Drop files here to collect them").foregroundStyle(.secondary)
                    Text("Keep adding from different folders, then compress everything at once.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06)))
            } else {
                List(state.basket, id: \.self, selection: $selection) { url in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                        Text(url.lastPathComponent)
                        Spacer()
                        Text(url.deletingLastPathComponent().lastPathComponent).foregroundStyle(.secondary)
                    }
                }
                .onDeleteCommand { removeSelected() }
            }
            Picker("Preset:", selection: Binding(get: { preset.id }, set: { presetID = $0 })) {
                ForEach(state.presets) { Text($0.name).tag($0.id) }
            }
            HStack {
                Button("Remove") { removeSelected() }.disabled(selection.isEmpty)
                Button("Clear") { state.basket.removeAll() }.disabled(state.basket.isEmpty)
                Spacer()
                Button("Options…") {
                    state.showCreateWindow(state.basket)
                    state.basket.removeAll()
                }
                .disabled(state.basket.isEmpty)
                Button("Compress") {
                    state.compress(state.basket, preset: preset)
                    state.basket.removeAll()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.basket.isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 340, minHeight: 320)
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls where !state.basket.contains(url) { state.basket.append(url) }
            return true
        } isTargeted: { targeted = $0 }
    }

    private func removeSelected() {
        state.basket.removeAll { selection.contains($0) }
        selection.removeAll()
    }
}

/// SHA-256 checksum calculator and verifier.
@MainActor
struct ChecksumView: View {
    @State private var file: URL?
    @State private var digest = ""
    @State private var expected = ""
    @State private var progress: Double?
    @State private var cancellation: Cancellation?
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.badge.gearshape").font(.largeTitle).foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text(file?.lastPathComponent ?? "Drop a file or choose one").font(.headline)
                    if let file { Text(FileOps.formatBytes(FileOps.fileSize(file))).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    if panel.runModal() == .OK, let url = panel.url { compute(url) }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(targeted ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.06)))

            if let progress {
                HStack {
                    ProgressView(value: progress)
                    Button("Cancel") { cancellation?.cancel() }
                }
            }
            LabeledContent("SHA-256") {
                HStack {
                    Text(digest.isEmpty ? "—" : digest)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                    if !digest.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(digest, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("Copy")
                    }
                }
            }
            TextField("Expected checksum (paste to verify)", text: $expected)
                .font(.system(.body, design: .monospaced))
            if !digest.isEmpty && !expected.isEmpty {
                if Checksum.matches(digest, expected: expected) {
                    Label("Checksums match", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Label("Checksums do NOT match", systemImage: "xmark.seal.fill").foregroundStyle(.red)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, !FileOps.isDirectory(url) else { return false }
            compute(url)
            return true
        } isTargeted: { targeted = $0 }
    }

    private func compute(_ url: URL) {
        cancellation?.cancel()
        let token = Cancellation()
        cancellation = token
        file = url
        digest = ""
        progress = 0
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try Checksum.sha256(of: url, cancellation: token) { fraction in
                        Task { @MainActor in if cancellation === token { progress = fraction } }
                    }
                }
            }.value
            guard cancellation === token else { return }
            progress = nil
            cancellation = nil
            switch result {
            case let .success(value): digest = value
            case let .failure(error): if (error as? ArchiveError) != .cancelled { Prompts.showError(error) }
            }
        }
    }
}

/// Strong password generator (settings are remembered).
@MainActor
struct GeneratorView: View {
    @State private var generator = GeneratorSettings.load()
    @State private var password = ""
    @State private var saveLabel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(password)
                    .font(.system(.title3, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { regenerate() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Generate another")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(password, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy to clipboard")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            Form {
                Stepper("Length: \(generator.length)", value: $generator.length, in: 8...128)
                Toggle("Uppercase letters (A–Z)", isOn: $generator.includeUppercase)
                Toggle("Lowercase letters (a–z)", isOn: $generator.includeLowercase)
                Toggle("Digits (0–9)", isOn: $generator.includeDigits)
                Toggle("Symbols (!#$%…)", isOn: $generator.includeSymbols)
                Toggle("Avoid look-alikes (l, 1, I, O, 0)", isOn: $generator.avoidAmbiguous)
                LabeledContent("Strength") {
                    Text("≈ \(Int(generator.entropyBits)) bits")
                        .foregroundStyle(generator.entropyBits >= 80 ? Color.green : generator.entropyBits >= 60 ? Color.orange : Color.red)
                }
            }
            HStack {
                TextField("Label", text: $saveLabel, prompt: Text("e.g. Tax documents 2026"))
                Button("Save to Vault") {
                    PasswordVault.save(password, label: saveLabel)
                    saveLabel = ""
                }
                .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { regenerate() }
        .onChange(of: generator) { _, newValue in
            GeneratorSettings.save(newValue)
            regenerate()
        }
    }

    private func regenerate() { password = generator.generate() }
}
