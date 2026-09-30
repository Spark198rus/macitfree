import AppKit
import ArchiveKit
import QuickLook
import SwiftUI

@MainActor
struct ArchiveWindow: View {
    let url: URL
    @StateObject private var model: ArchiveModel
    @EnvironmentObject private var state: AppState
    @State private var search = ""
    @State private var flatList = false
    @State private var sortOrder = [KeyPathComparator(\ArchiveNode.path)]
    @State private var quickLookURL: URL?
    @State private var quickLookItems: [URL] = []
    @State private var showInfo = false

    init(url: URL) {
        self.url = url
        _model = StateObject(wrappedValue: ArchiveModel(url: url))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            statusBar
        }
        .frame(minWidth: 560, minHeight: 320)
        .navigationTitle(model.title)
        .navigationSubtitle(model.subtitle)
        .toolbar { toolbar }
        .searchable(text: $search, placement: .toolbar, prompt: "Search in archive")
        .quickLookPreview($quickLookURL, in: quickLookItems)
        .dropDestination(for: URL.self) { urls, _ in
            guard model.phase == .ready, model.canModify else { return false }
            model.add(urls)
            return true
        }
        .task { if model.archive == nil { model.load() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.checkForEdits()
        }
        .alert(item: $model.pendingEdit) { edit in
            Alert(
                title: Text("Update “\((edit.path as NSString).lastPathComponent)” in the archive?"),
                message: Text("The file was changed in another app."),
                primaryButton: .default(Text("Update")) { model.applyPendingEdit() },
                secondaryButton: .cancel(Text("Don’t Update"))
            )
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Reading \(model.title)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .locked:
            VStack(spacing: 12) {
                Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("“\(model.title)” is encrypted").font(.title3)
                Text("Its file list is protected by a password.").foregroundStyle(.secondary)
                Button("Enter Password…") { model.unlock() }
                    .keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.orange)
                Text("Couldn’t open “\(model.title)”").font(.title3)
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
                Button("Try Again") { model.load() }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if flatList || !search.isEmpty {
                flatTable
            } else {
                outlineTable
            }
        }
    }

