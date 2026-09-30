import Foundation

public struct CreateOptions: Equatable {
    public var format: ArchiveFormat = .zip
    /// 0 = store only, 9 = maximum.
    public var compressionLevel = 6
    /// Encrypts the archive when set (ZIP: AES-256, 7z: AES-256, DMG: AES-256).
    public var password: String?
    /// 7z only: also encrypt the file list so names are hidden without the password.
    public var encryptFileNames = true
    /// Permit falling back to legacy ZipCrypto if no AES-capable tool is installed.
    public var allowWeakZipEncryption = true
    public var filter = FileFilter()
    /// Split the finished archive into volumes of this many bytes (`.001`, `.002`, …).
    public var volumeSize: UInt64?
    /// DMG only: the volume name (defaults to the output's base name).
    public var volumeName: String?

    public init(format: ArchiveFormat = .zip, compressionLevel: Int = 6, password: String? = nil, filter: FileFilter = FileFilter()) {
        self.format = format
        self.compressionLevel = compressionLevel
        self.password = password
        self.filter = filter
    }
}

public struct CreateResult {
    /// The archive, or its volumes when split.
    public var outputs: [URL]
    public var itemCount: Int
    public var warnings: [String]
}

public enum ArchiveCreator {
    /// Whether this machine has the tools needed to create `format` (optionally encrypted).
    public static func canCreate(_ format: ArchiveFormat, encrypted: Bool = false) -> Bool {
        switch format {
        case .zip:
            if encrypted { return ToolLocator.isAvailable(.bsdtar) || ToolLocator.isAvailable(.sevenZip) || ToolLocator.isAvailable(.zip) }
            return ToolLocator.isAvailable(.bsdtar) || ToolLocator.isAvailable(.zip)
        case .sevenZip:
            return encrypted ? ToolLocator.isAvailable(.sevenZip) : (ToolLocator.isAvailable(.sevenZip) || ToolLocator.isAvailable(.bsdtar))
        case .tar, .tarGzip, .tarBzip2, .tarXz, .tarZstd, .tarLz4, .tarCompress, .xar, .iso, .cpio:
            return !encrypted && ToolLocator.isAvailable(.bsdtar)
        case .dmg:
            return ToolLocator.isAvailable(.hdiutil)
        case .gzip, .bzip2, .xz, .zstd, .brotli, .lz4:
            return !encrypted && SingleFileBackend.tool(for: format).map(ToolLocator.isAvailable) == true
        default:
            return false
        }
    }

