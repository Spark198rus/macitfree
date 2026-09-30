import Foundation

/// Lets a caller cancel a long-running operation (terminates the running helper process).
public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        if let running, running.isRunning { running.terminate() }
    }

    public func check() throws {
        if isCancelled { throw ArchiveError.cancelled }
    }

    fileprivate func attach(_ process: Process?) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
    }
}

public struct ProcessResult {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    /// stdout and stderr combined, for error-message sniffing.
    public var combinedOutput: String { stdoutString + "\n" + stderrString }
}

public enum ProcessRunner {
    /// Runs a tool to completion. stdout/stderr are captured through temporary files so large
    /// outputs never dead-lock on a full pipe. stdin is `/dev/null` unless `input` is given, so
    /// helpers never block waiting for an interactive password prompt.
    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        input: Data? = nil,
        stdoutFile: URL? = nil,
        discardStdout: Bool = false,
        environment: [String: String] = [:],
        cancellation: Cancellation? = nil
    ) throws -> ProcessResult {
        try cancellation?.check()
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("macitfree-proc-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let outURL = stdoutFile ?? scratch.appendingPathComponent("stdout")
        let errURL = scratch.appendingPathComponent("stderr")
        _ = fm.createFile(atPath: outURL.path, contents: nil)
        _ = fm.createFile(atPath: errURL.path, contents: nil)
        let outHandle = discardStdout ? FileHandle.nullDevice : try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = defaultUTF8Locale
        env["LANG"] = defaultUTF8Locale
        env["COPYFILE_DISABLE"] = "1" // never add AppleDouble ._ files when archiving on macOS
        for (key, value) in environment { env[key] = value }
        process.environment = env
        process.standardOutput = outHandle
        process.standardError = errHandle

        var inHandle: FileHandle?
        if let input {
            let inURL = scratch.appendingPathComponent("stdin")
            try input.write(to: inURL)
            inHandle = try FileHandle(forReadingFrom: inURL)
            process.standardInput = inHandle
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        cancellation?.attach(process)
        defer { cancellation?.attach(nil) }
        do {
            try process.run()
        } catch {
            throw ArchiveError.toolFailed(tool: executable.lastPathComponent, status: -1, message: error.localizedDescription)
        }
        process.waitUntilExit()
        if !discardStdout { try? outHandle.close() }
        try? errHandle.close()
        try? inHandle?.close()

        if cancellation?.isCancelled == true { throw ArchiveError.cancelled }

        let stdout = stdoutFile == nil && !discardStdout ? ((try? Data(contentsOf: outURL)) ?? Data()) : Data()
        let stderr = (try? Data(contentsOf: errURL)) ?? Data()
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    static var defaultUTF8Locale: String {
        #if os(macOS)
        return "en_US.UTF-8"
        #else
        return "C.UTF-8"
        #endif
    }
}
