import AppKit
import ArchiveKit
import SwiftUI
import UniformTypeIdentifiers

enum ExtractDestinationMode: String, CaseIterable, Identifiable {
    case sameFolder, ask, fixed
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .sameFolder: return "Next to the archive"
        case .ask: return "Ask every time"
        case .fixed: return "A fixed folder"
        }
    }
}

enum FinderOpenAction: String, CaseIterable, Identifiable {
    case browse, extract
    var id: String { rawValue }
    var displayName: String { self == .browse ? "Browse the archive" : "Extract immediately" }
}

/// Keys for @AppStorage / UserDefaults.
enum Defaults {
    static let extractDestinationMode = "extractDestinationMode"
    static let extractFixedFolder = "extractFixedFolder"
    static let revealAfterExtract = "revealAfterExtract"
    static let trashArchiveAfterExtract = "trashArchiveAfterExtract"
    static let finderOpenAction = "finderOpenAction"
    static let defaultPresetID = "defaultPresetID"
    static let generator = "passwordGenerator"
    static let tryVaultPasswords = "tryVaultPasswords"
}

enum GeneratorSettings {
    static func load() -> PasswordGenerator {
        guard let data = UserDefaults.standard.data(forKey: Defaults.generator),
              let generator = try? JSONDecoder().decode(PasswordGenerator.self, from: data) else { return PasswordGenerator() }
        return generator
    }

    static func save(_ generator: PasswordGenerator) {
        UserDefaults.standard.set(try? JSONEncoder().encode(generator), forKey: Defaults.generator)
    }
}

/// A running or finished background job shown in the Activity list.
@MainActor
final class Activity: ObservableObject, Identifiable {
    enum State: Equatable { case running, done(String), failed(String), cancelled }

    let id = UUID()
    let title: String
    let cancellation = Cancellation()
    @Published var state: State = .running
    @Published var detail = ""
    var resultURLs: [URL] = []

    init(title: String) { self.title = title }

    var isRunning: Bool { state == .running }
}

