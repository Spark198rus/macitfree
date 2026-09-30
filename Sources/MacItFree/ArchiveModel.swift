import AppKit
import ArchiveKit
import SwiftUI
import UniformTypeIdentifiers

/// View model for one archive window. All `Archive` calls run on a private serial queue.
@MainActor
final class ArchiveModel: ObservableObject {
    enum Phase: Equatable {
        case loading
        case locked
        case ready
        case failed(String)
    }

    let url: URL
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var rootNodes: [ArchiveNode] = []
    @Published private(set) var allNodes: [ArchiveNode] = []
    @Published var selection = Set<String>()
    @Published private(set) var busyMessage: String?
    @Published var pendingEdit: PendingEdit?
    @Published var infoChecksum: String?

    private(set) var archive: Archive?
    private var cancellation: Cancellation?
    private let queue = DispatchQueue(label: "MacItFree.archive", qos: .userInitiated)
    private var triedVault = false
    private var watchedEdits: [String: WatchedEdit] = [:]

    struct WatchedEdit {
        var file: URL
        var modified: Date
    }

    struct PendingEdit: Identifiable {
        var path: String
        var file: URL
        var id: String { path }
    }

    init(url: URL) {
        self.url = url
    }

    var title: String { url.lastPathComponent }
    var canModify: Bool { archive?.canModify ?? false }
    var isBusy: Bool { busyMessage != nil }

    var subtitle: String {
        guard let archive, phase == .ready else { return "" }
        var parts = ["\(archive.fileCount) files", FileOps.formatBytes(archive.totalSize)]
        if archive.isEncrypted { parts.append("encrypted") }
        if !archive.canModify { parts.append("read-only") }
        return parts.joined(separator: " · ")
    }

    var selectedNodes: [ArchiveNode] {
        guard let root = archive?.root else { return [] }
        return selection.compactMap { root.node(at: $0) }.sorted { $0.path < $1.path }
    }

    /// The in-archive folder new files go into: the selected folder, the selected file's folder, or the root.
    var targetFolder: String {
        guard selectedNodes.count == 1, let node = selectedNodes.first else { return "" }
        return node.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
    }

