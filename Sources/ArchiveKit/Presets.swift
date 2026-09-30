import Foundation

/// A saved bundle of archiving options, like "ZIP for Windows friends" or "Encrypted 7-Zip backup".
public struct Preset: Codable, Identifiable, Equatable, Hashable {
    public enum Destination: Codable, Equatable, Hashable {
        case sameFolder
        case ask
        case folder(String)
    }

    public enum AfterCreating: String, Codable, CaseIterable {
        case nothing
        case reveal
        case moveSourcesToTrash

        public var displayName: String {
            switch self {
            case .nothing: return "Do nothing"
            case .reveal: return "Reveal in Finder"
            case .moveSourcesToTrash: return "Move originals to Trash"
            }
        }
    }

    public var id: UUID
    public var name: String
    public var format: ArchiveFormat
    public var compressionLevel: Int
    /// Ask for (or generate) a password when this preset is used.
    public var encrypt: Bool
    public var encryptFileNames: Bool
    public var filter: FileFilter
    /// Split volume size in bytes; nil for a single file.
    public var volumeSize: UInt64?
    public var destination: Destination
    public var afterCreating: AfterCreating

    public init(
        id: UUID = UUID(),
        name: String,
        format: ArchiveFormat,
        compressionLevel: Int = 6,
        encrypt: Bool = false,
        encryptFileNames: Bool = true,
        filter: FileFilter = FileFilter(),
        volumeSize: UInt64? = nil,
        destination: Destination = .sameFolder,
        afterCreating: AfterCreating = .nothing
    ) {
        self.id = id
        self.name = name
        self.format = format
        self.compressionLevel = compressionLevel
        self.encrypt = encrypt
        self.encryptFileNames = encryptFileNames
        self.filter = filter
        self.volumeSize = volumeSize
        self.destination = destination
        self.afterCreating = afterCreating
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public func createOptions(password: String?) -> CreateOptions {
        var options = CreateOptions(format: format, compressionLevel: compressionLevel, password: encrypt ? password : nil, filter: filter)
        options.encryptFileNames = encryptFileNames
        options.volumeSize = volumeSize
        return options
    }

    /// The archive name for the given source items: `Folder.zip` for one item, `Archive.zip` for several.
    public func outputName(for items: [URL]) -> String {
        let base: String
        if items.count == 1, let item = items.first {
            base = FileOps.isDirectory(item) || format.isSingleFileCompressor ? item.lastPathComponent : (item.lastPathComponent as NSString).deletingPathExtension
        } else {
            base = "Archive"
        }
        let name = format.isSingleFileCompressor && items.count == 1 ? items[0].lastPathComponent : base
        return name + "." + format.preferredExtension
    }

    public static let defaults: [Preset] = {
        var devFilter = FileFilter()
        devFilter.excludeVersionControl = true
        devFilter.excludeBuildArtifacts = true
        return [
            Preset(name: "ZIP (clean, works everywhere)", format: .zip, compressionLevel: 6),
            Preset(name: "ZIP, AES-256 encrypted", format: .zip, compressionLevel: 6, encrypt: true),
            Preset(name: "7-Zip, maximum compression", format: .sevenZip, compressionLevel: 9),
            Preset(name: "7-Zip, encrypted (hide names)", format: .sevenZip, compressionLevel: 9, encrypt: true, encryptFileNames: true),
            Preset(name: "Source code (no .git / node_modules)", format: .zip, compressionLevel: 9, filter: devFilter),
            Preset(name: "TAR + Gzip", format: .tarGzip, compressionLevel: 6),
            Preset(name: "TAR + XZ (smallest)", format: .tarXz, compressionLevel: 9),
            Preset(name: "Disk image (DMG)", format: .dmg, compressionLevel: 6),
            Preset(name: "ZIP split for email (20 MB parts)", format: .zip, compressionLevel: 9, volumeSize: 20 * 1024 * 1024),
        ]
    }()
}

/// Persists presets and extraction settings as JSON in the user's Application Support folder.
public final class SettingsStore {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            #if os(macOS)
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = base.appendingPathComponent("MacItFree", isDirectory: true)
            #else
            let home = FileManager.default.homeDirectoryForCurrentUser
            let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".config")
            self.directory = config.appendingPathComponent("macitfree", isDirectory: true)
            #endif
        }
    }

    private var presetsURL: URL { directory.appendingPathComponent("presets.json") }
    private var extractURL: URL { directory.appendingPathComponent("extract.json") }

    public func loadPresets() -> [Preset] {
        guard let data = try? Data(contentsOf: presetsURL),
              let presets = try? JSONDecoder().decode([Preset].self, from: data), !presets.isEmpty else {
            return Preset.defaults
        }
        return presets
    }

    public func savePresets(_ presets: [Preset]) throws {
        try write(presets, to: presetsURL)
    }

    public func loadExtractOptions() -> ExtractOptions {
        guard let data = try? Data(contentsOf: extractURL),
              let options = try? JSONDecoder().decode(ExtractOptions.self, from: data) else { return ExtractOptions() }
        return options
    }

    public func saveExtractOptions(_ options: ExtractOptions) throws {
        try write(options, to: extractURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
