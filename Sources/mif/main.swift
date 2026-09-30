import ArchiveKit
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// mif — the MacItFree command-line archiver. Scriptable from shell, Shortcuts ("Run Shell Script"),
// Automator, Hazel, Alfred, LaunchBar, Keyboard Maestro, …

let version = "1.0.0"

let usage = """
mif \(version) — free archive utility (MacItFree)

USAGE
  mif <command> [arguments] [options]

COMMANDS
  list, l      <archive>                     List contents
  extract, x   <archive> [items…]            Extract everything or selected items
  create, c    <output> <files…>             Create an archive (format from extension or -f)
  add          <archive> <files…>            Add files to an existing archive
  delete, rm   <archive> <items…>            Remove items from an archive
  rename, mv   <archive> <item> <new-name>   Rename an item inside an archive
  test, t      <archive>                     Verify archive integrity
  info         <archive>                     Show format, size and encryption details
  hash         <files…> [--verify HEX]       SHA-256 checksum (and verification)
  join         <file.001> [-o OUTPUT]        Join split volumes into one file
  split        <file> <size>                 Split a file into volumes (e.g. 100m, 4g)
  genpass      [--length N] [--count N] [--no-symbols]
  formats                                    Supported formats and installed helper tools
  presets                                    List saved presets (use with create --preset)

OPTIONS
  -p, --password PASS    Password (or set MIF_PASSWORD; you are prompted when needed)
  -d, --dest DIR         Extraction destination (default: next to the archive)
  --folder MODE          Wrap extracted items in a folder: smart (default) | always | never
  --keep-junk            Keep __MACOSX, ._*, .DS_Store, Thumbs.db when extracting
  -f, --format FMT       zip, 7z, tar, tar.gz, tar.bz2, tar.xz, tar.zst, tar.lz4, dmg, xar, iso, cpio,
                         gz, bz2, xz, zst, br, lz4
  -l, --level N          Compression level 0 (store) … 9 (maximum), default 6
  -e, --encrypt          Encrypt (prompts for a password unless -p is given)
  --generate-password    Encrypt with a freshly generated password and print it
  --preset NAME          Use a saved preset (see `mif presets`)
  --split SIZE           Split into volumes of SIZE (e.g. 20m, 4.7g)
  --exclude GLOB         Exclude matching names/paths (repeatable)
  --exclude-vcs          Exclude .git, .svn, .hg, …
  --exclude-build        Exclude node_modules, .build, DerivedData, __pycache__, …
  --exclude-hidden       Exclude all dot-files
  --no-clean             Keep macOS/Windows junk files in the archive
  --max-size SIZE        Skip files larger than SIZE
  --to FOLDER            Target folder inside the archive (for add)
  -o, --output PATH      Output path (join)
  -v, --verbose          More detail
"""

struct Arguments {
    var positional: [String] = []
    var options: [String: [String]] = [:]
    var flags: Set<String> = []

    static let valueOptions: Set<String> = [
        "-p", "--password", "-d", "--dest", "--folder", "-f", "--format", "-l", "--level", "--preset", "--split",
        "--exclude", "--max-size", "--to", "-o", "--output", "--verify", "--length", "--count",
    ]
    static let aliases: [String: String] = [
        "-p": "--password", "-d": "--dest", "-f": "--format", "-l": "--level", "-o": "--output", "-e": "--encrypt", "-v": "--verbose", "-h": "--help",
    ]

    init(_ args: [String]) throws {
        var i = 0
        var onlyPositional = false
        while i < args.count {
            let arg = args[i]
            if onlyPositional || !arg.hasPrefix("-") || arg == "-" {
                positional.append(arg)
            } else if arg == "--" {
                onlyPositional = true
            } else {
                var key = arg
                var inlineValue: String?
                if let eq = arg.firstIndex(of: "="), arg.hasPrefix("--") {
                    key = String(arg[..<eq])
                    inlineValue = String(arg[arg.index(after: eq)...])
                }
                if Arguments.valueOptions.contains(key) {
                    let value: String
                    if let inlineValue {
                        value = inlineValue
                    } else {
                        i += 1
                        guard i < args.count else { throw ArchiveError.invalidArgument("Option \(key) needs a value.") }
                        value = args[i]
                    }
                    options[Arguments.aliases[key] ?? key, default: []].append(value)
                } else {
                    flags.insert(Arguments.aliases[key] ?? key)
                }
            }
            i += 1
        }
    }