    private var outlineTable: some View {
        Table(model.rootNodes, children: \.children, selection: $model.selection) {
            TableColumn("Name") { (node: ArchiveNode) in
                NameCell(node: node, showPath: false).onDrag { model.dragProvider(for: node) }
            }
            .width(min: 180, ideal: 340)
            TableColumn("Size") { (node: ArchiveNode) in
                Text(node.sizeText).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80, max: 120)
            TableColumn("Packed") { (node: ArchiveNode) in
                Text(node.compressedText).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80, max: 120)
            TableColumn("Modified") { (node: ArchiveNode) in
                Text(node.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(ids)
        } primaryAction: { ids in
            model.open(ids)
        }
    }

    private var flatTable: some View {
        Table(sortedFlatNodes, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \ArchiveNode.path) { (node: ArchiveNode) in
                NameCell(node: node, showPath: true).onDrag { model.dragProvider(for: node) }
            }
            .width(min: 180, ideal: 340)
            TableColumn("Size", value: \ArchiveNode.size) { (node: ArchiveNode) in
                Text(node.sizeText).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80, max: 120)
            TableColumn("Packed", value: \ArchiveNode.compressedSortKey) { (node: ArchiveNode) in
                Text(node.compressedText).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80, max: 120)
            TableColumn("Modified", value: \ArchiveNode.modifiedSortKey) { (node: ArchiveNode) in
                Text(node.modified.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—").foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 150)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(ids)
        } primaryAction: { ids in
            model.open(ids)
        }
    }

    private var sortedFlatNodes: [ArchiveNode] {
        model.filteredNodes(search).sorted(using: sortOrder)
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<String>) -> some View {
        if !ids.isEmpty {
            Button("Open") { model.open(ids) }
            Button("Quick Look") { quickLook(ids) }
            Divider()
            Button("Extract…") {
                model.selection = ids
                model.extractSelectionOrAll(askDestination: true)
            }
            Button("Extract to Default Location") {
                model.selection = ids
                model.extractSelectionOrAll(askDestination: false)
            }
            Divider()
            Button("Rename…") {
                model.selection = ids
                model.renameSelection()
            }
            .disabled(!model.canModify || ids.count != 1)
            Button("Delete…") {
                model.selection = ids
                model.deleteSelection()
            }
            .disabled(!model.canModify)
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ids.sorted().joined(separator: "\n"), forType: .string)
            }
        } else {
            Button("Add Files…") { model.chooseFilesToAdd() }.disabled(!model.canModify)
            Button("New Folder…") { model.newFolder() }.disabled(!model.canModify)
        }
    }

    private func quickLook(_ ids: Set<String>? = nil) {
        let ids = ids ?? model.selection
        let nodes = ids.compactMap { model.archive?.root.node(at: $0) }.filter { !$0.isDirectory }.sorted { $0.path < $1.path }
        guard !nodes.isEmpty else { return }
        model.previewURLs(for: nodes) { urls in
            quickLookItems = urls
            quickLookURL = urls.first
        }
    }

    private func viewImages() {
        let nodes = model.imageNodes
        guard !nodes.isEmpty else { return }
        model.previewURLs(for: nodes) { urls in
            quickLookItems = urls
            quickLookURL = urls.first
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Extract to Default Location") { model.extractSelectionOrAll(askDestination: false) }
                Button("Extract To…") { model.extractSelectionOrAll(askDestination: true) }
            } label: {
                Label(model.selection.isEmpty ? "Extract All" : "Extract Selected", systemImage: "arrow.down.doc")
            } primaryAction: {
                model.extractSelectionOrAll(askDestination: false)
            }
            .help("Extract the selection (or everything) — hold the menu for more options")
            .disabled(model.phase != .ready)

            Button { model.chooseFilesToAdd() } label: { Label("Add", systemImage: "plus") }
                .help("Add files to the archive (or drop them onto the window)")
                .disabled(model.phase != .ready || !model.canModify)

            Button { model.newFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                .disabled(model.phase != .ready || !model.canModify)

            Button { model.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.phase != .ready || !model.canModify || model.selection.isEmpty)

            Button { quickLook() } label: { Label("Quick Look", systemImage: "eye") }
                .keyboardShortcut("y", modifiers: .command)
                .help("Quick Look (⌘Y)")
                .disabled(model.selection.isEmpty)

            Menu {
                Button("Test Integrity") { model.test() }
                Button("View Images…") { viewImages() }
                    .disabled(model.imageNodes.isEmpty)
                Divider()
                Button("Reveal Archive in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Reload") { model.load() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .disabled(model.phase != .ready)

            Button { showInfo.toggle() } label: { Label("Info", systemImage: "info.circle") }
                .popover(isPresented: $showInfo, arrowEdge: .bottom) { ArchiveInfoView(model: model) }
                .disabled(model.phase != .ready)

            Picker("View", selection: $flatList) {
                Label("Outline", systemImage: "list.bullet.indent").tag(false)
                Label("Flat List", systemImage: "list.bullet").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Outline or flat list of all files")
        }
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let message = model.busyMessage {
                ProgressView().controlSize(.small)
                Text(message)
                Button("Cancel") { model.cancel() }.buttonStyle(.link)
            } else if model.phase == .ready {
                let selected = model.selectedNodes
                if selected.isEmpty {
                    Text(model.subtitle)
                } else {
                    let size = selected.reduce(UInt64(0)) { $0 + $1.size }
                    Text("\(selected.count) selected · \(FileOps.formatBytes(size))")
                }
            }
            Spacer()
            if model.phase == .ready && !model.canModify {
                Label("Read-only", systemImage: "lock").labelStyle(.titleAndIcon)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

@MainActor
private struct NameCell: View {
    let node: ArchiveNode
    let showPath: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: IconCache.icon(for: node))
                .resizable()
                .frame(width: 16, height: 16)
            Text(showPath ? node.path : node.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if node.entry?.isSymlink == true {
                Image(systemName: "arrow.turn.up.right").foregroundStyle(.secondary).help(node.entry?.linkTarget ?? "Symbolic link")
            }
            if node.isEncrypted {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Encrypted")
            }
        }
    }
}

@MainActor
private struct ArchiveInfoView: View {
    @ObservedObject var model: ArchiveModel

    var body: some View {
        if let archive = model.archive {
            let packed = FileOps.fileSize(archive.workingURL)
            VStack(alignment: .leading, spacing: 10) {
                Text(model.title).font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    row("Format", archive.contentFormat.displayName + (archive.format == .split ? " (split volumes)" : ""))
                    row("Files", "\(archive.fileCount)")
                    row("Folders", "\(archive.entries.filter(\.isDirectory).count)")
                    row("Original size", FileOps.formatBytes(archive.totalSize))
                    row("Archive size", FileOps.formatBytes(packed))
                    if archive.totalSize > 0 {
                        row("Saved", String(format: "%.0f%%", max(0, (1 - Double(packed) / Double(archive.totalSize)) * 100)))
                    }
                    row("Encryption", archive.hasEncryptedListing ? "Yes, including file names" : archive.isEncrypted ? "Yes" : "None")
                    row("Editable", archive.canModify ? "Yes" : "No")
                    let methods = Set(archive.entries.compactMap(\.method)).sorted().joined(separator: ", ")
                    if !methods.isEmpty { row("Methods", methods) }
                }
                Divider()
                HStack {
                    Text("SHA-256").foregroundStyle(.secondary)
                    if let checksum = model.infoChecksum {
                        Text(checksum).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                    } else {
                        Button("Compute") { model.computeChecksum() }
                    }
                }
            }
            .padding()
            .frame(width: 380)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }
}
