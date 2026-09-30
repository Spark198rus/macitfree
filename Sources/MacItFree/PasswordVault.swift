import AppKit
import ArchiveKit
import Foundation
import Security

/// Saved archive passwords, stored in the user's login Keychain (encrypted by macOS).
/// When an encrypted archive is opened, every saved password is tried automatically.
enum PasswordVault {
    static let service = "MacItFree Password Vault"

    struct Item: Identifiable, Hashable {
        var label: String
        var id: String { label }
    }

    static func items() -> [Item] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let rows = result as? [[String: Any]] else { return [] }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map(Item.init(label:))
    }

    static func password(for label: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: label,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func allPasswords() -> [String] {
        var seen = Set<String>()
        return items().compactMap { password(for: $0.label) }.filter { seen.insert($0).inserted }
    }

    /// Saves (or updates) a password under `label`.
    @discardableResult
    static func save(_ password: String, label: String) -> Bool {
        let label = label.isEmpty ? "Password \(Date().formatted(date: .abbreviated, time: .shortened))" : label
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: label,
        ]
        let data = Data(password.utf8)
        if SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        var add = match
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "MacItFree: \(label)"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func delete(label: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: label,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func contains(password: String) -> Bool {
        allPasswords().contains(password)
    }
}

/// Modal prompts built on NSAlert, usable from any window or from background flows (Services, Dock drops).
enum Prompts {
    struct PasswordAnswer {
        var password: String
        var remember: Bool
    }

    @MainActor
    static func askPassword(for name: String, wrongAttempt: Bool) -> PasswordAnswer? {
        let alert = NSAlert()
        alert.messageText = wrongAttempt ? "Wrong password for “\(name)”" : "“\(name)” is encrypted"
        alert.informativeText = wrongAttempt ? "Please try again." : "Enter the password to open it."
        alert.alertStyle = wrongAttempt ? .warning : .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: 280, height: 24))
        field.placeholderString = "Password"
        let remember = NSButton(checkboxWithTitle: "Remember in password vault", target: nil, action: nil)
        remember.frame = NSRect(x: 0, y: 0, width: 280, height: 20)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 54))
        container.addSubview(field)
        container.addSubview(remember)
        alert.accessoryView = container
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return nil }
        return PasswordAnswer(password: field.stringValue, remember: remember.state == .on)
    }

    /// Asks for a new password (twice) with a "Generate" option. Returns nil if cancelled.
    @MainActor
    static func askNewPassword(title: String) -> PasswordAnswer? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "The password can’t be recovered if you forget it."
        alert.addButton(withTitle: "Encrypt")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Generate")

        let first = NSSecureTextField(frame: NSRect(x: 0, y: 58, width: 300, height: 24))
        first.placeholderString = "Password"
        let second = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: 300, height: 24))
        second.placeholderString = "Verify password"
        let remember = NSButton(checkboxWithTitle: "Remember in password vault", target: nil, action: nil)
        remember.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
        remember.state = .on
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 84))
        [first, second, remember].forEach(container.addSubview)
        alert.accessoryView = container
        alert.window.initialFirstResponder = first
        NSApp.activate(ignoringOtherApps: true)

        while true {
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if first.stringValue.isEmpty { NSSound.beep(); continue }
                if first.stringValue != second.stringValue {
                    alert.informativeText = "The passwords don’t match. Try again."
                    continue
                }
                return PasswordAnswer(password: first.stringValue, remember: remember.state == .on)
            case .alertThirdButtonReturn:
                let generated = GeneratorSettings.load().generate()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(generated, forType: .string)
                let info = NSAlert()
                info.messageText = "Generated password (copied to the clipboard)"
                info.informativeText = generated
                info.addButton(withTitle: "Use This Password")
                info.addButton(withTitle: "Cancel")
                if info.runModal() == .alertFirstButtonReturn {
                    return PasswordAnswer(password: generated, remember: remember.state == .on)
                }
            default:
                return nil
            }
        }
    }

    @MainActor
    static func askText(title: String, message: String = "", initial: String = "", confirm: String = "OK") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    @MainActor
    static func confirm(_ title: String, message: String, destructive: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: destructive)
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    static func showError(_ error: Error, title: String = "The operation couldn’t be completed") {
        if let archiveError = error as? ArchiveError, archiveError == .cancelled { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
