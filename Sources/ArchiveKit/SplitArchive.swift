import Foundation

/// Joining `name.001, name.002, …` volumes and splitting a file into such volumes.
public enum SplitArchive {
    public static func isFirstVolume(fileName: String) -> Bool {
        fileName.count > 4 && fileName.hasSuffix(".001")
    }

    /// All consecutive volumes starting at `first` (which must end in `.001`).
    public static func volumes(startingAt first: URL) -> [URL] {
        let fm = FileManager.default
        let stem = String(first.lastPathComponent.dropLast(4))
        let dir = first.deletingLastPathComponent()
        var result: [URL] = []
        var index = 1
        while true {
            let url = dir.appendingPathComponent(stem + "." + String(format: "%03d", index))
            guard fm.fileExists(atPath: url.path) else { break }
            result.append(url)
            index += 1
        }
        return result
    }

    /// Concatenates all volumes into `destination` (default: next to the volumes, without `.001`).
    @discardableResult
    public static func join(firstVolume: URL, to destination: URL? = nil, cancellation: Cancellation? = nil) throws -> URL {
        let volumes = volumes(startingAt: firstVolume)
        guard !volumes.isEmpty else { throw ArchiveError.invalidArgument("No volumes found for \(firstVolume.lastPathComponent).") }
        let output = destination ?? FileOps.uniqueURL(for: firstVolume.deletingPathExtension())
        _ = FileManager.default.createFile(atPath: output.path, contents: nil)
        let out = try FileHandle(forWritingTo: output)
        defer { try? out.close() }
        for volume in volumes {
            let input = try FileHandle(forReadingFrom: volume)
            defer { try? input.close() }
            while true {
                try cancellation?.check()
                let chunk = try input.read(upToCount: 4 << 20) ?? Data()
                if chunk.isEmpty { break }
                try out.write(contentsOf: chunk)
            }
        }
        return output
    }

    /// Splits `file` into volumes of `volumeSize` bytes named `file.001`, `file.002`, …
    /// Returns the volume URLs. The original file is left in place.
    @discardableResult
    public static func split(_ file: URL, volumeSize: UInt64, cancellation: Cancellation? = nil) throws -> [URL] {
        guard volumeSize > 0 else { throw ArchiveError.invalidArgument("Volume size must be positive.") }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var volumes: [URL] = []
        var index = 1
        let chunkSize = UInt64(4 << 20)
        while true {
            var remaining = volumeSize
            var first = try input.read(upToCount: Int(min(chunkSize, remaining))) ?? Data()
            if first.isEmpty { break }
            let url = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + "." + String(format: "%03d", index))
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            let out = try FileHandle(forWritingTo: url)
            defer { try? out.close() }
            while !first.isEmpty {
                try cancellation?.check()
                try out.write(contentsOf: first)
                remaining -= UInt64(first.count)
                if remaining == 0 { break }
                first = try input.read(upToCount: Int(min(chunkSize, remaining))) ?? Data()
            }
            volumes.append(url)
            index += 1
        }
        return volumes
    }

    /// Parses sizes like `100m`, `4.7g`, `650MB`, `1024k`, `12345`.
    public static func parseSize(_ text: String) -> UInt64? {
        let lower = text.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "ib", with: "").replacingOccurrences(of: "b", with: "")
        guard let last = lower.last else { return nil }
        let multipliers: [Character: Double] = ["k": 1024, "m": 1024 * 1024, "g": 1024 * 1024 * 1024]
        if let multiplier = multipliers[last], let value = Double(lower.dropLast()) {
            return value > 0 ? UInt64(value * multiplier) : nil
        }
        return UInt64(lower)
    }
}
