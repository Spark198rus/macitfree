import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Rules for leaving clutter out of archives (and cleaning it out of extracted folders).
public struct FileFilter: Codable, Equatable, Sendable {
    /// `.DS_Store`, `._*` AppleDouble files, `__MACOSX`, `.Spotlight-V100`, `Icon\r`, …
    public var excludeMacJunk = true
    /// `Thumbs.db`, `desktop.ini`, `ehthumbs.db`, `$RECYCLE.BIN`
    public var excludeWindowsJunk = true
    /// `.git`, `.svn`, `.hg`, `CVS`, `.bzr`
    public var excludeVersionControl = false
    /// `node_modules`, `.build`, `DerivedData`, `__pycache__`, `*.pyc`, `.gradle`, `Pods`, `.venv`
    public var excludeBuildArtifacts = false
    /// Any file or folder whose name starts with `.`
    public var excludeHiddenFiles = false
    /// Extra shell-style glob patterns matched against the name (and the relative path if it contains `/`).
    public var customPatterns: [String] = []
    /// Skip files larger than this many bytes.
    public var maximumFileSize: UInt64?
    /// Skip files modified more than this many days ago.
    public var maximumAgeDays: Int?
    /// Skip files modified less than this many days ago.
    public var minimumAgeDays: Int?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        excludeMacJunk = try c.decodeIfPresent(Bool.self, forKey: .excludeMacJunk) ?? true
        excludeWindowsJunk = try c.decodeIfPresent(Bool.self, forKey: .excludeWindowsJunk) ?? true
        excludeVersionControl = try c.decodeIfPresent(Bool.self, forKey: .excludeVersionControl) ?? false
        excludeBuildArtifacts = try c.decodeIfPresent(Bool.self, forKey: .excludeBuildArtifacts) ?? false
        excludeHiddenFiles = try c.decodeIfPresent(Bool.self, forKey: .excludeHiddenFiles) ?? false
        customPatterns = try c.decodeIfPresent([String].self, forKey: .customPatterns) ?? []
        maximumFileSize = try c.decodeIfPresent(UInt64.self, forKey: .maximumFileSize)
        maximumAgeDays = try c.decodeIfPresent(Int.self, forKey: .maximumAgeDays)
        minimumAgeDays = try c.decodeIfPresent(Int.self, forKey: .minimumAgeDays)
    }

    /// Keeps everything, junk included.
    public static let keepEverything: FileFilter = {
        var filter = FileFilter()
        filter.excludeMacJunk = false
        filter.excludeWindowsJunk = false
        return filter
    }()

    public static let macJunkNames: Set<String> = [
        ".DS_Store", "__MACOSX", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems",
        ".DocumentRevisions-V100", ".VolumeIcon.icns", ".apdisk", ".AppleDouble", ".AppleDB", ".AppleDesktop",
        "Icon\r", ".com.apple.timemachine.donotpresent",
    ]
    public static let windowsJunkNames: Set<String> = ["Thumbs.db", "ehthumbs.db", "desktop.ini", "Desktop.ini", "$RECYCLE.BIN"]
    public static let versionControlNames: Set<String> = [".git", ".svn", ".hg", "CVS", ".bzr", "_darcs", ".fossil"]
    public static let buildArtifactNames: Set<String> = [
        "node_modules", ".build", "DerivedData", "__pycache__", ".gradle", "Pods", ".venv", "venv",
        ".tox", ".mypy_cache", ".pytest_cache", ".next", ".nuxt", ".parcel-cache", ".cache", "xcuserdata",
    ]
    public static let buildArtifactPatterns = ["*.pyc", "*.pyo", "*.o", "*.class", "*.xcuserstate"]

    /// Returns `true` if an item should be left out, based purely on its name/relative path.
    public func excludes(name: String, relativePath: String, isDirectory: Bool) -> Bool {
        if excludeMacJunk && (FileFilter.macJunkNames.contains(name) || name.hasPrefix("._")) { return true }
        if excludeWindowsJunk && FileFilter.windowsJunkNames.contains(name) { return true }
        if excludeVersionControl && FileFilter.versionControlNames.contains(name) { return true }
        if excludeBuildArtifacts {
            if FileFilter.buildArtifactNames.contains(name) { return true }
            if !isDirectory && FileFilter.buildArtifactPatterns.contains(where: { FileFilter.glob($0, name) }) { return true }
        }
        if excludeHiddenFiles && name.hasPrefix(".") { return true }
        for pattern in customPatterns where !pattern.isEmpty {
            let subject = pattern.contains("/") ? relativePath : name
            if FileFilter.glob(pattern, subject) { return true }
        }
        return false
    }

    /// Returns `true` if a file should be skipped because of its size or age.
    public func excludes(size: UInt64?, modified: Date?, now: Date = Date()) -> Bool {
        if let maximumFileSize, let size, size > maximumFileSize { return true }
        if let modified {
            let ageDays = now.timeIntervalSince(modified) / 86_400
            if let maximumAgeDays, ageDays > Double(maximumAgeDays) { return true }
            if let minimumAgeDays, ageDays < Double(minimumAgeDays) { return true }
        }
        return false
    }

    public static func glob(_ pattern: String, _ string: String) -> Bool {
        fnmatch(pattern, string, 0) == 0
    }

    /// Deletes junk (per this filter's name rules) from an extracted folder tree.
    public func clean(directory: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return }
        var doomed: [URL] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let relative = FileFilter.relativePath(of: url, in: directory)
            if excludes(name: url.lastPathComponent, relativePath: relative, isDirectory: isDirectory) {
                doomed.append(url)
                if isDirectory { enumerator.skipDescendants() }
            }
        }
        for url in doomed { try? fm.removeItem(at: url) }
    }

    static func relativePath(of url: URL, in base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(basePath) else { return url.lastPathComponent }
        return String(path.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// One file-system item selected for archiving, relative to its base folder.
public struct CollectedItem: Hashable {
    public var base: URL
    public var relativePath: String
    public var isDirectory: Bool
    public var url: URL { base.appendingPathComponent(relativePath) }
}

public enum FileCollector {
    /// Walks the given top-level items and returns every file/folder that survives the filter,
    /// each relative to the folder containing its top-level item. Symlinks are kept, not followed.
    public static func collect(_ items: [URL], filter: FileFilter) throws -> [CollectedItem] {
        let fm = FileManager.default
        var result: [CollectedItem] = []
        for item in items {
            let item = item.standardizedFileURL
            let base = item.deletingLastPathComponent()
            let name = item.lastPathComponent
            guard let attributes = try? fm.attributesOfItem(atPath: item.path) else {
                throw ArchiveError.invalidArgument("“\(item.path)” does not exist.")
            }
            let type = attributes[.type] as? FileAttributeType
            let isDirectory = type == .typeDirectory
            if filter.excludes(name: name, relativePath: name, isDirectory: isDirectory) { continue }
            if !isDirectory {
                if type != .typeSymbolicLink && filter.excludes(size: (attributes[.size] as? NSNumber)?.uint64Value, modified: attributes[.modificationDate] as? Date) { continue }
                result.append(CollectedItem(base: base, relativePath: name, isDirectory: false))
                continue
            }
            result.append(CollectedItem(base: base, relativePath: name, isDirectory: true))
            try walk(directory: item, relative: name, base: base, filter: filter, into: &result)
        }
        return result
    }

    private static func walk(directory: URL, relative: String, base: URL, filter: FileFilter, into result: inout [CollectedItem]) throws {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: directory.path).sorted()
        for name in names {
            let url = directory.appendingPathComponent(name)
            let rel = relative + "/" + name
            guard let attributes = try? fm.attributesOfItem(atPath: url.path) else { continue }
            let type = attributes[.type] as? FileAttributeType
            let isDirectory = type == .typeDirectory
            if filter.excludes(name: name, relativePath: rel, isDirectory: isDirectory) { continue }
            if isDirectory {
                result.append(CollectedItem(base: base, relativePath: rel, isDirectory: true))
                try walk(directory: url, relative: rel, base: base, filter: filter, into: &result)
            } else {
                if type != .typeSymbolicLink && filter.excludes(size: (attributes[.size] as? NSNumber)?.uint64Value, modified: attributes[.modificationDate] as? Date) { continue }
                result.append(CollectedItem(base: base, relativePath: rel, isDirectory: false))
            }
        }
    }
}
