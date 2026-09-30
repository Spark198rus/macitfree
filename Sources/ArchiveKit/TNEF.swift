import Foundation

/// Decoder for Microsoft TNEF (`winmail.dat`) containers: extracts the embedded attachments.
public enum TNEF {
    public struct Attachment: Equatable {
        public var fileName: String
        public var data: Data
        public var modified: Date?
    }

    static let signature: UInt32 = 0x223E_9F78
    static let attAttachRendData: UInt32 = 0x0006_9002
    static let attAttachTitle: UInt32 = 0x0001_8010
    static let attAttachData: UInt32 = 0x0006_800F
    static let attAttachment: UInt32 = 0x0006_9005
    static let attAttachModifyDate: UInt32 = 0x0003_8013

    public static func attachments(in url: URL) throws -> [Attachment] {
        try attachments(in: Data(contentsOf: url))
    }

    public static func attachments(in data: Data) throws -> [Attachment] {
        let bytes = [UInt8](data)
        guard bytes.count >= 6, le32(bytes, 0) == signature else {
            throw ArchiveError.corrupt("not a TNEF (winmail.dat) file")
        }
        var result: [Attachment] = []
        var current: Attachment?
        var p = 6 // signature + legacy key
        while p + 9 <= bytes.count {
            let level = bytes[p]
            let attribute = le32(bytes, p + 1)
            let length = Int(le32(bytes, p + 5))
            let start = p + 9
            guard length >= 0, start + length + 2 <= bytes.count else { break }
            let value = Array(bytes[start..<start + length])
            p = start + length + 2 // skip checksum

            guard level == 2 else { continue } // attachment-level attributes only
            switch attribute {
            case attAttachRendData:
                if let current, !current.data.isEmpty || !current.fileName.isEmpty { result.append(current) }
                current = Attachment(fileName: "", data: Data(), modified: nil)
            case attAttachTitle:
                let name = cString(value)
                if current == nil { current = Attachment(fileName: "", data: Data(), modified: nil) }
                if current!.fileName.isEmpty { current!.fileName = name }
            case attAttachData:
                if current == nil { current = Attachment(fileName: "", data: Data(), modified: nil) }
                current!.data = Data(value)
            case attAttachModifyDate:
                current?.modified = dtr(value)
            case attAttachment:
                if let long = longFileName(inMAPIProperties: value), !long.isEmpty {
                    if current == nil { current = Attachment(fileName: "", data: Data(), modified: nil) }
                    current!.fileName = long
                }
            default:
                break
            }
        }
        if let current, !current.data.isEmpty || !current.fileName.isEmpty { result.append(current) }

        // Sanitise names and make them unique.
        var used = Set<String>()
        return result.enumerated().map { index, attachment in
            var a = attachment
            var name = sanitize(a.fileName)
            if name.isEmpty { name = "attachment-\(index + 1)" }
            var candidate = name
            var n = 2
            while used.contains(candidate.lowercased()) {
                let ext = (name as NSString).pathExtension
                let stem = (name as NSString).deletingPathExtension
                candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
                n += 1
            }
            used.insert(candidate.lowercased())
            a.fileName = candidate
            return a
        }
    }

    /// Writes every attachment into `directory`; returns the written files.
    @discardableResult
    public static func extract(_ url: URL, to directory: URL, only names: Set<String>? = nil) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for attachment in try attachments(in: url) where names == nil || names!.contains(attachment.fileName) {
            let target = directory.appendingPathComponent(attachment.fileName)
            try attachment.data.write(to: target)
            if let modified = attachment.modified {
                try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: target.path)
            }
            written.append(target)
        }
        return written
    }

    static func sanitize(_ name: String) -> String {
        let last = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        let cleaned = last.filter { $0 != "\0" && $0 != ":" }.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned == "." || cleaned == "..") ? "" : cleaned
    }

    /// Finds PR_ATTACH_LONG_FILENAME (0x3707) or PR_DISPLAY_NAME (0x3001) in an attAttachment MAPI block.
    static func longFileName(inMAPIProperties b: [UInt8]) -> String? {
        guard b.count >= 4 else { return nil }
        let count = Int(le32(b, 0))
        var p = 4
        var longName: String?
        var displayName: String?
        for _ in 0..<min(count, 10_000) {
            guard p + 4 <= b.count else { break }
            let type = le16(b, p)
            let id = le16(b, p + 2)
            p += 4
            if id >= 0x8000 { // named property: GUID, kind, id-or-name
                guard p + 20 <= b.count else { return longName ?? displayName }
                let kind = le32(b, p + 16)
                p += 20
                if kind == 0 {
                    p += 4
                } else {
                    guard p + 4 <= b.count else { return longName ?? displayName }
                    let nameLength = Int(le32(b, p))
                    p += 4 + padded(nameLength)
                }
            }
            let isMulti = type & 0x1000 != 0
            let baseType = type & 0x0FFF
            var valueCount = 1
            if isMulti || [0x001E, 0x001F, 0x0102, 0x000D].contains(baseType) {
                guard p + 4 <= b.count else { break }
                valueCount = Int(le32(b, p))
                p += 4
            }
            for _ in 0..<min(valueCount, 100_000) {
                switch baseType {
                case 0x0002, 0x0003, 0x000A, 0x000B, 0x0004:
                    p += 4
                case 0x0005, 0x0006, 0x0007, 0x0014, 0x0040:
                    p += 8
                case 0x0048:
                    p += 16
                case 0x001E, 0x001F, 0x0102, 0x000D:
                    guard p + 4 <= b.count else { return longName ?? displayName }
                    let length = Int(le32(b, p))
                    p += 4
                    guard length >= 0, p + length <= b.count else { return longName ?? displayName }
                    let raw = Array(b[p..<p + length])
                    if id == 0x3707 || id == 0x3001 {
                        let string: String? = baseType == 0x001F
                            ? String(bytes: raw, encoding: .utf16LittleEndian).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) }
                            : baseType == 0x001E ? cString(raw) : nil
                        if id == 0x3707 { longName = string } else { displayName = string }
                    }
                    p += padded(length)
                default:
                    return longName ?? displayName // unknown type: cannot continue safely
                }
            }
        }
        return longName ?? displayName
    }

    static func dtr(_ b: [UInt8]) -> Date? {
        guard b.count >= 12 else { return nil }
        var c = DateComponents()
        c.year = Int(le16(b, 0)); c.month = Int(le16(b, 2)); c.day = Int(le16(b, 4))
        c.hour = Int(le16(b, 6)); c.minute = Int(le16(b, 8)); c.second = Int(le16(b, 10))
        return Calendar(identifier: .gregorian).date(from: c)
    }

    private static func cString(_ bytes: [UInt8]) -> String {
        let trimmed = bytes.prefix { $0 != 0 }
        return String(bytes: trimmed, encoding: .utf8) ?? String(bytes: trimmed, encoding: .windowsCP1252) ?? ""
    }

    private static func padded(_ n: Int) -> Int { (n + 3) & ~3 }
    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