    func value(_ key: String) -> String? { options[key]?.last }
    func values(_ key: String) -> [String] { options[key] ?? [] }
    func has(_ flag: String) -> Bool { flags.contains(flag) }
}

enum ExitCode: Int32 {
    case ok = 0, failure = 1, usage = 2, password = 3
}

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func url(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
}

func promptPassword(_ prompt: String) -> String? {
    guard isatty(STDIN_FILENO) != 0, let raw = getpass(prompt) else { return nil }
    let password = String(cString: raw)
    return password.isEmpty ? nil : password
}

func initialPassword(_ args: Arguments) -> String? {
    args.value("--password") ?? ProcessInfo.processInfo.environment["MIF_PASSWORD"]
}

/// Opens and lists an archive, prompting for a password when needed.
func openArchive(_ path: String, _ args: Arguments) throws -> Archive {
    let archive = try Archive(url: url(path))
    archive.password = initialPassword(args)
    var attempts = 0
    while true {
        do {
            try archive.load()
            return archive
        } catch let error as ArchiveError where error == .passwordRequired || error == .wrongPassword {
            attempts += 1
            if error == .wrongPassword { printErr("Wrong password.") }
            guard attempts <= 3, let password = promptPassword("Password for \(archive.displayName): ") else { throw error }
            archive.password = password
        }
    }
}

/// Runs an operation that may discover (per-entry) encryption only when reading data.
func withPasswordRetry(_ archive: Archive, _ body: () throws -> Void) throws {
    var attempts = 0
    while true {
        do {
            if archive.isEncrypted && archive.password == nil {
                guard let password = promptPassword("Password for \(archive.displayName): ") else { throw ArchiveError.passwordRequired }
                archive.password = password
            }
            try body()
            return
        } catch let error as ArchiveError where error == .passwordRequired || error == .wrongPassword {
            attempts += 1
            if error == .wrongPassword { printErr("Wrong password.") }
            guard attempts <= 3, let password = promptPassword("Password for \(archive.displayName): ") else { throw error }
            archive.password = password
        }
    }
}

let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f
}()

// MARK: - Commands

func cmdList(_ args: Arguments) throws {
    guard let path = args.positional.first else { throw ArchiveError.invalidArgument("Usage: mif list <archive>") }
    let archive = try openArchive(path, args)
    let verbose = args.has("--verbose") || args.has("--long")
    for entry in archive.entries {
        let name = entry.isDirectory ? entry.path + "/" : entry.path
        if verbose {
            let size = entry.isDirectory ? "" : String(entry.size ?? 0)
            let date = entry.modified.map(dateFormatter.string(from:)) ?? ""
            let lock = entry.isEncrypted ? "*" : " "
            let link = entry.linkTarget.map { " -> \($0)" } ?? ""
            print(size.leftPadded(12) + "  " + date.leftPadded(16) + " " + lock + " " + name + link)
        } else {
            print(name)
        }
    }
    if verbose {
        print("\(archive.fileCount) files, \(FileOps.formatBytes(archive.totalSize))" + (archive.isEncrypted ? " (encrypted)" : ""))
    }
}

func cmdExtract(_ args: Arguments) throws {
    guard let path = args.positional.first else { throw ArchiveError.invalidArgument("Usage: mif extract <archive> [items…] [-d DEST]") }
    let archive = try openArchive(path, args)
    let destination = args.value("--dest").map(url) ?? archive.url.deletingLastPathComponent()
    var options = ExtractOptions()
    if let mode = args.value("--folder") {
        guard let policy = ExtractOptions.FolderPolicy(rawValue: mode) else { throw ArchiveError.invalidArgument("--folder must be smart, always or never") }
        options.folderPolicy = policy
    }
    options.removeJunk = !args.has("--keep-junk")
    let items = Array(args.positional.dropFirst())
    for item in items where archive.root.node(at: ArchiveEntry.normalize(item)) == nil {
        throw ArchiveError.invalidArgument("“\(item)” is not in the archive.")
    }
    var results: [URL] = []
    try withPasswordRetry(archive) {
        results = try archive.extract(paths: items.isEmpty ? nil : items, to: destination, options: options)
    }
    for result in results { print(result.path) }
}