    func filteredNodes(_ query: String) -> [ArchiveNode] {
        let files = allNodes.filter { !$0.isDirectory }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return files }
        return allNodes.filter { $0.path.localizedCaseInsensitiveContains(trimmed) }
    }

    // MARK: Loading

    func load() {
        phase = .loading
        let archive: Archive
        do {
            archive = try self.archive ?? Archive(url: url)
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        self.archive = archive
        perform("Reading archive…", showErrors: false, { archive, cancellation in
            try archive.load(cancellation: cancellation)
        }, then: { [weak self] in
            self?.refresh()
        }, failed: { [weak self] error in
            guard let self else { return }
            if let archiveError = error as? ArchiveError, archiveError == .passwordRequired || archiveError == .wrongPassword {
                self.phase = .locked
            } else {
                self.phase = .failed(error.localizedDescription)
            }
        })
    }

    private func refresh() {
        guard let archive else { return }
        rootNodes = archive.root.childNodes
        allNodes = archive.root.descendants
        let valid = Set(allNodes.map(\.path))
        selection = selection.filter(valid.contains)
        phase = .ready
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// Tries vault passwords, then asks. Returns false when the user cancels.
    func requestPassword(wrong: Bool) -> Bool {
        guard let archive else { return false }
        if !triedVault && !wrong {
            triedVault = true
            let useVault = UserDefaults.standard.object(forKey: Defaults.tryVaultPasswords) as? Bool ?? true
            if useVault, archive.tryPasswords(PasswordVault.allPasswords()) != nil { return true }
        }
        guard let answer = Prompts.askPassword(for: archive.displayName, wrongAttempt: wrong) else { return false }
        archive.password = answer.password
        if answer.remember { PasswordVault.save(answer.password, label: archive.displayName) }
        return true
    }

    func unlock() {
        guard requestPassword(wrong: archive?.password != nil) else { return }
        load()
    }

    // MARK: Background execution

    /// Runs `work` on the archive queue. Password errors prompt for a password and retry automatically.
    func perform<T>(
        _ message: String,
        showErrors: Bool = true,
        _ work: @escaping (Archive, Cancellation) throws -> T,
        then: @escaping (T) -> Void,
        failed: ((Error) -> Void)? = nil
    ) {
        guard let archive else { return }
        let cancellation = Cancellation()
        self.cancellation = cancellation
        busyMessage = message
        queue.async {
            let result = Result { try work(archive, cancellation) }
            Task { @MainActor in
                self.busyMessage = nil
                self.cancellation = nil
                switch result {
                case let .success(value):
                    then(value)
                case let .failure(error):
                    if let archiveError = error as? ArchiveError {
                        if archiveError == .cancelled { return }
                        if archiveError == .passwordRequired || archiveError == .wrongPassword, self.phase == .ready || failed == nil {
                            if self.requestPassword(wrong: archiveError == .wrongPassword) {
                                self.perform(message, showErrors: showErrors, work, then: then, failed: failed)
                            }
                            return
                        }
                    }
                    if let failed { failed(error) }
                    if showErrors { Prompts.showError(error) }
                }
            }
        }
    }

    func cancel() { cancellation?.cancel() }

    /// Ensures the password is known before an operation that reads encrypted data.
    private func ensureDataPassword() -> Bool {
        guard let archive, archive.isEncrypted, archive.password == nil else { return true }
        return requestPassword(wrong: false)
    }

    // MARK: Extraction

    func extract(paths: [String]?, askDestination: Bool) {
        guard let archive, ensureDataPassword() else { return }
        let state = AppState.shared
        let destination = askDestination
            ? state.chooseFolder(message: "Extract to:", start: url.deletingLastPathComponent())
            : state.extractDestination(for: url)
        guard let destination else { return }
        state.extract(archive, paths: paths, to: destination) { [weak self] _ in self?.objectWillChange.send() }
    }

    func extractSelectionOrAll(askDestination: Bool) {
        let paths = selectedNodes.map(\.path)
        extract(paths: paths.isEmpty ? nil : paths, askDestination: askDestination)
    }

    /// Extracts to a private temp folder (cached) for previews and opening.
    func previewURLs(for nodes: [ArchiveNode], then: @escaping ([URL]) -> Void) {
        guard !nodes.isEmpty, ensureDataPassword() else { return }
        let paths = nodes.map(\.path)
        perform("Preparing \(nodes.count == 1 ? nodes[0].name : "\(nodes.count) items")…", { archive, cancellation in
            try archive.extractForPreview(paths: paths, cancellation: cancellation)
        }, then: then)
    }

    func open(_ ids: Set<String>) {
        guard let root = archive?.root else { return }
        let nodes = ids.compactMap { root.node(at: $0) }.filter { !$0.isDirectory }
        guard !nodes.isEmpty else { return }
        previewURLs(for: nodes) { [weak self] urls in
            guard let self else { return }
            for (node, file) in zip(nodes, urls) {
                if self.canModify, let date = Self.modificationDate(file) {
                    self.watchedEdits[node.path] = WatchedEdit(file: file, modified: date)
                }
                NSWorkspace.shared.open(file)
            }
        }
    }

    // MARK: Edit in external app

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Called when the app becomes active: offers to write back files edited in other apps.
    func checkForEdits() {
        guard pendingEdit == nil else { return }
        for (path, watched) in watchedEdits {
            guard let date = Self.modificationDate(watched.file), date > watched.modified else { continue }
            watchedEdits[path]?.modified = date
            pendingEdit = PendingEdit(path: path, file: watched.file)
            return
        }
    }

    func applyPendingEdit() {
        guard let edit = pendingEdit else { return }
        pendingEdit = nil
        perform("Updating \((edit.path as NSString).lastPathComponent)…", { archive, cancellation in
            try archive.replace(path: edit.path, with: edit.file, cancellation: cancellation)
        }, then: { [weak self] in self?.refresh() })
    }

    // MARK: Modification

    func add(_ files: [URL]) {
        guard canModify, !files.isEmpty else {
            if !canModify { NSSound.beep() }
            return
        }
        guard ensureDataPassword() else { return }
        let folder = targetFolder
        perform("Adding \(files.count) item\(files.count == 1 ? "" : "s")…", { archive, cancellation in
            try archive.add(files, toFolder: folder, cancellation: cancellation)
        }, then: { [weak self] in self?.refresh() })
    }

    func chooseFilesToAdd() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        panel.message = targetFolder.isEmpty ? "Add to \(title)" : "Add to “\(targetFolder)” in \(title)"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    func deleteSelection() {
        let nodes = ArchiveNode.topMost(selectedNodes)
        guard canModify, !nodes.isEmpty else { return }
        let what = nodes.count == 1 ? "“\(nodes[0].name)”" : "\(nodes.count) items"
        guard Prompts.confirm("Delete \(what) from the archive?", message: "This can’t be undone.", destructive: "Delete") else { return }
        guard ensureDataPassword() else { return }
        let paths = nodes.map(\.path)
        perform("Deleting…", { archive, cancellation in
            try archive.delete(paths: paths, cancellation: cancellation)
        }, then: { [weak self] in
            self?.selection.removeAll()
            self?.refresh()
        })
    }

    func renameSelection() {
        guard canModify, selectedNodes.count == 1, let node = selectedNodes.first else { return }
        guard let newName = Prompts.askText(title: "Rename “\(node.name)”", initial: node.name, confirm: "Rename"), newName != node.name else { return }
        guard ensureDataPassword() else { return }
        let path = node.path
        perform("Renaming…", { archive, cancellation in
            try archive.rename(path: path, to: newName, cancellation: cancellation)
        }, then: { [weak self] in self?.refresh() })
    }

    func newFolder() {
        guard canModify, let name = Prompts.askText(title: "New Folder", message: "Name of the new folder:", initial: "untitled folder", confirm: "Create") else { return }
        guard ensureDataPassword() else { return }
        let folder = targetFolder
        perform("Creating folder…", { archive, cancellation in
            try archive.makeFolder(named: name, inFolder: folder, cancellation: cancellation)
        }, then: { [weak self] in self?.refresh() })
    }

    // MARK: Integrity & info

    func test() {
        guard ensureDataPassword() else { return }
        perform("Testing integrity…", { archive, cancellation in
            try archive.test(cancellation: cancellation)
        }, then: { [weak self] in
            let alert = NSAlert()
            alert.messageText = "No errors found"
            alert.informativeText = "All \(self?.archive?.fileCount ?? 0) files in “\(self?.title ?? "")” passed the integrity test."
            alert.runModal()
        })
    }

    func computeChecksum() {
        let url = self.url
        infoChecksum = "Computing…"
        perform("Computing SHA-256…", { _, cancellation in
            try Checksum.sha256(of: url, cancellation: cancellation)
        }, then: { [weak self] digest in self?.infoChecksum = digest })
    }

    // MARK: Drag & drop out of the archive

    /// A lazily-extracting item provider so files can be dragged to Finder or other apps.
    func dragProvider(for node: ArchiveNode) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = node.name
        guard let archive else { return provider }
        let type: UTType = node.isDirectory ? .folder : (UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data)
        let path = node.path
        let queue = self.queue
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            queue.async {
                do {
                    let urls = try archive.extractForPreview(paths: [path])
                    completion(urls.first, false, urls.isEmpty ? ArchiveError.invalidArgument("Couldn’t extract \(path)") : nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    // MARK: Comic / image viewer

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "tif", "tiff", "bmp"]

    var imageNodes: [ArchiveNode] {
        allNodes.filter { !$0.isDirectory && Self.imageExtensions.contains(($0.name as NSString).pathExtension.lowercased()) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

extension ArchiveNode {
    var modifiedSortKey: Date { modified ?? .distantPast }
    var compressedSortKey: UInt64 { compressedSize ?? 0 }

    var sizeText: String {
        if isDirectory { return fileCount == 0 ? "—" : FileOps.formatBytes(size) }
        return entry?.size == nil ? "—" : FileOps.formatBytes(size)
    }

    var compressedText: String { compressedSize.map(FileOps.formatBytes) ?? "—" }
}

/// Finder icons for archive entries, cached per extension.
enum IconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for node: ArchiveNode) -> NSImage {
        let key = node.isDirectory ? "/folder" : (node.name as NSString).pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let type: UTType = node.isDirectory ? .folder : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}
