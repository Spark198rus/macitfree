import Foundation

/// Something that can list, extract and verify one family of archive formats.
public protocol ReadBackend {
    var name: String { get }
    func list(_ archive: URL, password: String?, cancellation: Cancellation?) throws -> [ArchiveEntry]
    /// Extracts the whole archive, or only the given selectors (entry paths as stored, folders include
    /// their contents), into `directory`, recreating the stored folder structure.
    func extract(_ archive: URL, selectors: [String]?, to directory: URL, password: String?, cancellation: Cancellation?) throws
    func test(_ archive: URL, password: String?, cancellation: Cancellation?) throws
}

enum ToolErrors {
    static let passwordMarkers = [
        "wrong password", "incorrect passphrase", "too many incorrect passphrases", "passphrase required",
        "cannot open encrypted archive", "can not open encrypted archive", "enter passphrase",
        "password is incorrect", "authentication failed", "decryption failed",
    ]

    /// Maps a failing helper result to the most useful error.
    static func map(_ tool: String, _ result: ProcessResult, passwordGiven: Bool) -> ArchiveError {
        let text = result.combinedOutput.lowercased()
        if passwordMarkers.contains(where: text.contains) {
            return passwordGiven ? .wrongPassword : .passwordRequired
        }
        let message = result.stderrString.isEmpty ? result.stdoutString : result.stderrString
        return .toolFailed(tool: tool, status: result.status, message: String(message.suffix(2000)))
    }