func buildFilter(_ args: Arguments, base: FileFilter) throws -> FileFilter {
    var filter = base
    if args.has("--no-clean") {
        filter.excludeMacJunk = false
        filter.excludeWindowsJunk = false
    }
    if args.has("--exclude-vcs") { filter.excludeVersionControl = true }
    if args.has("--exclude-build") { filter.excludeBuildArtifacts = true }
    if args.has("--exclude-hidden") { filter.excludeHiddenFiles = true }
    filter.customPatterns += args.values("--exclude")
    if let size = args.value("--max-size") {
        guard let bytes = SplitArchive.parseSize(size) else { throw ArchiveError.invalidArgument("Invalid size “\(size)”.") }
        filter.maximumFileSize = bytes
    }
    return filter
}

func cmdCreate(_ args: Arguments) throws {
    guard args.positional.count >= 2 else { throw ArchiveError.invalidArgument("Usage: mif create <output> <files…>") }
    var output = url(args.positional[0])
    let inputs = args.positional.dropFirst().map(url)

    var preset: Preset?
    if let name = args.value("--preset") {
        let presets = SettingsStore().loadPresets()
        preset = presets.first { $0.name.lowercased() == name.lowercased() } ?? presets.first { $0.name.lowercased().contains(name.lowercased()) }
        guard preset != nil else { throw ArchiveError.invalidArgument("No preset named “\(name)”. Run `mif presets`.") }
    }

    var format: ArchiveFormat
    if let explicit = args.value("--format") {
        guard let f = ArchiveFormat(rawValue: explicit) ?? ArchiveFormat.detect(fileName: "x." + explicit) else {
            throw ArchiveError.invalidArgument("Unknown format “\(explicit)”. Run `mif formats`.")
        }
        format = f
        if ArchiveFormat.detect(fileName: output.lastPathComponent) != f {
            output = output.deletingLastPathComponent().appendingPathComponent(output.lastPathComponent + "." + f.preferredExtension)
        }
    } else if let detected = ArchiveFormat.detect(fileName: output.lastPathComponent), ArchiveFormat.creatable.contains(detected) {
        format = detected
    } else if let presetFormat = preset?.format {
        format = presetFormat
        output = output.deletingLastPathComponent().appendingPathComponent(output.lastPathComponent + "." + presetFormat.preferredExtension)
    } else {
        format = .zip
        output = output.deletingLastPathComponent().appendingPathComponent(output.lastPathComponent + ".zip")
    }

    var options = preset?.createOptions(password: nil) ?? CreateOptions()
    options.format = format
    options.filter = try buildFilter(args, base: preset?.filter ?? FileFilter())
    if let level = args.value("--level") {
        guard let n = Int(level), (0...9).contains(n) else { throw ArchiveError.invalidArgument("--level must be 0…9") }
        options.compressionLevel = n
    }
    if let split = args.value("--split") {
        guard let size = SplitArchive.parseSize(split) else { throw ArchiveError.invalidArgument("Invalid split size “\(split)”.") }
        options.volumeSize = size
    }

    var password = initialPassword(args)
    if args.has("--generate-password") {
        password = PasswordGenerator().generate()
        printErr("Generated password: \(password!)")
    }
    if password == nil && (args.has("--encrypt") || preset?.encrypt == true) {
        guard let first = promptPassword("Password: "), let second = promptPassword("Verify password: ") else {
            throw ArchiveError.invalidArgument("A password is required to encrypt.")
        }
        guard first == second else { throw ArchiveError.invalidArgument("Passwords don’t match.") }
        password = first
    }
    options.password = password

    let result = try ArchiveCreator.create(inputs, at: output, options: options)
    for warning in result.warnings { printErr("warning: \(warning)") }
    for out in result.outputs { print(out.path) }
    if args.has("--verbose") {
        let total = result.outputs.reduce(UInt64(0)) { $0 + FileOps.fileSize($1) }
        printErr("\(result.itemCount) files → \(FileOps.formatBytes(total))")
    }
}