    /// Creates an archive at `output` (replacing anything already there) from `items`.
    @discardableResult
    public static func create(_ items: [URL], at output: URL, options: CreateOptions, cancellation: Cancellation? = nil) throws -> CreateResult {
        guard !items.isEmpty else { throw ArchiveError.invalidArgument("Nothing to archive.") }
        let collected = try FileCollector.collect(items, filter: options.filter)
        guard !collected.isEmpty else { throw ArchiveError.invalidArgument("Every item was excluded by the filter settings.") }

        let fm = FileManager.default
        let work = try FileOps.makeTemporaryDirectory("create")
        defer { try? fm.removeItem(at: work) }
        let temporary = work.appendingPathComponent("archive." + options.format.preferredExtension)
        var warnings: [String] = []
        let level = max(0, min(9, options.compressionLevel))

        switch options.format {
        case .zip:
            try createZip(collected, output: temporary, level: level, options: options, work: work, warnings: &warnings, cancellation: cancellation)
        case .sevenZip:
            try createSevenZip(collected, output: temporary, level: level, options: options, work: work, cancellation: cancellation)
        case .tar, .tarGzip, .tarBzip2, .tarXz, .tarZstd, .tarLz4, .tarCompress, .xar, .iso, .cpio:
            if options.password != nil { throw ArchiveError.unsupported("\(options.format.displayName) archives cannot be encrypted. Use ZIP, 7-Zip or DMG.") }
            try runBsdtarCreate(collected, output: temporary, formatArgs: bsdtarFormatArgs(options.format, level: level), work: work, cancellation: cancellation)
        case .dmg:
            let volumeName = options.volumeName ?? ArchiveFormat.baseName(of: output.lastPathComponent)
            try createDiskImage(collected, output: temporary, level: level, password: options.password, volumeName: volumeName, work: work, cancellation: cancellation)
        case .gzip, .bzip2, .xz, .zstd, .brotli, .lz4:
            if options.password != nil { throw ArchiveError.unsupported("\(options.format.displayName) files cannot be encrypted.") }
            try compressSingleFile(collected, output: temporary, format: options.format, level: level, cancellation: cancellation)
        default:
            throw ArchiveError.unsupported("Creating \(options.format.displayName) archives is not supported.")
        }

        try cancellation?.check()
        var outputs: [URL]
        if let volumeSize = options.volumeSize, FileOps.fileSize(temporary) > volumeSize {
            let pieces = try SplitArchive.split(temporary, volumeSize: volumeSize, cancellation: cancellation)
            outputs = []
            for (index, piece) in pieces.enumerated() {
                let target = output.deletingLastPathComponent().appendingPathComponent(output.lastPathComponent + "." + String(format: "%03d", index + 1))
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: piece, to: target)
                outputs.append(target)
            }
        } else {
            try FileOps.replace(output, with: temporary)
            outputs = [output]
        }
        return CreateResult(outputs: outputs, itemCount: collected.filter { !$0.isDirectory }.count, warnings: warnings)
    }

    // MARK: ZIP

    private static func createZip(_ items: [CollectedItem], output: URL, level: Int, options: CreateOptions, work: URL, warnings: inout [String], cancellation: Cancellation?) throws {
        let isEPUB = output.pathExtension.lowercased() == "epub" || items.contains { $0.relativePath == "mimetype" } && items.contains { $0.relativePath == "META-INF" }
        if isEPUB && options.password == nil, ToolLocator.isAvailable(.zip) {
            try createEPUB(items, output: output, level: level, cancellation: cancellation)
            return
        }

        if let password = options.password {
            var failures: [String] = []
            if ToolLocator.isAvailable(.bsdtar) {
                do {
                    let args = ["--format", "zip", "--options", "zip:encryption=aes256,zip:compression-level=\(level)", "--passphrase", password]
                    try runBsdtarCreate(items, output: output, formatArgs: args, work: work, cancellation: cancellation)
                    return
                } catch ArchiveError.cancelled {
                    throw ArchiveError.cancelled
                } catch {
                    failures.append(error.localizedDescription)
                    try? FileManager.default.removeItem(at: output)
                }
            }
            if ToolLocator.isAvailable(.sevenZip) {
                try runSevenZipCreate(items, output: output, args: ["-tzip", "-mem=AES256", "-mx=\(level)", "-p" + password], cancellation: cancellation)
                return
            }
            if options.allowWeakZipEncryption, ToolLocator.isAvailable(.zip) {
                warnings.append("AES-256 is unavailable; used legacy ZipCrypto encryption, which is weak. Install 7-Zip (brew install sevenzip) for AES-256.")
                try runZipTool(items, output: output, extraArgs: ["-\(level)", "-P", password], cancellation: cancellation)
                return
            }
            throw ArchiveError.toolMissing(tool: "7zz", hint: Tool.sevenZip.installHint + (failures.isEmpty ? "" : " (\(failures.joined(separator: "; ")))"))
        }

        if ToolLocator.isAvailable(.bsdtar) {
            let compression = level == 0 ? "zip:compression=store" : "zip:compression-level=\(level)"
            try runBsdtarCreate(items, output: output, formatArgs: ["--format", "zip", "--options", compression], work: work, cancellation: cancellation)
        } else {
            try runZipTool(items, output: output, extraArgs: ["-\(level)"], cancellation: cancellation)
        }
    }

    /// EPUB requires an uncompressed `mimetype` entry first in the archive.
    private static func createEPUB(_ items: [CollectedItem], output: URL, level: Int, cancellation: Cancellation?) throws {
        let mimetype = items.filter { $0.relativePath.split(separator: "/").last == "mimetype" && $0.relativePath.split(separator: "/").count <= 2 }
        if let first = mimetype.first {
            try runZipTool([first], output: output, extraArgs: ["-0"], cancellation: cancellation)
        }
        let rest = items.filter { !mimetype.contains($0) }
        if !rest.isEmpty { try runZipTool(rest, output: output, extraArgs: ["-\(level)"], cancellation: cancellation) }
    }

    /// Runs Info-ZIP once per base folder, feeding names on stdin (appends to `output`).
    private static func runZipTool(_ items: [CollectedItem], output: URL, extraArgs: [String], cancellation: Cancellation?) throws {
        let zip = try ToolLocator.require(.zip)
        for (base, group) in grouped(items) {
            let names = group.map { $0.isDirectory ? $0.relativePath + "/" : $0.relativePath }.joined(separator: "\n") + "\n"
            let result = try ProcessRunner.run(zip, ["-q", "-X", "-y"] + extraArgs + [output.path, "-@"], currentDirectory: base, input: Data(names.utf8), cancellation: cancellation)
            guard result.status == 0 else { throw ToolErrors.map("zip", result, passwordGiven: false) }
        }
    }

    // MARK: 7z

    private static func createSevenZip(_ items: [CollectedItem], output: URL, level: Int, options: CreateOptions, work: URL, cancellation: Cancellation?) throws {
        if ToolLocator.isAvailable(.sevenZip) {
            var args = ["-t7z", "-mx=\(level)"]
            if let password = options.password {
                args.append("-p" + password)
                if options.encryptFileNames { args.append("-mhe=on") }
            }
            try runSevenZipCreate(items, output: output, args: args, cancellation: cancellation)
            return
        }
        guard options.password == nil else {
            throw ArchiveError.toolMissing(tool: "7zz", hint: "Encrypted 7-Zip archives need 7-Zip. " + Tool.sevenZip.installHint)
        }
        let compression = level == 0 ? "7zip:compression=store" : "7zip:compression-level=\(level)"
        try runBsdtarCreate(items, output: output, formatArgs: ["--format", "7zip", "--options", compression], work: work, cancellation: cancellation)
    }

    /// 7-Zip always recurses into folders it is given, so only files (and truly empty folders) are listed.
    private static func runSevenZipCreate(_ items: [CollectedItem], output: URL, args: [String], cancellation: Cancellation?) throws {
        let seven = try ToolLocator.require(.sevenZip)
        for (base, group) in grouped(items) {
            let names = group.filter { !$0.isDirectory || FileOps.contents(of: $0.url).isEmpty }.map(\.relativePath)
            if names.isEmpty { continue }
            let list = try ToolErrors.listFile(names, escapeGlobs: false)
            defer { try? FileManager.default.removeItem(at: list) }
            let result = try ProcessRunner.run(seven, ["a", "-y", "-snl", "-spd"] + args + [output.path, "@" + list.path], currentDirectory: base, cancellation: cancellation)
            guard result.status == 0 else { throw ToolErrors.map("7-Zip", result, passwordGiven: false) }
        }
    }

    // MARK: bsdtar family

    static func bsdtarFormatArgs(_ format: ArchiveFormat, level: Int) -> [String] {
        let zstdLevels = [1, 1, 2, 3, 5, 7, 9, 12, 16, 19]
        switch format {
        case .tar: return []
        case .tarGzip: return ["-z", "--options", "gzip:compression-level=\(level)"]
        case .tarBzip2: return ["-j", "--options", "bzip2:compression-level=\(max(1, level))"]
        case .tarXz: return ["-J", "--options", "xz:compression-level=\(level)"]
        case .tarZstd: return ["--zstd", "--options", "zstd:compression-level=\(zstdLevels[level])"]
        case .tarLz4: return ["--lz4", "--options", "lz4:compression-level=\(max(1, level))"]
        case .tarCompress: return ["-Z"]
        case .xar: return ["--format", "xar"]
        case .iso: return ["--format", "iso9660"]
        case .cpio: return ["--format", "cpio"]
        default: return []
        }
    }

    /// One bsdtar run with a `-T` list containing `-C base` directives, so items from several folders
    /// land at the archive root. `-n` stops bsdtar from recursing: the list is already filtered.
    private static func runBsdtarCreate(_ items: [CollectedItem], output: URL, formatArgs: [String], work: URL, cancellation: Cancellation?) throws {
        let bsdtar = try ToolLocator.require(.bsdtar)
        var lines: [String] = []
        for (base, group) in grouped(items) {
            lines += ["-C", base.path]
            lines += group.map(\.relativePath)
        }
        let list = work.appendingPathComponent("bsdtar-list-\(UUID().uuidString).txt")
        try (lines.joined(separator: "\n") + "\n").write(to: list, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: list) }
        var args = ["-c", "-f", output.path, "-n"]
        #if os(macOS)
        args.append("--no-mac-metadata")
        #endif
        args += formatArgs + ["-T", list.path]
        let result = try ProcessRunner.run(bsdtar, args, cancellation: cancellation)
        guard result.status == 0 else { throw ToolErrors.map("bsdtar", result, passwordGiven: false) }
    }

    // MARK: DMG

    private static func createDiskImage(_ items: [CollectedItem], output: URL, level: Int, password: String?, volumeName: String, work: URL, cancellation: Cancellation?) throws {
        let hdiutil = try ToolLocator.require(.hdiutil)
        let fm = FileManager.default
        // Stage a filtered copy (APFS clones make this nearly free).
        let stage = work.appendingPathComponent("stage", isDirectory: true).appendingPathComponent(volumeName, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        for item in items {
            try cancellation?.check()
            let target = stage.appendingPathComponent(item.relativePath)
            if item.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: item.url, to: target)
            }
        }
        let imageFormat: String
        switch level {
        case 0: imageFormat = "UDRO"
        case 1...5: imageFormat = "UDZO"
        case 6...8: imageFormat = "ULFO"
        default: imageFormat = "ULMO"
        }
        var args = ["create", "-quiet", "-volname", volumeName, "-srcfolder", stage.path, "-format", imageFormat, "-ov"]
        var input: Data?
        if let password {
            args += ["-encryption", "AES-256", "-stdinpass"]
            input = Data(password.utf8)
        }
        args.append(output.path)
        let result = try ProcessRunner.run(hdiutil, args, input: input, cancellation: cancellation)
        guard result.status == 0 else { throw ToolErrors.map("hdiutil", result, passwordGiven: false) }
    }

    // MARK: Single-file compressors

    private static func compressSingleFile(_ items: [CollectedItem], output: URL, format: ArchiveFormat, level: Int, cancellation: Cancellation?) throws {
        let files = items.filter { !$0.isDirectory }
        guard files.count == 1, items.count == 1 else {
            throw ArchiveError.unsupported("\(format.displayName) compresses a single file. Choose a TAR-based format (e.g. \(ArchiveFormat.tarGzip.displayName)) for folders or several files.")
        }
        guard let tool = SingleFileBackend.tool(for: format) else { throw ArchiveError.unsupported("Unsupported format.") }
        let executable = try ToolLocator.require(tool)
        let source = files[0].url.path
        let args: [String]
        switch format {
        case .gzip: args = ["-c", "-n", "-\(max(1, level))", source]
        case .bzip2: args = ["-c", "-\(max(1, level))", source]
        case .xz: args = ["-c", "-\(level)", source]
        case .zstd: args = ["-q", "-c", "-\([1, 1, 2, 3, 5, 7, 9, 12, 16, 19][level])", source]
        case .brotli: args = ["-c", "-q", "\(min(11, level == 9 ? 11 : level))", source]
        case .lz4: args = ["-q", "-c", "-\(max(1, level))", source]
        default: throw ArchiveError.unsupported("Unsupported format.")
        }
        let result = try ProcessRunner.run(executable, args, stdoutFile: output, cancellation: cancellation)
        guard result.status == 0 else { throw ToolErrors.map(tool.rawValue, result, passwordGiven: false) }
    }

    // MARK: Helpers

    /// Groups items by base folder, preserving first-seen order.
    static func grouped(_ items: [CollectedItem]) -> [(URL, [CollectedItem])] {
        var order: [URL] = []
        var groups: [URL: [CollectedItem]] = [:]
        for item in items {
            if groups[item.base] == nil { order.append(item.base) }
            groups[item.base, default: []].append(item)
        }
        return order.map { ($0, groups[$0]!) }
    }
}