    /// Writes selectors to a list file, one per line.
    static func listFile(_ selectors: [String], escapeGlobs: Bool) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macitfree-list-\(UUID().uuidString).txt")
        let lines = selectors.map { escapeGlobs ? escapeGlob($0) : $0 }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func escapeGlob(_ s: String) -> String {
        var out = ""
        for c in s {
            if "*?[]\\".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}

// MARK: - bsdtar (libarchive)

public struct BsdtarBackend: ReadBackend {
    public let name = "bsdtar"
    public init() {}

    public func list(_ archive: URL, password: String?, cancellation: Cancellation?) throws -> [ArchiveEntry] {
        let tool = try ToolLocator.require(.bsdtar)
        var args = ["-tvf", archive.path]
        if let password { args += ["--passphrase", password] }
        let result = try ProcessRunner.run(tool, args, cancellation: cancellation)
        guard result.status == 0 else { throw ToolErrors.map("bsdtar", result, passwordGiven: password != nil) }
        return ListingParsers.parseBsdtarVerbose(result.stdoutString)
    }

    public func extract(_ archive: URL, selectors: [String]?, to directory: URL, password: String?, cancellation: Cancellation?) throws {
        let tool = try ToolLocator.require(.bsdtar)
        var args = ["-x", "-f", archive.path, "-C", directory.path]
        if let password { args += ["--passphrase", password] }
        var listFile: URL?
        defer { if let listFile { try? FileManager.default.removeItem(at: listFile) } }
        if let selectors {
            listFile = try ToolErrors.listFile(selectors, escapeGlobs: true)
            args += ["-T", listFile!.path]
        }
        let result = try ProcessRunner.run(tool, args, cancellation: cancellation)
        guard result.status == 0 else { throw ToolErrors.map("bsdtar", result, passwordGiven: password != nil) }
    }

    public func test(_ archive: URL, password: String?, cancellation: Cancellation?) throws {
        let tool = try ToolLocator.require(.bsdtar)
        var args = ["-x", "-O", "-f", archive.path]
        if let password { args += ["--passphrase", password] }
        let result = try ProcessRunner.run(tool, args, discardStdout: true, cancellation: cancellation)
        guard result.status == 0 else { throw ToolErrors.map("bsdtar", result, passwordGiven: password != nil) }
    }
}

// MARK: - 7-Zip

public struct SevenZipBackend: ReadBackend {
    public let name = "7-Zip"
    public init() {}

    private func passwordArg(_ password: String?) -> String {
        // An explicit (possibly empty) -p stops 7-Zip from prompting on the terminal.
        "-p" + (password ?? "")
    }

    public func list(_ archive: URL, password: String?, cancellation: Cancellation?) throws -> [ArchiveEntry] {
        let tool = try ToolLocator.require(.sevenZip)
        let result = try ProcessRunner.run(tool, ["l", "-slt", passwordArg(password), "--", archive.path], cancellation: cancellation)
        guard result.status == 0 else { throw ToolErrors.map("7-Zip", result, passwordGiven: password != nil) }
        return ListingParsers.parseSevenZipTechnical(result.stdoutString)
    }

    public func extract(_ archive: URL, selectors: [String]?, to directory: URL, password: String?, cancellation: Cancellation?) throws {
        let tool = try ToolLocator.require(.sevenZip)
        var args = ["x", "-y", "-snl", passwordArg(password), "-o" + directory.path]
        var listFile: URL?
        defer { if let listFile { try? FileManager.default.removeItem(at: listFile) } }
        if let selectors {
            // -spd: treat names literally (no wildcards). Folders include their contents.
            listFile = try ToolErrors.listFile(selectors, escapeGlobs: false)
            args += ["-spd", "-i@" + listFile!.path]
        }
        args += ["--", archive.path]
        let result = try ProcessRunner.run(tool, args, cancellation: cancellation)
        guard result.status == 0 || (result.status == 1 && !hasPasswordError(result)) else {
            throw ToolErrors.map("7-Zip", result, passwordGiven: password != nil)
        }
    }

    public func test(_ archive: URL, password: String?, cancellation: Cancellation?) throws {
        let tool = try ToolLocator.require(.sevenZip)
        let result = try ProcessRunner.run(tool, ["t", passwordArg(password), "--", archive.path], cancellation: cancellation)
        guard result.status == 0 else { throw ToolErrors.map("7-Zip", result, passwordGiven: password != nil) }
    }

    private func hasPasswordError(_ result: ProcessResult) -> Bool {
        let text = result.combinedOutput.lowercased()
        return ToolErrors.passwordMarkers.contains(where: text.contains)
    }
}

// MARK: - ZIP (native listing, tool extraction)

public struct ZipBackend: ReadBackend {
    public let name = "ZIP"
    public init() {}

    public func list(_ archive: URL, password: String?, cancellation: Cancellation?) throws -> [ArchiveEntry] {
        do {
            return try ZipReader.list(archive)
        } catch {
            // Fall back to a tool for oddities such as split or damaged archives.
            if ToolLocator.isAvailable(.sevenZip) { return try SevenZipBackend().list(archive, password: password, cancellation: cancellation) }
            return try BsdtarBackend().list(archive, password: password, cancellation: cancellation)
        }
    }

    private var extractor: ReadBackend {
        ToolLocator.isAvailable(.sevenZip) ? SevenZipBackend() : BsdtarBackend()
    }

    public func extract(_ archive: URL, selectors: [String]?, to directory: URL, password: String?, cancellation: Cancellation?) throws {
        if password == nil, try needsPassword(archive, selectors: selectors) { throw ArchiveError.passwordRequired }
        try extractor.extract(archive, selectors: selectors, to: directory, password: password, cancellation: cancellation)
    }

    public func test(_ archive: URL, password: String?, cancellation: Cancellation?) throws {
        if password == nil, try needsPassword(archive, selectors: nil) { throw ArchiveError.passwordRequired }
        try extractor.test(archive, password: password, cancellation: cancellation)
    }

    private func needsPassword(_ archive: URL, selectors: [String]?) throws -> Bool {
        guard let entries = try? ZipReader.list(archive) else { return false }
        guard let selectors else { return entries.contains { $0.isEncrypted } }
        return entries.contains { entry in
            entry.isEncrypted && selectors.contains { entry.selector == $0 || entry.selector.hasPrefix($0 + "/") }
        }
    }
}

// MARK: - Single-file compressors (gz, bz2, xz, zst, br, lz4, Z)

public struct SingleFileBackend: ReadBackend {
    public let format: ArchiveFormat
    public var name: String { format.displayName }
    public init(format: ArchiveFormat) { self.format = format }

    static func tool(for format: ArchiveFormat) -> Tool? {
        switch format {
        case .gzip, .compress: return .gzip
        case .bzip2: return .bzip2
        case .xz: return .xz
        case .zstd: return .zstd
        case .brotli: return .brotli
        case .lz4: return .lz4
        default: return nil
        }
    }

    /// Returns the tool and arguments that decompress `archive` to stdout.
    func decompressCommand(_ archive: URL) throws -> (URL, [String]) {
        if let tool = Self.tool(for: format), let url = ToolLocator.find(tool) {
            return (url, ["-d", "-c", archive.path])
        }
        if [.gzip, .bzip2, .xz, .compress].contains(format), let seven = ToolLocator.find(.sevenZip) {
            return (seven, ["e", "-so", "--", archive.path])
        }
        let tool = Self.tool(for: format) ?? .sevenZip
        throw ArchiveError.toolMissing(tool: tool.rawValue, hint: tool.installHint)
    }

    func innerName(_ archive: URL) -> String {
        let base = ArchiveFormat.baseName(of: archive.lastPathComponent)
        return base == archive.lastPathComponent ? base + ".out" : base
    }

    public func list(_ archive: URL, password: String?, cancellation: Cancellation?) throws -> [ArchiveEntry] {
        var size: UInt64?
        if format == .gzip, let handle = try? FileHandle(forReadingFrom: archive) {
            defer { try? handle.close() }
            // ISIZE: uncompressed size mod 2^32 in the last four bytes.
            if let end = try? handle.seekToEnd(), end >= 4 {
                try? handle.seek(toOffset: end - 4)
                if let b = try? handle.read(upToCount: 4), b.count == 4 {
                    size = UInt64(b[b.startIndex]) | UInt64(b[b.startIndex + 1]) << 8 | UInt64(b[b.startIndex + 2]) << 16 | UInt64(b[b.startIndex + 3]) << 24
                }
            }
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: archive.path)
        return [ArchiveEntry(
            rawPath: innerName(archive),
            size: size,
            compressedSize: (attributes?[.size] as? NSNumber)?.uint64Value,
            modified: attributes?[.modificationDate] as? Date,
            method: format.displayName
        )]
    }

    public func extract(_ archive: URL, selectors: [String]?, to directory: URL, password: String?, cancellation: Cancellation?) throws {
        let (tool, args) = try decompressCommand(archive)
        let output = directory.appendingPathComponent(innerName(archive))
        let result = try ProcessRunner.run(tool, args, stdoutFile: output, cancellation: cancellation)
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: output)
            throw ToolErrors.map(tool.lastPathComponent, result, passwordGiven: false)
        }
    }

