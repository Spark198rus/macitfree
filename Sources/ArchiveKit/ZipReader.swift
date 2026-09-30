import Foundation

/// Native reader for the ZIP central directory (including ZIP64). Gives exact, locale-independent
/// listings with per-entry encryption flags, which command-line tools do not report reliably.
public enum ZipReader {
    public static func list(_ url: URL) throws -> [ArchiveEntry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw ArchiveError.corrupt("file is too small to be a ZIP archive") }

        // The end-of-central-directory record lives in the last 22 + 65535 bytes.
        let tailLength = min(fileSize, 22 + 65_535)
        try handle.seek(toOffset: fileSize - tailLength)
        let tail = [UInt8](try handle.read(upToCount: Int(tailLength)) ?? Data())
        guard let eocd = lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: tail, minimumRemaining: 22) else {
            throw ArchiveError.corrupt("end of central directory not found")
        }

        var entryCount = UInt64(le16(tail, eocd + 10))
        var cdSize = UInt64(le32(tail, eocd + 12))
        var cdOffset = UInt64(le32(tail, eocd + 16))

        // ZIP64 locator sits immediately before the EOCD record.
        let eocdAbsolute = fileSize - tailLength + UInt64(eocd)
        if eocdAbsolute >= 20 {
            try handle.seek(toOffset: eocdAbsolute - 20)
            let locator = [UInt8](try handle.read(upToCount: 20) ?? Data())
            if locator.count == 20 && Array(locator[0..<4]) == [0x50, 0x4B, 0x06, 0x07] {
                let zip64Offset = le64(locator, 8)
                try handle.seek(toOffset: zip64Offset)
                let record = [UInt8](try handle.read(upToCount: 56) ?? Data())
                if record.count == 56 && Array(record[0..<4]) == [0x50, 0x4B, 0x06, 0x06] {
                    entryCount = le64(record, 32)
                    cdSize = le64(record, 40)
                    cdOffset = le64(record, 48)
                }
            }
        }

        // Self-extracting archives have data prepended; adjust offsets if the CD is not where it claims.
        var cdStart = cdOffset
        if cdOffset + cdSize > eocdAbsolute || !signatureMatches(handle, at: cdOffset, [0x50, 0x4B, 0x01, 0x02]) {
            if eocdAbsolute >= cdSize { cdStart = eocdAbsolute - cdSize }
        }
        guard cdSize < 1 << 32 else { throw ArchiveError.corrupt("central directory is implausibly large") }
        try handle.seek(toOffset: cdStart)
        let cd = [UInt8](try handle.read(upToCount: Int(cdSize)) ?? Data())

        var entries: [ArchiveEntry] = []
        entries.reserveCapacity(Int(min(entryCount, 1_000_000)))
        var p = 0
        while p + 46 <= cd.count, Array(cd[p..<p + 4]) == [0x50, 0x4B, 0x01, 0x02] {
            let madeBy = le16(cd, p + 4)
            let flags = le16(cd, p + 8)
            let method = le16(cd, p + 10)
            let dosTime = le16(cd, p + 12)
            let dosDate = le16(cd, p + 14)
            let crc = le32(cd, p + 16)
            var compressed = UInt64(le32(cd, p + 20))
            var uncompressed = UInt64(le32(cd, p + 24))
            let nameLength = Int(le16(cd, p + 28))
            let extraLength = Int(le16(cd, p + 30))
            let commentLength = Int(le16(cd, p + 32))
            let externalAttributes = le32(cd, p + 38)
            let nameStart = p + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= cd.count else { throw ArchiveError.corrupt("truncated central directory") }

            let nameBytes = Array(cd[nameStart..<extraStart])
            var name = decodeName(nameBytes, utf8Flag: flags & 0x0800 != 0)
            var modified: Date? = dosDateTime(date: dosDate, time: dosTime)

            // Walk extra fields: ZIP64 sizes, extended timestamp, Info-ZIP Unicode path.
            var e = extraStart
            while e + 4 <= extraStart + extraLength {
                let id = le16(cd, e)
                let size = Int(le16(cd, e + 2))
                let body = e + 4
                guard body + size <= extraStart + extraLength else { break }
                switch id {
                case 0x0001:
                    var q = body
                    if uncompressed == 0xFFFF_FFFF, q + 8 <= body + size { uncompressed = le64(cd, q); q += 8 }
                    if compressed == 0xFFFF_FFFF, q + 8 <= body + size { compressed = le64(cd, q); q += 8 }
                case 0x5455:
                    if size >= 5 && cd[body] & 1 != 0 {
                        modified = Date(timeIntervalSince1970: TimeInterval(Int32(bitPattern: le32(cd, body + 1))))
                    }
                case 0x7075:
                    if size > 5, let unicode = String(bytes: cd[(body + 5)..<(body + size)], encoding: .utf8) {
                        name = unicode
                    }
                default:
                    break
                }
                e = body + size
            }

            let hostOS = madeBy >> 8
            let unixMode: UInt16? = (hostOS == 3 || hostOS == 19) ? UInt16(truncatingIfNeeded: externalAttributes >> 16) : nil
            let fileType = (unixMode ?? 0) & 0o170000
            let isDirectory = name.hasSuffix("/") || fileType == 0o040000 || (unixMode == nil && externalAttributes & 0x10 != 0)
            let isSymlink = fileType == 0o120000

            entries.append(ArchiveEntry(
                rawPath: name,
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                size: uncompressed,
                compressedSize: compressed,
                modified: modified,
                isEncrypted: flags & 1 != 0,
                crc32: crc,
                permissions: unixMode.map { $0 & 0o7777 },
                method: methodName(method)
            ))
            p = next
        }
        return entries
    }

    static func methodName(_ method: UInt16) -> String {
        switch method {
        case 0: return "Stored"
        case 8: return "Deflate"
        case 9: return "Deflate64"
        case 12: return "BZip2"
        case 14: return "LZMA"
        case 93: return "Zstandard"
        case 95: return "XZ"
        case 98: return "PPMd"
        case 99: return "AES"
        default: return "Method \(method)"
        }
    }

    private static func signatureMatches(_ handle: FileHandle, at offset: UInt64, _ sig: [UInt8]) -> Bool {
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: sig.count) else { return false }
        return [UInt8](data) == sig
    }

    private static func lastIndex(of sig: [UInt8], in bytes: [UInt8], minimumRemaining: Int) -> Int? {
        guard bytes.count >= minimumRemaining else { return nil }
        var i = bytes.count - minimumRemaining
        while i >= 0 {
            if bytes[i] == sig[0] && bytes[i + 1] == sig[1] && bytes[i + 2] == sig[2] && bytes[i + 3] == sig[3] {
                return i
            }
            i -= 1
        }
        return nil
    }

    static func decodeName(_ bytes: [UInt8], utf8Flag: Bool) -> String {
        // Many Mac/Unix tools write UTF-8 without setting the flag, so try UTF-8 first either way.
        if let utf8 = String(bytes: bytes, encoding: .utf8) { return utf8 }
        return String(bytes.map { $0 < 0x80 ? Character(UnicodeScalar($0)) : cp437High[Int($0) - 0x80] })
    }

    private static let cp437High: [Character] = Array(
        "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■\u{00A0}"
    )

    static func dosDateTime(date: UInt16, time: UInt16) -> Date? {
        guard date != 0 else { return nil }
        var components = DateComponents()
        components.year = 1980 + Int(date >> 9)
        components.month = Int((date >> 5) & 0x0F)
        components.day = Int(date & 0x1F)
        components.hour = Int(time >> 11)
        components.minute = Int((time >> 5) & 0x3F)
        components.second = Int(time & 0x1F) * 2
        return Calendar(identifier: .gregorian).date(from: components)
    }

    private static func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
    private static func le64(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(le32(b, i)) | UInt64(le32(b, i + 4)) << 32
    }
}