/// App-wide state: presets, settings, background jobs, window routing.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let store = SettingsStore()
    @Published var presets: [Preset]
    @Published var extractOptions: ExtractOptions
    @Published var activities: [Activity] = []
    /// Files waiting in the "New Archive" window.
    @Published var pendingCompression: [URL] = []
    /// Files gathered in Collect mode.
    @Published var basket: [URL] = []
    @Published var recentArchives: [URL] = []

    /// Captured from any SwiftUI window so AppKit callbacks (Services, Dock drops) can open windows.
    var openWindowAction: OpenWindowAction?
    private var pendingArchiveWindows: [URL] = []

    private init() {
        presets = store.loadPresets()
        extractOptions = store.loadExtractOptions()
        recentArchives = NSDocumentController.shared.recentDocumentURLs
    }

    // MARK: Settings

    var defaultPreset: Preset {
        let id = UserDefaults.standard.string(forKey: Defaults.defaultPresetID)
        return presets.first { $0.id.uuidString == id } ?? presets.first ?? Preset.defaults[0]
    }

    func savePresets() {
        do { try store.savePresets(presets) } catch { Prompts.showError(error, title: "Couldn’t save presets") }
    }

    func saveExtractOptions() {
        try? store.saveExtractOptions(extractOptions)
    }

    // MARK: Windows

    func registerOpenWindow(_ action: OpenWindowAction) {
        openWindowAction = action
        let pending = pendingArchiveWindows
        pendingArchiveWindows.removeAll()
        for url in pending { action(value: url) }
    }

    func openArchiveWindow(_ url: URL) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        recentArchives = NSDocumentController.shared.recentDocumentURLs
        if let openWindowAction {
            openWindowAction(value: url)
        } else {
            pendingArchiveWindows.append(url)
        }
    }

    func openWindow(id: String) {
        openWindowAction?.callAsFunction(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Opening files from Finder / Dock / Services

    /// Archives are browsed (or extracted, per settings); anything else is compressed with the default preset.
    func handleOpen(_ urls: [URL]) {
        let archives = urls.filter { ArchiveFormat.detect(url: $0) != nil && !FileOps.isDirectory($0) }
        let others = urls.filter { !archives.contains($0) }
        let action = FinderOpenAction(rawValue: UserDefaults.standard.string(forKey: Defaults.finderOpenAction) ?? "") ?? .browse
        if action == .extract {
            extract(archives)
        } else {
            archives.forEach(openArchiveWindow)
        }
        if !others.isEmpty { compress(others, preset: defaultPreset) }
    }

    func chooseAndOpenArchives() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose archives to open"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(openArchiveWindow)
    }

    func chooseFilesToCompress() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose files and folders to compress"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return }
        showCreateWindow(panel.urls)
    }

    func showCreateWindow(_ urls: [URL]) {
        pendingCompression = urls
        openWindow(id: "create")
    }

    // MARK: Compression

    /// Compresses with a preset. Asks for destination/password as the preset requires.
    func compress(_ urls: [URL], preset: Preset, password: String? = nil, outputOverride: URL? = nil) {
        guard !urls.isEmpty else { return }
        var password = password
        if preset.encrypt && password == nil {
            guard let answer = Prompts.askNewPassword(title: "Choose a password for the new archive") else { return }
            password = answer.password
            if answer.remember { PasswordVault.save(answer.password, label: preset.outputName(for: urls)) }
        }

        var output: URL
        if let outputOverride {
            output = outputOverride
        } else {
            let name = preset.outputName(for: urls)
            switch preset.destination {
            case .sameFolder:
                output = urls[0].deletingLastPathComponent().appendingPathComponent(name)
            case let .folder(path):
                output = URL(fileURLWithPath: path).appendingPathComponent(name)
            case .ask:
                let panel = NSSavePanel()
                panel.nameFieldStringValue = name
                panel.directoryURL = urls[0].deletingLastPathComponent()
                NSApp.activate(ignoringOtherApps: true)
                guard panel.runModal() == .OK, let chosen = panel.url else { return }
                output = chosen
            }
            if outputOverride == nil && preset.destination != .ask { output = FileOps.uniqueURL(for: output) }
        }

        let options = preset.createOptions(password: password)
        let activity = Activity(title: "Compressing \(output.lastPathComponent)")
        activity.detail = "\(urls.count) item\(urls.count == 1 ? "" : "s") → \(preset.format.displayName)"
        activities.insert(activity, at: 0)
        let after = preset.afterCreating
        let cancellation = activity.cancellation

        run(activity, work: {
            try ArchiveCreator.create(urls, at: output, options: options, cancellation: cancellation)
        }, completion: { result in
            activity.resultURLs = result.outputs
            let size = result.outputs.reduce(UInt64(0)) { $0 + FileOps.fileSize($1) }
            activity.state = .done("\(result.itemCount) files → \(FileOps.formatBytes(size))" + (result.warnings.isEmpty ? "" : " ⚠︎ " + result.warnings.joined(separator: " ")))
            switch after {
            case .nothing: break
            case .reveal: NSWorkspace.shared.activateFileViewerSelecting(result.outputs)
            case .moveSourcesToTrash: NSWorkspace.shared.recycle(urls)
            }
        })
    }

    // MARK: Extraction

    func extractDestination(for archive: URL) -> URL? {
        let mode = ExtractDestinationMode(rawValue: UserDefaults.standard.string(forKey: Defaults.extractDestinationMode) ?? "") ?? .sameFolder
        switch mode {
        case .sameFolder:
            return archive.deletingLastPathComponent()
        case .fixed:
            if let path = UserDefaults.standard.string(forKey: Defaults.extractFixedFolder), !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            return archive.deletingLastPathComponent()
        case .ask:
            return chooseFolder(message: "Extract “\(archive.lastPathComponent)” to:", start: archive.deletingLastPathComponent())
        }
    }

    func chooseFolder(message: String, start: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Extract Here"
        panel.message = message
        panel.directoryURL = start
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Makes sure an archive can be read: loads it, trying vault passwords and prompting as needed.
    /// Returns false if the user cancelled.
    func unlock(_ archive: Archive, requireDataPassword: Bool) -> Bool {
        var wrong = false
        while true {
            do {
                if !archive.isLoaded { try archive.load() }
                if requireDataPassword && archive.isEncrypted && archive.password == nil {
                    throw ArchiveError.passwordRequired
                }
                return true
            } catch let error as ArchiveError where error == .passwordRequired || error == .wrongPassword {
                if !wrong, UserDefaults.standard.object(forKey: Defaults.tryVaultPasswords) as? Bool ?? true,
                   archive.tryPasswords(PasswordVault.allPasswords()) != nil {
                    continue
                }
                guard let answer = Prompts.askPassword(for: archive.displayName, wrongAttempt: wrong || error == .wrongPassword) else { return false }
                if archive.isLoaded && !archive.verify(password: answer.password) {
                    wrong = true
                    continue
                }
                archive.password = answer.password
                if answer.remember { PasswordVault.save(answer.password, label: archive.displayName) }
                wrong = error == .wrongPassword
                if archive.isLoaded { return true }
            } catch {
                Prompts.showError(error, title: "Couldn’t open “\(archive.displayName)”")
                return false
            }
        }
    }

    /// Extracts whole archives using the extraction settings (used by Services, Dock and drop zones).
    func extract(_ urls: [URL], to fixedDestination: URL? = nil) {
        for url in urls {
            let archive: Archive
            do { archive = try Archive(url: url) } catch {
                Prompts.showError(error)
                continue
            }
            guard unlock(archive, requireDataPassword: true) else { continue }
            guard let destination = fixedDestination ?? extractDestination(for: url) else { continue }
            extract(archive, paths: nil, to: destination)
        }
    }

    /// Extracts (part of) an opened archive in the background.
    func extract(_ archive: Archive, paths: [String]?, to destination: URL, completion: (([URL]) -> Void)? = nil) {
        let activity = Activity(title: "Extracting \(archive.displayName)")
        activity.detail = paths.map { "\($0.count) item\($0.count == 1 ? "" : "s")" } ?? "\(archive.fileCount) files"
        activities.insert(activity, at: 0)
        let options = extractOptions
        let reveal = UserDefaults.standard.bool(forKey: Defaults.revealAfterExtract)
        let trash = UserDefaults.standard.bool(forKey: Defaults.trashArchiveAfterExtract) && paths == nil
        let cancellation = activity.cancellation
        run(activity, work: {
            try archive.extract(paths: paths, to: destination, options: options, cancellation: cancellation)
        }, completion: { results in
            activity.resultURLs = results
            activity.state = .done("→ " + (results.count == 1 ? results[0].lastPathComponent : "\(results.count) items in \(destination.lastPathComponent)"))
            if reveal { NSWorkspace.shared.activateFileViewerSelecting(results) }
            if trash {
                let volumes = archive.format == .split ? SplitArchive.volumes(startingAt: archive.url) : [archive.url]
                NSWorkspace.shared.recycle(volumes)
            }
            completion?(results)
        })
    }

    // MARK: Background execution

    /// Runs `work` off the main thread and reports into `activity`.
    func run<T>(_ activity: Activity, work: @escaping () throws -> T, completion: @escaping (T) -> Void) {
        Task {
            let result: Result<T, Error> = await Task.detached(priority: .userInitiated) {
                Result { try work() }
            }.value
            switch result {
            case let .success(value):
                completion(value)
            case let .failure(error):
                if let archiveError = error as? ArchiveError, archiveError == .cancelled {
                    activity.state = .cancelled
                } else {
                    activity.state = .failed(error.localizedDescription)
                    NSSound.beep()
                }
            }
        }
    }

    func clearFinishedActivities() {
        activities.removeAll { !$0.isRunning }
    }
}
