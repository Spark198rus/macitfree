import Foundation

public struct ExtractOptions: Codable, Equatable, Sendable {
    public enum FolderPolicy: String, Codable, CaseIterable, Sendable {
        /// Wrap in a folder only when the archive has more than one top-level item (like Archive Utility).
        case smart
        /// Always create a folder named after the archive.
        case always
        /// Never create a folder; items land directly in the destination.
        case never

        public var displayName: String {
            switch self {
            case .smart: return "Only when needed"
            case .always: return "Always"
            case .never: return "Never"
            }
        }
    }

    public var folderPolicy: FolderPolicy = .smart
    /// Remove `__MACOSX`, `._*`, `.DS_Store`, `Thumbs.db` and friends after extracting.
    public var removeJunk = true

    public init(folderPolicy: FolderPolicy = .smart, removeJunk: Bool = true) {
        self.folderPolicy = folderPolicy
        self.removeJunk = removeJunk
    }
}

/// An opened archive: listing, extraction, integrity test and in-place modification.
/// Not thread-safe; use one instance from one queue at a time.
public final class Archive {
    /// The file the user opened (for split archives, the `.001` volume).
    public let url: URL
    /// The format of `url`.
    public let format: ArchiveFormat
    /// The file actually read: `url`, or the joined file for split archives.
    public private(set) var workingURL: URL
    /// The format of `workingURL`.
    public private(set) var contentFormat: ArchiveFormat
    public var password: String?
    public private(set) var entries: [ArchiveEntry] = []
    public private(set) var root = ArchiveNode.tree(from: [])
    /// The listing itself was encrypted (7z with encrypted headers, encrypted DMG).
    public private(set) var hasEncryptedListing = false
    public private(set) var isLoaded = false

    private var scratchDirectories: [URL] = []
    private var previewDirectory: URL?
    private var previewCache: [String: URL] = [:]

