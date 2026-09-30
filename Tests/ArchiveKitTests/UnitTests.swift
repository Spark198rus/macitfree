@testable import ArchiveKit
import XCTest

final class FormatDetectionTests: XCTestCase {
    func testDetectsByFileName() {
        XCTAssertEqual(ArchiveFormat.detect(fileName: "a.zip"), .zip)
        XCTAssertEqual(ArchiveFormat.detect(fileName: "Book.EPUB"), .zip)
        XCTAssertEqual(ArchiveFormat.detect(fileName: "x.tar.gz"), .tarGzip)
        XCTAssertEqual(ArchiveFormat.detect(fileName: "x.tgz"), .tarGzip)
        XCTAssertEqual(ArchiveFormat.detect(fileName: "x.gz"), .gzip)
        XCTAssertEqual(ArchiveFormat.detect(fileName: "x.tar.zst"), .tarZstd)
        XCTAssertEqual(ArchiveFormat.detect(fileName: "x.tar.Z"), .tarCompress)
        XCTAssertEqual(ArchiveFormat.detect(fileName: "x.Z"), .compress)
        XCTAssertEqual(ArchiveFormat.detect(fileName: "comic.cbr"), .rar)
        XCTAssertEqual(ArchiveFormat.detect(fileName: "backup.7z.001"), .split)
        XCTAssertEqual(ArchiveFormat.detect(fileName: "winmail.dat"), .tnef)
        XCTAssertEqual(ArchiveFormat.detect(fileName: "Installer.dmg"), .dmg)
        XCTAssertNil(ArchiveFormat.detect(fileName: "notes.txt"))
    }

    func testDetectsByMagic() {
        XCTAssertEqual(ArchiveFormat.detect(magic: Data([0x50, 0x4B, 0x03, 0x04, 0, 0])), .zip)
        XCTAssertEqual(ArchiveFormat.detect(magic: Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])), .sevenZip)
        XCTAssertEqual(ArchiveFormat.detect(magic: Data([0x1F, 0x8B, 8])), .gzip)
        XCTAssertEqual(ArchiveFormat.detect(magic: Data("BZh91AY".utf8)), .bzip2)
        XCTAssertEqual(ArchiveFormat.detect(magic: Data([0x28, 0xB5, 0x2F, 0xFD])), .zstd)
        XCTAssertEqual(ArchiveFormat.detect(magic: Data([0x78, 0x9F, 0x3E, 0x22])), .tnef)
        var tar = Data(count: 512)
        tar.replaceSubrange(257..<262, with: Data("ustar".utf8))
        XCTAssertEqual(ArchiveFormat.detect(magic: tar), .tar)
        XCTAssertNil(ArchiveFormat.detect(magic: Data("hello".utf8)))
    }

    func testBaseName() {
        XCTAssertEqual(ArchiveFormat.baseName(of: "photos.tar.gz"), "photos")
        XCTAssertEqual(ArchiveFormat.baseName(of: "photos.zip"), "photos")
        XCTAssertEqual(ArchiveFormat.baseName(of: "backup.7z.001"), "backup")
        XCTAssertEqual(ArchiveFormat.baseName(of: "readme.txt"), "readme")
        XCTAssertEqual(ArchiveFormat.baseName(of: ".zip"), ".zip")
    }
}

