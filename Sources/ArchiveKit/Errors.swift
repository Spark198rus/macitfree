import Foundation

public enum ArchiveError: Error, LocalizedError, Equatable {
    /// The archive (or an entry in it) is encrypted and no password was supplied.
    case passwordRequired
    /// A password was supplied but it is wrong.
    case wrongPassword
    /// A helper command-line tool is not installed.
    case toolMissing(tool: String, hint: String)
    /// The operation is not supported for this format.
    case unsupported(String)
    /// A helper tool exited with an error.
    case toolFailed(tool: String, status: Int32, message: String)
    /// The archive is damaged or not an archive at all.
    case corrupt(String)
    /// The format of a file could not be determined.
    case unknownFormat(String)
    case cancelled
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .passwordRequired:
            return "This archive is encrypted. A password is required."
        case .wrongPassword:
            return "The password is incorrect."
        case let .toolMissing(tool, hint):
            return "The helper tool “\(tool)” is not installed. \(hint)"
        case let .unsupported(message):
            return message
        case let .toolFailed(tool, status, message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(tool) failed (exit code \(status))" + (trimmed.isEmpty ? "." : ":\n\(trimmed)")
        case let .corrupt(message):
            return "The archive appears to be damaged: \(message)"
        case let .unknownFormat(name):
            return "“\(name)” is not a recognised archive format."
        case .cancelled:
            return "The operation was cancelled."
        case let .invalidArgument(message):
            return message
        }
    }
}
