import Foundation

/// Every archive/compression format MacItFree knows how to open and/or create.
public enum ArchiveFormat: String, CaseIterable, Codable, Sendable, Identifiable {
    case zip
    case sevenZip = "7z"
    case rar
    case tar
    case tarGzip = "tar.gz"
    case tarBzip2 = "tar.bz2"
    case tarXz = "tar.xz"
    case tarZstd = "tar.zst"
    case tarLz4 = "tar.lz4"
    case tarCompress = "tar.Z"
    case xar
    case iso
    case cpio
    case cab
    case lha
    case arj
    case dmg
    case gzip = "gz"
    case bzip2 = "bz2"
    case xz
    case zstd = "zst"
    case brotli = "br"
    case lz4
    case compress = "Z"
    /// Split volumes (`name.ext.001`, `name.ext.002`, …) that are joined before opening.
    case split = "001"
    /// Outlook `winmail.dat` / TNEF attachments container.
    case tnef

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .zip: return "ZIP"
        case .sevenZip: return "7-Zip"
        case .rar: return "RAR"
        case .tar: return "TAR"
        case .tarGzip: return "TAR + Gzip"
        case .tarBzip2: return "TAR + Bzip2"
        case .tarXz: return "TAR + XZ"
        case .tarZstd: return "TAR + Zstandard"
        case .tarLz4: return "TAR + LZ4"
        case .tarCompress: return "TAR + Compress"
        case .xar: return "XAR"
        case .iso: return "ISO 9660 Image"
        case .cpio: return "CPIO"
        case .cab: return "Microsoft Cabinet"
        case .lha: return "LHA/LZH"
        case .arj: return "ARJ"
        case .dmg: return "Apple Disk Image"
        case .gzip: return "Gzip"
        case .bzip2: return "Bzip2"
        case .xz: return "XZ"
        case .zstd: return "Zstandard"
        case .brotli: return "Brotli"
        case .lz4: return "LZ4"
        case .compress: return "Unix Compress"
        case .split: return "Split Archive"
        case .tnef: return "Winmail.dat (TNEF)"
        }
    }

    /// The extension used when creating an archive of this format.
    public var preferredExtension: String {
        switch self {
        case .split: return "001"
        case .tnef: return "dat"
        default: return rawValue
        }
    }

    /// All file extensions (lowercased, without dot) that map to this format.
    public var extensions: [String] {
        switch self {
        case .zip:
            return ["zip", "zipx", "cbz", "epub", "jar", "war", "ear", "apk", "aar", "ipa", "xpi", "crx",
                    "docx", "xlsx", "pptx", "odt", "ods", "odp", "sketch", "whl", "nupkg", "vsix"]
        case .sevenZip: return ["7z", "cb7"]
        case .rar: return ["rar", "cbr"]
        case .tar: return ["tar", "cbt"]
        case .tarGzip: return ["tar.gz", "tgz", "taz"]
        case .tarBzip2: return ["tar.bz2", "tbz", "tbz2", "tb2", "tar.bz"]
        case .tarXz: return ["tar.xz", "txz", "tar.lzma", "tlz"]
        case .tarZstd: return ["tar.zst", "tar.zstd", "tzst"]
        case .tarLz4: return ["tar.lz4", "tlz4"]
        case .tarCompress: return ["tar.z", "tz"]
        case .xar: return ["xar", "pkg", "xip"]
        case .iso: return ["iso"]
        case .cpio: return ["cpio"]
        case .cab: return ["cab"]
        case .lha: return ["lha", "lzh"]
        case .arj: return ["arj"]
        case .dmg: return ["dmg", "sparseimage", "sparsebundle"]
        case .gzip: return ["gz", "gzip"]
        case .bzip2: return ["bz2", "bzip2"]
        case .xz: return ["xz", "lzma"]
        case .zstd: return ["zst", "zstd"]
        case .brotli: return ["br"]
        case .lz4: return ["lz4"]
        case .compress: return ["z"]
        case .split: return ["001"]
        case .tnef: return ["tnef"]
        }
    }

    /// A format that compresses exactly one file (no directory structure).
    public var isSingleFileCompressor: Bool {
        switch self {
        case .gzip, .bzip2, .xz, .zstd, .brotli, .lz4, .compress: return true
        default: return false
        }
    }

    public var isTarFamily: Bool {
        switch self {
        case .tar, .tarGzip, .tarBzip2, .tarXz, .tarZstd, .tarLz4, .tarCompress: return true
        default: return false
        }
    }

    /// Formats offered in "create archive" UIs, in display order.
    public static let creatable: [ArchiveFormat] = [
        .zip, .sevenZip, .tarGzip, .tarBzip2, .tarXz, .tarZstd, .tar, .dmg, .xar, .iso, .cpio,
        .gzip, .bzip2, .xz, .zstd, .brotli, .lz4,
    ]

    /// Whether the format itself can carry encryption when created with MacItFree.
    public var supportsEncryption: Bool {
        switch self {
        case .zip, .sevenZip, .dmg: return true
        default: return false
        }
    }

    /// Compression levels are meaningful (0 = store, 9 = maximum).
    public var supportsCompressionLevel: Bool {
        switch self {
        case .tar, .xar, .iso, .cpio, .split, .tnef, .rar, .cab, .lha, .arj, .compress, .tarCompress: return false
        default: return true
        }
    }

    // MARK: - Detection

    /// Detects a format from the file name, falling back to magic bytes.
    public static func detect(url: URL) -> ArchiveFormat? {
        if let byName = detect(fileName: url.lastPathComponent) { return byName }
        return detect(magicOf: url)
    }

    /// Detects a format from a file name only (longest matching extension wins).
    public static func detect(fileName: String) -> ArchiveFormat? {
        let lower = fileName.lowercased()
        if lower == "winmail.dat" || lower.hasSuffix(".tnef") { return .tnef }
        if SplitArchive.isFirstVolume(fileName: fileName) { return .split }
        var best: (ArchiveFormat, Int)?
        for format in allCases where format != .tnef && format != .split {
            for ext in format.extensions where lower.hasSuffix("." + ext) {
                if best == nil || ext.count > best!.1 { best = (format, ext.count) }
            }
        }
        // `foo.z` should be compress, but `foo.tar.z` is tar+compress; handled by longest match above.
        return best?.0
    }

    /// Detects a format by sniffing the first bytes of the file.
    public static func detect(magicOf url: URL) -> ArchiveFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 0x8006)) ?? Data()
        if let format = detect(magic: head) { return format }
        // UDIF disk images carry a "koly" trailer 512 bytes before EOF.
        if let end = try? handle.seekToEnd(), end >= 512 {
            try? handle.seek(toOffset: end - 512)
            if let trailer = try? handle.read(upToCount: 4), trailer == Data("koly".utf8) { return .dmg }
        }
        return nil
    }

    public static func detect(magic data: Data) -> ArchiveFormat? {
        let b = [UInt8](data.prefix(0x8006))
        func starts(_ sig: [UInt8], at offset: Int = 0) -> Bool {
            guard b.count >= offset + sig.count else { return false }
            return Array(b[offset..<offset + sig.count]) == sig
        }
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) || starts([0x50, 0x4B, 0x07, 0x08]) { return .zip }
        if starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        if starts([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return .rar }
        if starts([0x78, 0x9F, 0x3E, 0x22]) { return .tnef }
        if starts([0x78, 0x61, 0x72, 0x21]) { return .xar }
        if starts([0x4D, 0x53, 0x43, 0x46]) { return .cab }
        if starts([0x60, 0xEA]) { return .arj }
        if starts(Array("-lh".utf8), at: 2) { return .lha }
        if starts(Array("ustar".utf8), at: 257) { return .tar }
        if starts(Array("070707".utf8)) || starts(Array("070701".utf8)) || starts(Array("070702".utf8)) || starts([0xC7, 0x71]) { return .cpio }
        if starts(Array("CD001".utf8), at: 0x8001) { return .iso }
        if starts([0x1F, 0x8B]) { return .gzip }
        if starts(Array("BZh".utf8)) { return .bzip2 }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if starts([0x28, 0xB5, 0x2F, 0xFD]) { return .zstd }
        if starts([0x04, 0x22, 0x4D, 0x18]) { return .lz4 }
        if starts([0x1F, 0x9D]) { return .compress }
        return nil
    }

    /// Strips the archive extension from a file name: `photos.tar.gz` → `photos`.
    public static func baseName(of fileName: String) -> String {
        let lower = fileName.lowercased()
        if lower == "winmail.dat" { return "winmail" }
        if SplitArchive.isFirstVolume(fileName: fileName) {
            return baseName(of: String(fileName.dropLast(4)))
        }
        var longest = 0
        for format in allCases {
            for ext in format.extensions where lower.hasSuffix("." + ext) && ext.count > longest {
                longest = ext.count
            }
        }
        if longest > 0 && fileName.count > longest + 1 {
            return String(fileName.dropLast(longest + 1))
        }
        return (fileName as NSString).deletingPathExtension
    }
}