final class ListingParserTests: XCTestCase {
    func testBsdtarVerbose() {
        let output = """
        drwxr-xr-x  0 root   root        0 Sep 30 20:48 ./
        -rw-r--r--  0 user   staff      12 Jan  2  2020 ./dir one/a file.txt
        lrwxrwxrwx  0 0      0           0 Sep 30 20:48 dir one/link -> a file.txt
        drwxr-xr-x  0 0      0           0 Sep 30 20:48 dir one/sub/
        """
        let entries = ListingParsers.parseBsdtarVerbose(output, now: Date())
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[1].path, "dir one/a file.txt")
        XCTAssertEqual(entries[1].rawPath, "./dir one/a file.txt")
        XCTAssertEqual(entries[1].size, 12)
        XCTAssertEqual(entries[1].permissions, 0o644)
        let year = Calendar(identifier: .gregorian).component(.year, from: entries[1].modified!)
        XCTAssertEqual(year, 2020)
        XCTAssertTrue(entries[2].isSymlink)
        XCTAssertEqual(entries[2].linkTarget, "a file.txt")
        XCTAssertEqual(entries[2].path, "dir one/link")
        XCTAssertTrue(entries[3].isDirectory)
        XCTAssertEqual(entries[3].path, "dir one/sub")
        XCTAssertEqual(entries[3].selector, "dir one/sub")
    }

    func testSevenZipTechnical() {
        let output = """
        7-Zip 23.01 (x64)

        Listing archive: t.7z

        --
        Path = t.7z
        Type = 7z
        Physical Size = 270

        ----------
        Path = dir/a.txt
        Size = 6
        Packed Size = 16
        Modified = 2024-05-01 10:11:12.1234567
        Attributes = A -rw-r--r--
        CRC = 363A3020
        Encrypted = +
        Method = LZMA2:12 7zAES:19

        Path = dir
        Size = 0
        Packed Size = 0
        Modified = 2024-05-01 10:11:12
        Attributes = D drwxr-xr-x
        CRC =
        Encrypted = -
        Method =

        """
        let entries = ListingParsers.parseSevenZipTechnical(output)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].path, "dir/a.txt")
        XCTAssertEqual(entries[0].size, 6)
        XCTAssertEqual(entries[0].compressedSize, 16)
        XCTAssertTrue(entries[0].isEncrypted)
        XCTAssertEqual(entries[0].crc32, 0x363A3020)
        XCTAssertNotNil(entries[0].modified)
        XCTAssertTrue(entries[1].isDirectory)
        XCTAssertFalse(entries[1].isEncrypted)
        XCTAssertNil(entries[1].method)
    }

    func testTreeSynthesizesFolders() {
        let entries = [ArchiveEntry(rawPath: "a/b/c.txt", size: 5), ArchiveEntry(rawPath: "a/d.txt", size: 7), ArchiveEntry(rawPath: "z/")]
        let root = ArchiveNode.tree(from: entries)
        XCTAssertEqual(root.childNodes.map(\.name), ["a", "z"])
        let a = root.node(at: "a")!
        XCTAssertTrue(a.isSynthesized)
        XCTAssertEqual(a.size, 12)
        XCTAssertEqual(a.fileCount, 2)
        XCTAssertEqual(a.childNodes.map(\.name), ["b", "d.txt"])
        XCTAssertEqual(Set(a.selectors), ["a/b/c.txt", "a/d.txt"])
        XCTAssertNil(root.node(at: "a/d.txt")!.children)
        XCTAssertEqual(root.node(at: "z")!.selectors, ["z"])
        let top = ArchiveNode.topMost([a, root.node(at: "a/b/c.txt")!])
        XCTAssertEqual(top.map(\.path), ["a"])
    }
}

final class FilterTests: XCTestCase {
    func testJunkRules() {
        let filter = FileFilter()
        XCTAssertTrue(filter.excludes(name: ".DS_Store", relativePath: "x/.DS_Store", isDirectory: false))
        XCTAssertTrue(filter.excludes(name: "._photo.jpg", relativePath: "._photo.jpg", isDirectory: false))
        XCTAssertTrue(filter.excludes(name: "__MACOSX", relativePath: "__MACOSX", isDirectory: true))
        XCTAssertTrue(filter.excludes(name: "Thumbs.db", relativePath: "Thumbs.db", isDirectory: false))
        XCTAssertFalse(filter.excludes(name: ".git", relativePath: ".git", isDirectory: true))
        XCTAssertFalse(filter.excludes(name: "photo.jpg", relativePath: "photo.jpg", isDirectory: false))

        var dev = FileFilter()
        dev.excludeVersionControl = true
        dev.excludeBuildArtifacts = true
        dev.customPatterns = ["*.log", "secrets/*"]
        XCTAssertTrue(dev.excludes(name: ".git", relativePath: "p/.git", isDirectory: true))
        XCTAssertTrue(dev.excludes(name: "node_modules", relativePath: "p/node_modules", isDirectory: true))
        XCTAssertTrue(dev.excludes(name: "x.pyc", relativePath: "x.pyc", isDirectory: false))
        XCTAssertTrue(dev.excludes(name: "debug.log", relativePath: "p/debug.log", isDirectory: false))
        XCTAssertTrue(dev.excludes(name: "key.pem", relativePath: "secrets/key.pem", isDirectory: false))
        XCTAssertFalse(dev.excludes(name: "main.swift", relativePath: "p/main.swift", isDirectory: false))
    }

