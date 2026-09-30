import AppKit
import ArchiveKit
import SwiftUI
import UniformTypeIdentifiers

/// The main window: two drop zones (compress / extract), quick actions, recent archives and activity.
@MainActor
struct WelcomeView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var presetID: UUID?
    @State private var compressTargeted = false
    @State private var extractTargeted = false

    private var selectedPreset: Preset {
        state.presets.first { $0.id == presetID } ?? state.defaultPreset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                DropZone(
                    title: "Compress",
                    subtitle: "Drop files and folders",
                    systemImage: "archivebox",
                    isTargeted: $compressTargeted
                ) { urls in
                    state.compress(urls, preset: selectedPreset)
                } onClick: {
                    state.chooseFilesToCompress()
                }
                DropZone(
                    title: "Extract",
                    subtitle: "Drop archives",
                    systemImage: "arrow.up.bin",
                    isTargeted: $extractTargeted
                ) { urls in
                    state.extract(urls)
                } onClick: {
                    let panel = NSOpenPanel()
                    panel.allowsMultipleSelection = true
                    panel.message = "Choose archives to extract"
                    if panel.runModal() == .OK { state.extract(panel.urls) }
                }
            }
            .frame(height: 170)

            HStack {
                Picker("Preset:", selection: Binding(get: { selectedPreset.id }, set: { presetID = $0 })) {
                    ForEach(state.presets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .frame(maxWidth: 360)
                Spacer()
                Button("Open Archive…") { state.chooseAndOpenArchives() }
                Button("Options…") { state.chooseFilesToCompress() }
                    .help("Choose files and set every archiving option")
            }

            HStack(spacing: 12) {
                Button { openWindow(id: "collect") } label: { Label("Collect Basket", systemImage: "tray.full") }
                Button { openWindow(id: "checksum") } label: { Label("Checksum", systemImage: "number") }
                Button { openWindow(id: "generator") } label: { Label("Password Generator", systemImage: "key") }
                Spacer()
                SettingsLink { Label("Settings", systemImage: "gearshape") }
            }
            .buttonStyle(.borderless)

            if !state.activities.isEmpty {
                ActivityList()
            } else if !state.recentArchives.isEmpty {
                recentList
            } else {
                Spacer(minLength: 0)
                Text("Tip: right-click files in Finder › Quick Actions / Services › “Compress with MacItFree”, or drag MacItFree.app into a Finder toolbar with ⌘ held.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 440)
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Archives").font(.headline)
            List(state.recentArchives.prefix(8), id: \.self) { url in
                Button {
                    state.openArchiveWindow(url)
                } label: {
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                        Text(url.lastPathComponent)
                        Spacer()
                        Text(url.deletingLastPathComponent().path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }
}

@MainActor
struct DropZone: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 42, weight: .light))
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isTargeted ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            onDrop(urls)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

@MainActor
struct ActivityList: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                Button("Clear") { state.clearFinishedActivities() }
                    .buttonStyle(.link)
                    .disabled(!state.activities.contains { !$0.isRunning })
            }
            List(state.activities) { activity in
                ActivityRow(activity: activity)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }
}

@MainActor
struct ActivityRow: View {
    @ObservedObject var activity: Activity

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch activity.state {
                case .running: ProgressView().controlSize(.small)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(activity.title).lineLimit(1).truncationMode(.middle)
                Text(statusText).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            Spacer()
            if activity.isRunning {
                Button("Cancel") { activity.cancellation.cancel() }.buttonStyle(.link)
            } else if !activity.resultURLs.isEmpty {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(activity.resultURLs)
                } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        switch activity.state {
        case .running: return activity.detail
        case let .done(message): return message
        case let .failed(message): return message
        case .cancelled: return "Cancelled"
        }
    }
}
