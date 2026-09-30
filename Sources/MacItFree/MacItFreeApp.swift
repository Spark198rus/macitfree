import AppKit
import ArchiveKit
import SwiftUI

@main
struct MacItFreeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        let state = AppState.shared
        Window("MacItFree", id: "main") {
            WelcomeView()
                .environmentObject(state)
                .registersWindowOpener()
        }
        .defaultSize(width: 560, height: 520)
        .commands { AppCommands(state: state) }

        WindowGroup("Archive", for: URL.self) { $url in
            if let url {
                ArchiveWindow(url: url)
                    .environmentObject(state)
                    .registersWindowOpener()
            }
        }
        .defaultSize(width: 860, height: 560)

        Window("New Archive", id: "create") {
            CreateArchiveView()
                .environmentObject(state)
                .registersWindowOpener()
        }
        .windowResizability(.contentSize)

        Window("Collect", id: "collect") {
            CollectView()
                .environmentObject(state)
                .registersWindowOpener()
        }
        .defaultSize(width: 380, height: 420)

        Window("Checksum", id: "checksum") {
            ChecksumView()
                .registersWindowOpener()
        }
        .windowResizability(.contentSize)

        Window("Password Generator", id: "generator") {
            GeneratorView()
                .registersWindowOpener()
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var state: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open Archive…") { state.chooseAndOpenArchives() }
                .keyboardShortcut("o")
            Button("New Archive from Files…") { state.chooseFilesToCompress() }
                .keyboardShortcut("n")
            Divider()
            Button("Extract Archives…") {
                let panel = NSOpenPanel()
                panel.allowsMultipleSelection = true
                panel.message = "Choose archives to extract"
                if panel.runModal() == .OK { state.extract(panel.urls) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandMenu("Tools") {
            Button("Collect Basket") { state.openWindow(id: "collect") }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Checksum (SHA-256)…") { state.openWindow(id: "checksum") }
            Button("Password Generator…") { state.openWindow(id: "generator") }
            Divider()
            Button("Join Split Files…") {
                let panel = NSOpenPanel()
                panel.message = "Choose the first volume (.001)"
                guard panel.runModal() == .OK, let first = panel.url else { return }
                do {
                    let joined = try SplitArchive.join(firstVolume: first)
                    NSWorkspace.shared.activateFileViewerSelecting([joined])
                } catch {
                    Prompts.showError(error)
                }
            }
            Button("Main Window") { state.openWindow(id: "main") }
                .keyboardShortcut("0")
        }
    }
}

/// Lets AppKit-side code (Dock drops, Services) open SwiftUI windows.
private struct WindowOpenerRegistration: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear { AppState.shared.registerOpenWindow(openWindow) }
    }
}

extension View {
    func registersWindowOpener() -> some View { modifier(WindowOpenerRegistration()) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var services: ServiceProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let services = ServiceProvider()
        self.services = services
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }

    /// Files dropped on the Dock icon / Finder toolbar button, or opened via "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        AppState.shared.handleOpen(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Finder integration through the Services menu (right-click › Quick Actions / Services).
@MainActor
final class ServiceProvider: NSObject {
    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    @objc func compressFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = fileURLs(from: pasteboard)
        AppState.shared.compress(urls, preset: AppState.shared.defaultPreset)
    }

    @objc func compressFilesWithOptions(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        AppState.shared.showCreateWindow(fileURLs(from: pasteboard))
    }

    @objc func extractArchives(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        AppState.shared.extract(fileURLs(from: pasteboard))
    }

    @objc func extractArchivesTo(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = fileURLs(from: pasteboard)
        guard let first = urls.first,
              let destination = AppState.shared.chooseFolder(message: "Extract to:", start: first.deletingLastPathComponent()) else { return }
        AppState.shared.extract(urls, to: destination)
    }

    @objc func browseArchive(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        NSApp.activate(ignoringOtherApps: true)
        fileURLs(from: pasteboard).forEach(AppState.shared.openArchiveWindow)
    }

    @objc func addToBasket(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let state = AppState.shared
        for url in fileURLs(from: pasteboard) where !state.basket.contains(url) { state.basket.append(url) }
        state.openWindow(id: "collect")
    }
}