func cmdAdd(_ args: Arguments) throws {
    guard args.positional.count >= 2 else { throw ArchiveError.invalidArgument("Usage: mif add <archive> <files…> [--to FOLDER]") }
    let archive = try openArchive(args.positional[0], args)
    let files = args.positional.dropFirst().map(url)
    var filter = try buildFilter(args, base: FileFilter())
    if args.has("--no-clean") { filter = try buildFilter(args, base: .keepEverything) }
    try withPasswordRetry(archive) {
        try archive.add(Array(files), toFolder: args.value("--to") ?? "", filter: filter)
    }
    print("\(archive.displayName): \(archive.fileCount) file" + (archive.fileCount == 1 ? "" : "s"))
}

func cmdDelete(_ args: Arguments) throws {
    guard args.positional.count >= 2 else { throw ArchiveError.invalidArgument("Usage: mif delete <archive> <items…>") }
    let archive = try openArchive(args.positional[0], args)
    let items = Array(args.positional.dropFirst())
    for item in items where archive.root.node(at: ArchiveEntry.normalize(item)) == nil {
        throw ArchiveError.invalidArgument("“\(item)” is not in the archive.")
    }
    try withPasswordRetry(archive) { try archive.delete(paths: items) }
    print("\(archive.displayName): \(archive.fileCount) file" + (archive.fileCount == 1 ? "" : "s"))
}

func cmdRename(_ args: Arguments) throws {
    guard args.positional.count == 3 else { throw ArchiveError.invalidArgument("Usage: mif rename <archive> <item> <new-name>") }
    let archive = try openArchive(args.positional[0], args)
    try withPasswordRetry(archive) { try archive.rename(path: args.positional[1], to: args.positional[2]) }
}

func cmdTest(_ args: Arguments) throws {
    guard let path = args.positional.first else { throw ArchiveError.invalidArgument("Usage: mif test <archive>") }
    let archive = try openArchive(path, args)
    try withPasswordRetry(archive) { try archive.test() }
    print("OK: \(archive.displayName) — \(archive.fileCount) files verified")
}

func cmdInfo(_ args: Arguments) throws {
    guard let path = args.positional.first else { throw ArchiveError.invalidArgument("Usage: mif info <archive>") }
    let archive = try openArchive(path, args)
    let packed = FileOps.fileSize(archive.workingURL)
    print("File:        \(archive.url.path)")
    print("Format:      \(archive.contentFormat.displayName)" + (archive.format == .split ? " (joined from split volumes)" : ""))
    print("Files:       \(archive.fileCount)")
    print("Folders:     \(archive.entries.filter(\.isDirectory).count)")
    print("Size:        \(FileOps.formatBytes(archive.totalSize)) (\(archive.totalSize) bytes)")
    print("Packed:      \(FileOps.formatBytes(packed))")
    if archive.totalSize > 0 {
        print("Ratio:       " + String(format: "%.1f%%", Double(packed) / Double(archive.totalSize) * 100))
    }
    print("Encrypted:   " + (archive.hasEncryptedListing ? "yes (including file names)" : archive.isEncrypted ? "yes" : "no"))
    print("Modifiable:  " + (archive.canModify ? "yes" : "no"))
    let methods = Set(archive.entries.compactMap(\.method))
    if !methods.isEmpty { print("Methods:     " + methods.sorted().joined(separator: ", ")) }
}

func cmdHash(_ args: Arguments) throws {
    guard !args.positional.isEmpty else { throw ArchiveError.invalidArgument("Usage: mif hash <files…> [--verify HEX]") }
    var failed = false
    for path in args.positional {
        let digest = try Checksum.sha256(of: url(path))
        if let expected = args.value("--verify") {
            let ok = Checksum.matches(digest, expected: expected)
            print("\(ok ? "OK" : "MISMATCH")  \(digest)  \(path)")
            failed = failed || !ok
        } else {
            print("\(digest)  \(path)")
        }
    }
    if failed { exit(ExitCode.failure.rawValue) }
}

func cmdJoin(_ args: Arguments) throws {
    guard let path = args.positional.first else { throw ArchiveError.invalidArgument("Usage: mif join <file.001> [-o OUTPUT]") }
    let output = try SplitArchive.join(firstVolume: url(path), to: args.value("--output").map(url))
    print(output.path)
}