    public init(url: URL, format: ArchiveFormat? = nil) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ArchiveError.invalidArgument("“\(url.path)” does not exist.")
        }
        guard let detected = format ?? ArchiveFormat.detect(url: url) else {
            throw ArchiveError.unknownFormat(url.lastPathComponent)
        }
        self.url = url
        self.format = detected
        self.workingURL = url
        self.contentFormat = detected
    }

    deinit { cleanup() }

    /// Removes temporary files (joined volumes, previews).
    public func cleanup() {
        for dir in scratchDirectories { try? FileManager.default.removeItem(at: dir) }
        scratchDirectories.removeAll()
        previewDirectory = nil
        previewCache.removeAll()
    }

    public var displayName: String { url.lastPathComponent }
    public var isEncrypted: Bool { hasEncryptedListing || entries.contains { $0.isEncrypted } }
    public var totalSize: UInt64 { entries.reduce(0) { $0 + ($1.isDirectory ? 0 : ($1.size ?? 0)) } }
    public var fileCount: Int { entries.filter { !$0.isDirectory }.count }

    /// Whether files can be added, removed or renamed in place.
    public var canModify: Bool {
        guard format == contentFormat else { return false } // split volumes are read-only
        switch contentFormat {
        case .zip, .sevenZip, .tar, .tarGzip, .tarBzip2, .tarXz, .tarZstd, .tarLz4, .xar, .cpio:
            return ArchiveCreator.canCreate(contentFormat, encrypted: isEncrypted)
        default:
            return false
        }
    }

    private func backend() throws -> ReadBackend { try Backends.reader(for: contentFormat) }

    // MARK: Listing

    /// Lists the archive. Throws `.passwordRequired` / `.wrongPassword` when the listing is encrypted.
    public func load(cancellation: Cancellation? = nil) throws {
        if format == .split && workingURL == url {
            let dir = try FileOps.makeTemporaryDirectory("joined")
            scratchDirectories.append(dir)
            let joined = try SplitArchive.join(firstVolume: url, to: dir.appendingPathComponent(String(url.lastPathComponent.dropLast(4))), cancellation: cancellation)
            workingURL = joined
            guard let inner = ArchiveFormat.detect(url: joined), inner != .split else {
                throw ArchiveError.unknownFormat(joined.lastPathComponent)
            }
            contentFormat = inner
        }
        do {
            // Drop the archive-root entry (`./`) that some tar files carry.
            entries = try backend().list(workingURL, password: password, cancellation: cancellation).filter { !$0.path.isEmpty }
        } catch ArchiveError.passwordRequired {
            hasEncryptedListing = true
            throw ArchiveError.passwordRequired
        } catch ArchiveError.wrongPassword {
            hasEncryptedListing = true
            throw ArchiveError.wrongPassword
        }
        if password != nil && contentFormat == .dmg { hasEncryptedListing = true }
        if password != nil && contentFormat == .sevenZip && !hasEncryptedListing {
            // Detect encrypted 7z headers so rebuilds keep file names hidden.
            if (try? backend().list(workingURL, password: nil, cancellation: cancellation)) == nil { hasEncryptedListing = true }
        }
        root = ArchiveNode.tree(from: entries)
        isLoaded = true
    }

    /// Checks whether `candidate` opens this archive, without changing `password`.
    public func verify(password candidate: String, cancellation: Cancellation? = nil) -> Bool {
        let backend: ReadBackend
        do { backend = try self.backend() } catch { return false }
        if !isLoaded || hasEncryptedListing {
            return (try? backend.list(workingURL, password: candidate, cancellation: cancellation)) != nil
        }
        guard let probe = entries.filter({ $0.isEncrypted && !$0.isDirectory }).min(by: { ($0.size ?? 0) < ($1.size ?? 0) }) else {
            return true
        }
        guard let dir = try? FileOps.makeTemporaryDirectory("verify") else { return false }
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try backend.extract(workingURL, selectors: [probe.selector], to: dir, password: candidate, cancellation: cancellation)
            return true
        } catch {
            return false
        }
    }

    /// Tries each candidate (e.g. from the password vault); on success stores it in `password`.
    @discardableResult
    public func tryPasswords(_ candidates: [String], cancellation: Cancellation? = nil) -> String? {
        for candidate in candidates where verify(password: candidate, cancellation: cancellation) {
            password = candidate
            return candidate
        }
        return nil
    }

    // MARK: Extraction

    func selectors(for paths: [String]) -> [String] {
        let nodes = ArchiveNode.topMost(paths.compactMap { root.node(at: ArchiveEntry.normalize($0)) })
        return Array(Set(nodes.flatMap(\.selectors))).sorted()
    }

    /// Extracts everything (`paths == nil`) or the given items into `destination`.
    /// Returns the top-level items created in `destination`.
    @discardableResult
    public func extract(paths: [String]? = nil, to destination: URL, options: ExtractOptions = ExtractOptions(), cancellation: Cancellation? = nil) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = try FileOps.makeStagingDirectory(in: destination)
        defer { try? fm.removeItem(at: staging) }

        let selection = paths.map { $0.map(ArchiveEntry.normalize) }
        if let selection, selection.isEmpty { return [] }
        try backend().extract(workingURL, selectors: selection.map(selectors(for:)), to: staging, password: password, cancellation: cancellation)
        if options.removeJunk { FileFilter().clean(directory: staging) }
        try cancellation?.check()

        var results: [URL] = []
        if let selection {
            let nodes = ArchiveNode.topMost(selection.compactMap { root.node(at: $0) })
            for node in nodes {
                let source = staging.appendingPathComponent(node.path)
                guard fm.fileExists(atPath: source.path) || FileOps.isSymlink(source) else { continue }
                results.append(try FileOps.moveUnique(source, to: destination.appendingPathComponent(node.name)))
            }
            return results
        }

        let top = FileOps.contents(of: staging)
        let wrap: Bool
        switch options.folderPolicy {
        case .smart: wrap = top.count > 1
        case .always: wrap = true
        case .never: wrap = false
        }
        if wrap {
            let folder = FileOps.uniqueURL(for: destination.appendingPathComponent(ArchiveFormat.baseName(of: url.lastPathComponent)))
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
            for item in top { try fm.moveItem(at: item, to: folder.appendingPathComponent(item.lastPathComponent)) }
            results = [folder]
        } else {
            for item in top { results.append(try FileOps.moveUnique(item, to: destination.appendingPathComponent(item.lastPathComponent))) }
        }
        return results
    }

    /// Extracts items to a private temporary folder (for Quick Look, drag-out, "open with").
    /// Repeated calls for the same path reuse the extracted copy.
    public func extractForPreview(paths: [String], cancellation: Cancellation? = nil) throws -> [URL] {
        let fm = FileManager.default
        let normalized = paths.map(ArchiveEntry.normalize)
        let missing = normalized.filter { path in
            guard let cached = previewCache[path] else { return true }
            return !fm.fileExists(atPath: cached.path)
        }
        if !missing.isEmpty {
            if previewDirectory == nil {
                let dir = try FileOps.makeTemporaryDirectory("preview")
                scratchDirectories.append(dir)
                previewDirectory = dir
            }
            let batch = previewDirectory!.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: batch, withIntermediateDirectories: true)
            try backend().extract(workingURL, selectors: selectors(for: missing), to: batch, password: password, cancellation: cancellation)
            for path in missing {
                let url = batch.appendingPathComponent(path)
                if fm.fileExists(atPath: url.path) || FileOps.isSymlink(url) { previewCache[path] = url }
            }
        }
        return normalized.compactMap { previewCache[$0] }
    }

    // MARK: Integrity

    public func test(cancellation: Cancellation? = nil) throws {
        try backend().test(workingURL, password: password, cancellation: cancellation)
    }

    // MARK: Modification

    /// Removes entries (folders are removed with their contents).
    public func delete(paths: [String], cancellation: Cancellation? = nil) throws {
        try requireModifiable()
        let normalized = paths.map(ArchiveEntry.normalize).filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return }
        let doomed = entries.filter { entry in
            normalized.contains { entry.path == $0 || entry.path.hasPrefix($0 + "/") }
        }
        var done = false
        // Fast path: Info-ZIP deletes in place, but only matches UTF-8-flagged names reliably when ASCII.
        if contentFormat == .zip, doomed.count < entries.count, doomed.allSatisfy({ $0.rawPath.utf8.allSatisfy { $0 < 0x80 } }),
           let zip = ToolLocator.find(.zip) {
            let names = doomed.map(\.rawPath).joined(separator: "\n") + "\n"
            let result = try ProcessRunner.run(zip, ["-d", "-q", "-nw", workingURL.path, "-@"], input: Data(names.utf8), cancellation: cancellation)
            guard result.status == 0 else { throw ToolErrors.map("zip", result, passwordGiven: false) }
            try load(cancellation: cancellation)
            done = !normalized.contains { root.node(at: $0) != nil }
        }
        if !done {
            try rebuild(cancellation: cancellation) { rootDir in
                for path in normalized { try? FileManager.default.removeItem(at: rootDir.appendingPathComponent(path)) }
            }
            try load(cancellation: cancellation)
        }
        invalidatePreviews()
    }

    /// Adds files/folders into `folder` (an in-archive path; empty for the root). Existing items are replaced.
    public func add(_ files: [URL], toFolder folder: String = "", filter: FileFilter = FileFilter(), cancellation: Cancellation? = nil) throws {
        try requireModifiable()
        let folder = ArchiveEntry.normalize(folder)
        let fm = FileManager.default
        for file in files where !fm.fileExists(atPath: file.path) && !FileOps.isSymlink(file) {
            throw ArchiveError.invalidArgument("“\(file.path)” does not exist.")
        }
        if contentFormat == .zip, !isEncrypted, let zip = ToolLocator.find(.zip) {
            let stage = try FileOps.makeTemporaryDirectory("add")
            defer { try? fm.removeItem(at: stage) }
            let target = folder.isEmpty ? stage : stage.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            var staged: [URL] = []
            for file in files {
                let destination = target.appendingPathComponent(file.lastPathComponent)
                try fm.copyItem(at: file, to: destination)
                staged.append(destination)
            }
            let collected = try FileCollector.collect(staged, filter: filter)
            let prefix = folder.isEmpty ? "" : folder + "/"
            var names = collected.map { prefix + ($0.isDirectory ? $0.relativePath + "/" : $0.relativePath) }
            if !folder.isEmpty && root.node(at: folder)?.entry == nil { names.insert(folder + "/", at: 0) }
            // Info-ZIP may duplicate (rather than replace) existing non-ASCII names, so rebuild in that case.
            let replacesNonASCII = names.contains { name in
                !name.utf8.allSatisfy { $0 < 0x80 } && root.node(at: ArchiveEntry.normalize(name)) != nil
            }
            if replacesNonASCII {
                try addByRebuilding(files, folder: folder, filter: filter, cancellation: cancellation)
                return
            }
            let result = try ProcessRunner.run(zip, ["-q", "-X", "-y", workingURL.path, "-@"], currentDirectory: stage, input: Data((names.joined(separator: "\n") + "\n").utf8), cancellation: cancellation)
            guard result.status == 0 else { throw ToolErrors.map("zip", result, passwordGiven: false) }
            invalidatePreviews()
            try load(cancellation: cancellation)
        } else {
            try addByRebuilding(files, folder: folder, filter: filter, cancellation: cancellation)
        }
    }

    private func addByRebuilding(_ files: [URL], folder: String, filter: FileFilter, cancellation: Cancellation?) throws {
        let fm = FileManager.default
        try rebuild(cancellation: cancellation) { rootDir in
            let target = folder.isEmpty ? rootDir : rootDir.appendingPathComponent(folder, isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            let collected = try FileCollector.collect(files, filter: filter)
            for item in collected {
                let destination = target.appendingPathComponent(item.relativePath)
                if item.isDirectory {
                    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                } else {
                    if fm.fileExists(atPath: destination.path) || FileOps.isSymlink(destination) { try fm.removeItem(at: destination) }
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: item.url, to: destination)
                }
            }
        }
        invalidatePreviews()
        try load(cancellation: cancellation)
    }

    /// Replaces the file at `path` with the contents of `file` (used after editing in another app).
    public func replace(path: String, with file: URL, cancellation: Cancellation? = nil) throws {
        let normalized = ArchiveEntry.normalize(path)
        let parent = (normalized as NSString).deletingLastPathComponent
        let name = (normalized as NSString).lastPathComponent
        let stage = try FileOps.makeTemporaryDirectory("replace")
        defer { try? FileManager.default.removeItem(at: stage) }
        let copy = stage.appendingPathComponent(name)
        try FileManager.default.copyItem(at: file, to: copy)
        try add([copy], toFolder: parent, filter: .keepEverything, cancellation: cancellation)
    }

    /// Renames an item (keeping it in the same folder).
    public func rename(path: String, to newName: String, cancellation: Cancellation? = nil) throws {
        try requireModifiable()
        let normalized = ArchiveEntry.normalize(path)
        guard !newName.isEmpty, !newName.contains("/"), newName != ".", newName != ".." else {
            throw ArchiveError.invalidArgument("“\(newName)” is not a valid name.")
        }
        guard root.node(at: normalized) != nil else { throw ArchiveError.invalidArgument("“\(normalized)” is not in the archive.") }
        let parent = (normalized as NSString).deletingLastPathComponent
        let newPath = parent.isEmpty ? newName : parent + "/" + newName
        if root.node(at: newPath) != nil { throw ArchiveError.invalidArgument("An item named “\(newName)” already exists there.") }
        try rebuild(cancellation: cancellation) { rootDir in
            try FileManager.default.moveItem(at: rootDir.appendingPathComponent(normalized), to: rootDir.appendingPathComponent(newPath))
        }
        invalidatePreviews()
        try load(cancellation: cancellation)
    }

    /// Creates an empty folder inside the archive.
    public func makeFolder(named name: String, inFolder folder: String = "", cancellation: Cancellation? = nil) throws {
        let stage = try FileOps.makeTemporaryDirectory("mkdir")
        defer { try? FileManager.default.removeItem(at: stage) }
        let dir = stage.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try add([dir], toFolder: folder, filter: .keepEverything, cancellation: cancellation)
    }

    private func requireModifiable() throws {
        guard canModify else {
            throw ArchiveError.unsupported("\(contentFormat.displayName) archives can’t be modified here" + (ArchiveCreator.canCreate(contentFormat) ? " while encrypted without 7-Zip." : "."))
        }
        if isEncrypted && password == nil { throw ArchiveError.passwordRequired }
    }

    private func invalidatePreviews() {
        previewCache.removeAll()
    }

    /// Generic modification: extract everything, let `mutate` change the tree, re-create the archive
    /// with the same format (and password), then atomically replace the original file.
    private func rebuild(cancellation: Cancellation?, _ mutate: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let work = try FileOps.makeStagingDirectory(in: workingURL.deletingLastPathComponent())
        defer { try? fm.removeItem(at: work) }
        let rootDir = work.appendingPathComponent("root", isDirectory: true)
        try fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try backend().extract(workingURL, selectors: nil, to: rootDir, password: password, cancellation: cancellation)
        try mutate(rootDir)
        try cancellation?.check()

        let output = work.appendingPathComponent("rebuilt." + contentFormat.preferredExtension)
        let items = FileOps.contents(of: rootDir)
        if items.isEmpty {
            guard contentFormat == .zip else { throw ArchiveError.unsupported("An archive can’t be left completely empty.") }
            // An empty ZIP is just an end-of-central-directory record.
            try Data([0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)).write(to: output)
        } else {
            var options = CreateOptions(format: contentFormat, compressionLevel: 6, password: isEncrypted ? password : nil, filter: .keepEverything)
            options.encryptFileNames = hasEncryptedListing
            options.allowWeakZipEncryption = true
            try ArchiveCreator.create(items, at: output, options: options, cancellation: cancellation)
        }
        try FileOps.replace(workingURL, with: output)
    }
}
