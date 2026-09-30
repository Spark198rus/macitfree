import Foundation

/// Parsers for the textual listings produced by helper tools.
public enum ListingParsers {
    // MARK: bsdtar -tv

    /// Parses `bsdtar -tvf` output, which looks like `ls -l`:
    /// `-rw-r--r--  0 user   staff      12 Sep 30 20:48 path/to/file`
    public static func parseBsdtarVerbose(_ output: String, now: Date = Date()) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if let entry = parseBsdtarLine(String(line), now: now) { entries.append(entry) }
        }
        return entries
    }

    static func parseBsdtarLine(_ line: String, now: Date) -> ArchiveEntry? {
        // Tokenise the first 8 whitespace-separated fields and remember where field 8 ends.
        var fields: [Substring] = []
        var index = line.startIndex
        while fields.count < 8 {
            while index < line.endIndex, line[index] == " " || line[index] == "\t" { index = line.index(after: index) }
            guard index < line.endIndex else { return nil }
            let start = index
            while index < line.endIndex, line[index] != " " && line[index] != "\t" { index = line.index(after: index) }
            fields.append(line[start..<index])
        }
        guard index < line.endIndex else { return nil }
        var name = String(line[line.index(after: index)...])
        let mode = fields[0]
        guard mode.count >= 10, let typeChar = mode.first else { return nil }

        var linkTarget: String?
        if typeChar == "l", let range = name.range(of: " -> ") {
            linkTarget = String(name[range.upperBound...])
            name = String(name[..<range.lowerBound])
        } else if typeChar == "h" || name.contains(" link to ") {
            if let range = name.range(of: " link to ") { name = String(name[..<range.lowerBound]) }
        }

        let size = UInt64(fields[4])
        let date = parseLsDate(month: String(fields[5]), day: String(fields[6]), timeOrYear: String(fields[7]), now: now)
        return ArchiveEntry(
            rawPath: name,
            isDirectory: typeChar == "d",
            isSymlink: typeChar == "l",
            linkTarget: linkTarget,
            size: typeChar == "d" ? 0 : size,
            modified: date,
            permissions: permissionBits(String(mode))
        )
    }

    static func permissionBits(_ mode: String) -> UInt16? {
        let chars = Array(mode)
        guard chars.count >= 10 else { return nil }
        var bits: UInt16 = 0
        let flags: [(Int, Character, UInt16)] = [
            (1, "r", 0o400), (2, "w", 0o200), (3, "x", 0o100),
            (4, "r", 0o040), (5, "w", 0o020), (6, "x", 0o010),
            (7, "r", 0o004), (8, "w", 0o002), (9, "x", 0o001),
        ]
        for (i, c, bit) in flags where chars[i] == c || (c == "x" && (chars[i] == "s" || chars[i] == "t")) {
            bits |= bit
        }
        return bits
    }

    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func parseLsDate(month: String, day: String, timeOrYear: String, now: Date) -> Date? {
        guard let m = months.firstIndex(of: month.lowercased().prefix(3).description), let d = Int(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        var components = DateComponents()
        components.month = m + 1
        components.day = d
        if timeOrYear.contains(":") {
            let hm = timeOrYear.split(separator: ":")
            components.hour = Int(hm[0])
            components.minute = hm.count > 1 ? Int(hm[1]) : 0
            // ls omits the year for recent dates (within ~6 months).
            let thisYear = calendar.component(.year, from: now)
            components.year = thisYear
            if let candidate = calendar.date(from: components), candidate > now.addingTimeInterval(86_400) {
                components.year = thisYear - 1
            }
        } else {
            components.year = Int(timeOrYear)
        }
        return calendar.date(from: components)
    }

    // MARK: 7-Zip -slt

    /// Parses `7z l -slt` technical listings (blocks of `Key = Value` lines).
    public static func parseSevenZipTechnical(_ output: String) -> [ArchiveEntry] {
        guard let separator = output.range(of: "\n----------\n") else { return [] }
        let body = output[separator.upperBound...]
        var entries: [ArchiveEntry] = []
        var fields: [String: String] = [:]

        func flush() {
            defer { fields.removeAll() }
            guard let path = fields["Path"] else { return }
            let attributes = fields["Attributes"] ?? ""
            let isDirectory = fields["Folder"] == "+" || attributes.hasPrefix("D")
            let unixPart = attributes.split(separator: " ").last.map(String.init) ?? ""
            let isSymlink = unixPart.hasPrefix("l") || fields["Symbolic Link"].map { !$0.isEmpty } == true
            entries.append(ArchiveEntry(
                rawPath: path,
                isDirectory: isDirectory,
                isSymlink: isSymlink,
                linkTarget: fields["Symbolic Link"].flatMap { $0.isEmpty ? nil : $0 },
                size: fields["Size"].flatMap { UInt64($0) },
                compressedSize: fields["Packed Size"].flatMap { UInt64($0) },
                modified: fields["Modified"].flatMap(parseSevenZipDate),
                isEncrypted: fields["Encrypted"] == "+",
                crc32: fields["CRC"].flatMap { UInt32($0, radix: 16) },
                permissions: unixPart.count >= 10 ? permissionBits(unixPart) : nil,
                method: fields["Method"].flatMap { $0.isEmpty ? nil : $0 }
            ))
        }

        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.isEmpty {
                flush()
                continue
            }
            guard let eq = line.range(of: " = ") else {
                if line.hasSuffix(" =") { fields[String(line.dropLast(2))] = "" }
                continue
            }
            fields[String(line[..<eq.lowerBound])] = String(line[eq.upperBound...])
        }
        flush()
        return entries
    }

    static func parseSevenZipDate(_ value: String) -> Date? {
        guard value.count >= 19 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: String(value.prefix(19)))
    }
}
