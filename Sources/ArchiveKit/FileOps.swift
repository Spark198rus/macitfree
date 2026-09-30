import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Small file-system helpers shared by the library, CLI and app.
public enum FileOps {
    /// Returns `url` if nothing exists there, otherwise `name 2.ext`, `name 3.ext`, … (Finder style).
    public static func uniqueURL(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) || isSymlink(url) else { return url }
        let dir = url.deletingLastPathComponent()
        let fileName = url.lastPathComponent
        let base = ArchiveFormat.baseName(of: fileName)
        let suffix = String(fileName.dropFirst(base.count)) // keeps compound extensions like .tar.gz
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent("\(base) \(n)\(suffix)")
            if !fm.fileExists(atPath: candidate.path) && !isSymlink(candidate) { return candidate }
            n += 1
        }
    }

    static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// A fresh hidden staging directory inside `parent` (same volume, so moves are cheap renames).
    public static func makeStagingDirectory(in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(".macitfree-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func makeTemporaryDirectory(_ label: String = "work") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacItFree", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Moves an item, picking a unique name at the destination. Returns the final URL.
    @discardableResult
    public static func moveUnique(_ source: URL, to destination: URL) throws -> URL {
        let target = uniqueURL(for: destination)
        try FileManager.default.moveItem(at: source, to: target)
        return target
    }

    /// Replaces `original` with `replacement` (moving it), as atomically as the platform allows.
    public static func replace(_ original: URL, with replacement: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: original.path) || isSymlink(original) else {
            try fm.moveItem(at: replacement, to: original)
            return
        }
        #if os(macOS)
        if (try? fm.replaceItemAt(original, withItemAt: replacement)) != nil { return }
        #else
        // swift-corelibs-foundation's replaceItemAt is unreliable; rename(2) is atomic on one volume.
        if rename(replacement.path, original.path) == 0 { return }
        #endif
        try fm.removeItem(at: original)
        try fm.moveItem(at: replacement, to: original)
    }

    public static func contents(of directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public static func fileSize(_ url: URL) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    public static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Human readable byte count ("1.4 MB").
    public static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(bytes) \(bytes == 1 ? "byte" : "bytes")" }
        return String(format: value >= 100 ? "%.0f" : "%.1f", value) + " " + units[unit]
    }
}