func cmdSplit(_ args: Arguments) throws {
    guard args.positional.count == 2, let size = SplitArchive.parseSize(args.positional[1]) else {
        throw ArchiveError.invalidArgument("Usage: mif split <file> <size>   (e.g. 100m)")
    }
    for volume in try SplitArchive.split(url(args.positional[0]), volumeSize: size) { print(volume.path) }
}

func cmdGenpass(_ args: Arguments) throws {
    var generator = PasswordGenerator()
    if let length = args.value("--length") {
        guard let n = Int(length), n >= 4 else { throw ArchiveError.invalidArgument("--length must be at least 4") }
        generator.length = n
    }
    if args.has("--no-symbols") { generator.includeSymbols = false }
    let count = Int(args.value("--count") ?? "1") ?? 1
    for _ in 0..<max(1, count) { print(generator.generate()) }
}

func cmdFormats(_ args: Arguments) {
    print("HELPER TOOLS")
    for tool in Tool.allCases {
        let location = ToolLocator.find(tool)?.path ?? "not installed — \(tool.installHint)"
        print("  " + tool.rawValue.rightPadded(8) + location)
    }
    print("\nFORMATS" + "".rightPadded(26) + "open  create  encrypt")
    for format in ArchiveFormat.allCases {
        let canOpen = (try? Backends.reader(for: format)) != nil || format == .split
        let canCreate = ArchiveCreator.canCreate(format)
        let canEncrypt = format.supportsEncryption && ArchiveCreator.canCreate(format, encrypted: true)
        let exts = format.extensions.prefix(4).map { "." + $0 }.joined(separator: " ")
        print("  " + format.displayName.rightPadded(18) + exts.rightPadded(20)
              + (canOpen ? "yes" : " - ").rightPadded(6) + (canCreate ? "yes" : " - ").rightPadded(8) + (canEncrypt ? "yes" : " - "))
    }
}

func cmdPresets(_ args: Arguments) {
    for preset in SettingsStore().loadPresets() {
        var details = [preset.format.displayName, "level \(preset.compressionLevel)"]
        if preset.encrypt { details.append("encrypted") }
        if let size = preset.volumeSize { details.append("split \(FileOps.formatBytes(size))") }
        print(preset.name.rightPadded(40) + details.joined(separator: ", "))
    }
}

extension String {
    func leftPadded(_ width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
    func rightPadded(_ width: Int) -> String { count >= width ? self + " " : self + String(repeating: " ", count: width - count) }
}

// MARK: - Main

let rawArgs = Array(CommandLine.arguments.dropFirst())
guard let command = rawArgs.first, command != "help", command != "--help", command != "-h" else {
    print(usage)
    exit(rawArgs.isEmpty ? ExitCode.usage.rawValue : ExitCode.ok.rawValue)
}
if command == "--version" {
    print("mif \(version)")
    exit(0)
}

do {
    let args = try Arguments(Array(rawArgs.dropFirst()))
    switch command {
    case "list", "l", "ls": try cmdList(args)
    case "extract", "x": try cmdExtract(args)
    case "create", "c", "a": try cmdCreate(args)
    case "add": try cmdAdd(args)
    case "delete", "rm", "d": try cmdDelete(args)
    case "rename", "mv": try cmdRename(args)
    case "test", "t": try cmdTest(args)
    case "info", "i": try cmdInfo(args)
    case "hash", "sha256": try cmdHash(args)
    case "join": try cmdJoin(args)
    case "split": try cmdSplit(args)
    case "genpass", "password": try cmdGenpass(args)
    case "formats": cmdFormats(args)
    case "presets": cmdPresets(args)
    default:
        printErr("Unknown command “\(command)”.\n")
        print(usage)
        exit(ExitCode.usage.rawValue)
    }
} catch let error as ArchiveError {
    printErr("mif: " + (error.errorDescription ?? "\(error)"))
    switch error {
    case .passwordRequired, .wrongPassword: exit(ExitCode.password.rawValue)
    case .invalidArgument: exit(ExitCode.usage.rawValue)
    default: exit(ExitCode.failure.rawValue)
    }
} catch {
    printErr("mif: \(error.localizedDescription)")
    exit(ExitCode.failure.rawValue)
}