    public func test(_ archive: URL, password: String?, cancellation: Cancellation?) throws {
        let (tool, args) = try decompressCommand(archive)
        let result = try ProcessRunner.run(tool, args, discardStdout: true, cancellation: cancellation)
        guard result.status == 0 else { throw ToolErrors.map(tool.lastPathComponent, result, passwordGiven: false) }
    }
}

// MARK: - TNEF (winmail.dat)

public struct TNEFBackend: ReadBackend {
    public let name = "TNEF"
    public init() {}

    public func list(_ archive: URL, password: String?, cancellation: Cancellation?) throws -> [ArchiveEntry] {
        try TNEF.attachments(in: archive).map {
            ArchiveEntry(rawPath: $0.fileName, size: UInt64($0.data.count), modified: $0.modified)
        }
    }

    public func extract(_ archive: URL, selectors: [String]?, to directory: URL, password: String?, cancellation: Cancellation?) throws {
        try TNEF.extract(archive, to: directory, only: selectors.map(Set.init))
    }

    public func test(_ archive: URL, password: String?, cancellation: Cancellation?) throws {
        _ = try TNEF.attachments(in: archive)
    }
}

// MARK: - Apple disk images (hdiutil, macOS only)

public struct DiskImageBackend: ReadBackend {
    public let name = "Disk Image"
    public init() {}

    public static func isEncrypted(_ image: URL) -> Bool {
        guard let hdiutil = ToolLocator.find(.hdiutil),
              let result = try? ProcessRunner.run(hdiutil, ["isencrypted", image.path]) else { return false }
        return result.stdoutString.lowercased().contains("encrypted: yes")
    }

    /// Mounts the image read-only and invisibly, runs `body` with the mount points, then detaches.
    func withMounted<T>(_ image: URL, password: String?, cancellation: Cancellation?, _ body: ([URL]) throws -> T) throws -> T {
        let hdiutil = try ToolLocator.require(.hdiutil)
        if password == nil && Self.isEncrypted(image) { throw ArchiveError.passwordRequired }
        let mountRoot = try FileOps.makeTemporaryDirectory("mount")
        defer { try? FileManager.default.removeItem(at: mountRoot) }
        var args = ["attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify", "-mountrandom", mountRoot.path, "-plist"]
        var input: Data?
        if let password {
            args.append("-stdinpass")
            input = Data(password.utf8)
        }
        args.append(image.path)
        let result = try ProcessRunner.run(hdiutil, args, input: input, cancellation: cancellation)
        guard result.status == 0 else {
            if password != nil && result.combinedOutput.lowercased().contains("authentication") { throw ArchiveError.wrongPassword }
            throw ToolErrors.map("hdiutil", result, passwordGiven: password != nil)
        }
        let mountPoints = Self.mountPoints(fromPlist: result.stdout)
        defer {
            for mp in mountPoints { _ = try? ProcessRunner.run(hdiutil, ["detach", mp.path, "-force"]) }
        }
        guard !mountPoints.isEmpty else { throw ArchiveError.corrupt("the disk image has no mountable volume") }
        return try body(mountPoints)
    }

