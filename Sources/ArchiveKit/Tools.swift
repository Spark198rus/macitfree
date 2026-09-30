import Foundation

/// External command-line helpers MacItFree drives. `bsdtar`, `zip`, `unzip`, `gzip`, `bzip2` and
/// `hdiutil` ship with macOS; the rest are optional extras (e.g. `brew install sevenzip zstd brotli xz lz4`).
public enum Tool: String, CaseIterable, Sendable {
    case bsdtar
    case zip
    case unzip
    case sevenZip = "7zz"
    case hdiutil
    case gzip
    case bzip2
    case xz
    case zstd
    case brotli
    case lz4
    case unrar

    /// Binary names to look for, in order of preference.
    public var candidates: [String] {
        switch self {
        case .bsdtar: return ["bsdtar", "tar"]
        case .sevenZip: return ["7zz", "7z", "7za"]
        default: return [rawValue]
        }
    }

    public var installHint: String {
        switch self {
        case .sevenZip: return "Install 7-Zip with Homebrew: brew install sevenzip"
        case .bsdtar: return "bsdtar ships with macOS; on Linux install libarchive-tools."
        case .hdiutil: return "Disk images can only be handled on macOS."
        case .zip, .unzip: return "Install Info-ZIP (brew install zip unzip)."
        case .unrar: return "Install with Homebrew: brew install --cask rar"
        default: return "Install it with Homebrew: brew install \(rawValue)"
        }
    }

    public var isBundledWithMacOS: Bool {
        switch self {
        case .bsdtar, .zip, .unzip, .hdiutil, .gzip, .bzip2: return true
        default: return false
        }
    }
}

public enum ToolLocator {
    private static let lock = NSLock()
    private static var cache: [Tool: URL?] = [:]
    /// Tests or users can override lookup, e.g. to force a tool to be considered missing.
    public static var overrides: [Tool: URL?] = [:]

    public static var searchDirectories: [String] {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":").map(String.init) where !dirs.contains(dir) { dirs.append(dir) }
        }
        // Tools bundled inside the app (Contents/Resources/bin) win over everything else.
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            dirs.insert(bundled, at: 0)
        }
        return dirs
    }

    public static func find(_ tool: Tool) -> URL? {
        if let override = overrides[tool] { return override }
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[tool] { return cached }
        let found = locate(tool)
        cache[tool] = found
        return found
    }

    public static func require(_ tool: Tool) throws -> URL {
        guard let url = find(tool) else {
            throw ArchiveError.toolMissing(tool: tool.rawValue, hint: tool.installHint)
        }
        return url
    }

    public static func isAvailable(_ tool: Tool) -> Bool { find(tool) != nil }

    public static func resetCache() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
    }

    private static func locate(_ tool: Tool) -> URL? {
        let fm = FileManager.default
        for name in tool.candidates {
            for dir in searchDirectories {
                let path = (dir as NSString).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: path) {
                    // macOS's /usr/bin/tar *is* bsdtar, but GNU tar elsewhere is not.
                    if tool == .bsdtar && name == "tar" && !isBsdtar(path) { continue }
                    return URL(fileURLWithPath: path)
                }
            }
        }
        return nil
    }

    private static func isBsdtar(_ path: String) -> Bool {
        guard let result = try? ProcessRunner.run(URL(fileURLWithPath: path), ["--version"]) else { return false }
        return result.stdoutString.contains("bsdtar")
    }
}