    func testSizeAndAgeRules() {
        var filter = FileFilter()
        filter.maximumFileSize = 100
        filter.maximumAgeDays = 10
        let now = Date()
        XCTAssertTrue(filter.excludes(size: 101, modified: now, now: now))
        XCTAssertFalse(filter.excludes(size: 100, modified: now, now: now))
        XCTAssertTrue(filter.excludes(size: 1, modified: now.addingTimeInterval(-11 * 86_400), now: now))
    }

    func testDecodingToleratesMissingKeys() throws {
        let filter = try JSONDecoder().decode(FileFilter.self, from: Data(#"{"excludeHiddenFiles": true}"#.utf8))
        XCTAssertTrue(filter.excludeHiddenFiles)
        XCTAssertTrue(filter.excludeMacJunk)
    }
}

final class ChecksumTests: XCTestCase {
    func testKnownVectors() {
        XCTAssertEqual(Checksum.sha256(of: Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Checksum.sha256(of: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            Checksum.sha256(of: Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    func testPortableImplementationMatches() {
        var portable = PortableSHA256()
        let data = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        portable.update(data.prefix(333))
        portable.update(data.dropFirst(333))
        let hex = portable.finalize().map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, Checksum.sha256(of: data))
    }

    func testFileHashAndMatching() throws {
        let dir = try FileOps.makeTemporaryDirectory("hash")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try Data("abc".utf8).write(to: file)
        let digest = try Checksum.sha256(of: file)
        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertTrue(Checksum.matches(digest, expected: "  BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD  a.txt\n"))
        XCTAssertFalse(Checksum.matches(digest, expected: "deadbeef"))
    }
}

final class PasswordGeneratorTests: XCTestCase {
    func testLengthAndClasses() {
        var generator = PasswordGenerator()
        generator.length = 32
        for _ in 0..<50 {
            let password = generator.generate()
            XCTAssertEqual(password.count, 32)
            XCTAssertTrue(password.contains { $0.isUppercase })
            XCTAssertTrue(password.contains { $0.isLowercase })
            XCTAssertTrue(password.contains { $0.isNumber })
            XCTAssertFalse(password.contains { "lI1O0o".contains($0) })
        }
        generator.includeSymbols = false
        generator.includeUppercase = false
        XCTAssertTrue(generator.generate().allSatisfy { $0.isLowercase || $0.isNumber })
        XCTAssertGreaterThan(PasswordGenerator().entropyBits, 100)
    }
}

final class TNEFTests: XCTestCase {
    /// Builds a minimal TNEF stream with one attachment using a short title and a MAPI long file name.
    static func makeTNEF(title: String, longName: String?, payload: Data) -> Data {
        var d = Data()
        func u16(_ v: UInt16) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
        func u32(_ v: UInt32) { for i in 0..<4 { d.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        func attribute(_ level: UInt8, _ id: UInt32, _ value: Data) {
            d.append(level)
            u32(id)
            u32(UInt32(value.count))
            d.append(value)
            u16(UInt16(value.reduce(0) { ($0 + Int($1)) & 0xFFFF }))
        }
        u32(0x223E_9F78)
        u16(0x0001)
        attribute(1, 0x0009_8000, Data([1, 0, 0, 0])) // message-level attribute (ignored)
        attribute(2, 0x0006_9002, Data(count: 14)) // attAttachRendData
        attribute(2, 0x0001_8010, Data(title.utf8) + Data([0])) // attAttachTitle
        attribute(2, 0x0006_800F, payload) // attAttachData
        if let longName {
            var mapi = Data()
            func m32(_ v: UInt32) { for i in 0..<4 { mapi.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
            m32(2) // two properties
            // PT_LONG PR_ATTACH_METHOD = 1
            mapi.append(contentsOf: [0x03, 0x00, 0x05, 0x37]); m32(1)
            // PT_UNICODE PR_ATTACH_LONG_FILENAME
            mapi.append(contentsOf: [0x1F, 0x00, 0x07, 0x37]); m32(1)
            let utf16 = Data((longName + "\0").utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
            m32(UInt32(utf16.count)); mapi.append(utf16)
            while mapi.count % 4 != 0 { mapi.append(0) }
            attribute(2, 0x0006_9005, mapi)
        }
        return d
    }

    func testDecodesAttachmentWithLongName() throws {
        let payload = Data("PDF-ish bytes".utf8)
        let data = Self.makeTNEF(title: "QUARTE~1.PDF", longName: "Quarterly Report ✓.pdf", payload: payload)
        let attachments = try TNEF.attachments(in: data)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0].fileName, "Quarterly Report ✓.pdf")
        XCTAssertEqual(attachments[0].data, payload)
    }

    func testFallsBackToTitleAndSanitizes() throws {
        let data = Self.makeTNEF(title: "../../evil.txt", longName: nil, payload: Data("x".utf8))
        let attachments = try TNEF.attachments(in: data)
        XCTAssertEqual(attachments.map(\.fileName), ["evil.txt"])
    }

    func testRejectsNonTNEF() {
        XCTAssertThrowsError(try TNEF.attachments(in: Data("hello world".utf8)))
    }
}

final class SplitTests: XCTestCase {
    func testSplitAndJoinRoundTrip() throws {
        let dir = try FileOps.makeTemporaryDirectory("split")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("blob.bin")
        let data = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0) })
        try data.write(to: file)
        let volumes = try SplitArchive.split(file, volumeSize: 3000)
        XCTAssertEqual(volumes.map(\.lastPathComponent), ["blob.bin.001", "blob.bin.002", "blob.bin.003", "blob.bin.004"])
        XCTAssertEqual(FileOps.fileSize(volumes[3]), 1000)
        let joined = try SplitArchive.join(firstVolume: volumes[0], to: dir.appendingPathComponent("joined.bin"))
        XCTAssertEqual(try Data(contentsOf: joined), data)
    }

    func testParseSize() {
        XCTAssertEqual(SplitArchive.parseSize("100m"), 100 * 1024 * 1024)
        XCTAssertEqual(SplitArchive.parseSize("1.5K"), 1536)
        XCTAssertEqual(SplitArchive.parseSize("20MB"), 20 * 1024 * 1024)
        XCTAssertEqual(SplitArchive.parseSize("4096"), 4096)
        XCTAssertNil(SplitArchive.parseSize("lots"))
    }
}

final class MiscTests: XCTestCase {
    func testCP437TableIsComplete() {
        XCTAssertEqual(ZipReader.decodeName([0x80, 0x81, 0xFF], utf8Flag: false).count, 3)
        XCTAssertEqual(ZipReader.decodeName([0x80, 0x81], utf8Flag: false), "Çü")
        XCTAssertEqual(ZipReader.decodeName(Array("naïve".utf8), utf8Flag: false), "naïve")
    }

    func testUniqueURL() throws {
        let dir = try FileOps.makeTemporaryDirectory("unique")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.tar.gz")
        XCTAssertEqual(FileOps.uniqueURL(for: url), url)
        try Data().write(to: url)
        XCTAssertEqual(FileOps.uniqueURL(for: url).lastPathComponent, "a 2.tar.gz")
    }

    func testFormatBytes() {
        XCTAssertEqual(FileOps.formatBytes(1), "1 byte")
        XCTAssertEqual(FileOps.formatBytes(1500), "1.5 KB")
        XCTAssertEqual(FileOps.formatBytes(250_000_000), "250 MB")
    }

    func testPresetsRoundTripThroughStore() throws {
        let dir = try FileOps.makeTemporaryDirectory("settings")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SettingsStore(directory: dir)
        XCTAssertEqual(store.loadPresets(), Preset.defaults)
        var presets = Preset.defaults
        presets[0].name = "Mine"
        presets[0].destination = .folder("/tmp/out")
        try store.savePresets(presets)
        XCTAssertEqual(store.loadPresets(), presets)
        try store.saveExtractOptions(ExtractOptions(folderPolicy: .always, removeJunk: false))
        XCTAssertEqual(store.loadExtractOptions().folderPolicy, .always)
    }

    func testPresetOutputName() {
        let zip = Preset(name: "z", format: .zip)
        XCTAssertEqual(zip.outputName(for: [URL(fileURLWithPath: "/tmp/report.pdf")]), "report.zip")
        XCTAssertEqual(zip.outputName(for: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]), "Archive.zip")
        let gz = Preset(name: "g", format: .gzip)
        XCTAssertEqual(gz.outputName(for: [URL(fileURLWithPath: "/tmp/data.csv")]), "data.csv.gz")
    }
}