    static func mountPoints(fromPlist data: Data) -> [URL] {
        // hdiutil may print non-plist noise before the XML.
        var data = data
        if let start = data.range(of: Data("<?xml".utf8)) { data = data.subdata(in: start.lowerBound..<data.endIndex) }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return [] }
        return entities.compactMap { $0["mount-point"] as? String }.map { URL(fileURLWithPath: $0) }
    }

    /// Paths inside the image are relative to the volume root; with several volumes they are prefixed by volume name.
    private func roots(_ mountPoints: [URL]) -> [(prefix: String, url: URL)] {
        if mountPoints.count == 1 { return [("", mountPoints[0])] }
        return mountPoints.map { ($0.lastPathComponent + "/", $0) }
    }

    public func list(_ archive: URL, password: String?, cancellation: Cancellation?) throws -> [ArchiveEntry] {
        try withMounted(archive, password: password, cancellation: cancellation) { mountPoints in
            var entries: [ArchiveEntry] = []
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            for (prefix, root) in roots(mountPoints) {
                guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { continue }
                for case let url as URL in enumerator {
                    try cancellation?.check()
                    let values = try? url.resourceValues(forKeys: Set(keys))
                    let relative = prefix + FileFilter.relativePath(of: url, in: root)
                    if relative.hasPrefix(".HFS+ Private Directory Data") || relative == ".Trashes" || relative == ".fseventsd" {
                        enumerator.skipDescendants()
                        continue
                    }
                    entries.append(ArchiveEntry(
                        rawPath: relative,
                        isDirectory: values?.isDirectory ?? false,
                        isSymlink: values?.isSymbolicLink ?? false,
                        size: values?.fileSize.map(UInt64.init),
                        modified: values?.contentModificationDate
                    ))
                }
            }
            return entries
        }
    }

    public func extract(_ archive: URL, selectors: [String]?, to directory: URL, password: String?, cancellation: Cancellation?) throws {
        try withMounted(archive, password: password, cancellation: cancellation) { mountPoints in
            let fm = FileManager.default
            for (prefix, root) in roots(mountPoints) {
                let items: [String]
                if let selectors {
                    items = selectors.filter { prefix.isEmpty || $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
                } else {
                    items = FileOps.contents(of: root).map(\.lastPathComponent)
                        .filter { ![".Trashes", ".fseventsd", ".HFS+ Private Directory Data\r"].contains($0) }
                }
                for item in items {
                    try cancellation?.check()
                    let source = root.appendingPathComponent(item)
                    let target = directory.appendingPathComponent(prefix + item)
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
                    if fm.isExecutableFile(atPath: ditto.path) {
                        let result = try ProcessRunner.run(ditto, [source.path, target.path], cancellation: cancellation)
                        if result.status != 0 { throw ToolErrors.map("ditto", result, passwordGiven: false) }
                    } else {
                        try fm.copyItem(at: source, to: target)
                    }
                }
            }
        }
    }

    public func test(_ archive: URL, password: String?, cancellation: Cancellation?) throws {
        let hdiutil = try ToolLocator.require(.hdiutil)
        var args = ["verify"]
        var input: Data?
        if let password {
            args.append("-stdinpass")
            input = Data(password.utf8)
        } else if Self.isEncrypted(archive) {
            throw ArchiveError.passwordRequired
        }
        args.append(archive.path)
        let result = try ProcessRunner.run(hdiutil, args, input: input, cancellation: cancellation)
        guard result.status == 0 else { throw ToolErrors.map("hdiutil", result, passwordGiven: password != nil) }
    }
}

// MARK: - Backend selection

public enum Backends {
    public static func reader(for format: ArchiveFormat) throws -> ReadBackend {
        switch format {
        case .zip:
            return ZipBackend()
        case .sevenZip, .rar, .cab, .arj, .lha:
            if ToolLocator.isAvailable(.sevenZip) { return SevenZipBackend() }
            if format == .arj { throw ArchiveError.toolMissing(tool: "7zz", hint: Tool.sevenZip.installHint) }
            return BsdtarBackend()
        case .tar, .tarGzip, .tarBzip2, .tarXz, .tarZstd, .tarLz4, .tarCompress, .xar, .iso, .cpio:
            if ToolLocator.isAvailable(.bsdtar) { return BsdtarBackend() }
            if ToolLocator.isAvailable(.sevenZip) && [.tar, .iso, .xar, .cpio].contains(format) { return SevenZipBackend() }
            throw ArchiveError.toolMissing(tool: "bsdtar", hint: Tool.bsdtar.installHint)
        case .dmg:
            return DiskImageBackend()
        case .gzip, .bzip2, .xz, .zstd, .brotli, .lz4, .compress:
            return SingleFileBackend(format: format)
        case .tnef:
            return TNEFBackend()
        case .split:
            throw ArchiveError.unsupported("Split archives must be joined before they can be read.")
        }
    }
}
