@testable import ArchiveKit
import XCTest

/// End-to-end tests that drive the real helper tools. Formats whose tools are missing are skipped.
final class IntegrationTests: XCTestCase {
    var work: URL!
    var source: URL!

    override func setUpWithError() throws {
        work = try FileOps.makeTemporaryDirectory("tests")
        source = work.appendingPathComponent("Project", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: source.appendingPathComponent("docs/empty", isDirectory: true), withIntermediateDirectories: true)
        try Data("hello world\n".utf8).write(to: source.appendingPathComponent("readme.txt"))
        try Data("Ünïcødé [brackets] *star*\n".utf8).write(to: source.appendingPathComponent("docs/Ünïcødé [1] *.md"))
        try Data(repeating: 0x41, count: 50_000).write(to: source.appendingPathComponent("docs/big.bin"))
        try Data("junk".utf8).write(to: source.appendingPathComponent(".DS_Store"))
        try Data("junk".utf8).write(to: source.appendingPathComponent("docs/._big.bin"))
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("link.txt").path, withDestinationPath: "readme.txt")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    private func requireTools(_ format: ArchiveFormat, encrypted: Bool = false) throws {
        try XCTSkipUnless(ArchiveCreator.canCreate(format, encrypted: encrypted), "tools for \(format.rawValue) not installed")
    }

    private func assertTreeMatchesSource(_ root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let fm = FileManager.default
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("readme.txt"), encoding: .utf8), "hello world\n", file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("docs/big.bin")).count, 50_000, file: file, line: line)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("docs/Ünïcødé [1] *.md").path), file: file, line: line)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(".DS_Store").path), "junk should be filtered", file: file, line: line)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("docs/._big.bin").path), "junk should be filtered", file: file, line: line)
    }

    private func roundTrip(_ format: ArchiveFormat, password: String? = nil) throws {
        try requireTools(format, encrypted: password != nil)
        let output = work.appendingPathComponent("out." + format.preferredExtension)
        var options = CreateOptions(format: format, compressionLevel: 5, password: password)
        options.encryptFileNames = false
        let result = try ArchiveCreator.create([source], at: output, options: options)
        XCTAssertEqual(result.outputs, [output])
        XCTAssertEqual(result.itemCount, 4) // readme, unicode md, big.bin, link

        let archive = try Archive(url: output)
        archive.password = password
        try archive.load()
        XCTAssertEqual(archive.contentFormat, format)
        XCTAssertNotNil(archive.root.node(at: "Project/docs/big.bin"))
        XCTAssertNil(archive.root.node(at: "Project/.DS_Store"))
        if password != nil { XCTAssertTrue(archive.isEncrypted) }
        try archive.test()

        let destination = work.appendingPathComponent("extracted-\(format.rawValue)", isDirectory: true)
        let results = try archive.extract(to: destination)
        XCTAssertEqual(results.map(\.lastPathComponent), ["Project"], "smart folder: single top-level item is not wrapped")
        try assertTreeMatchesSource(results[0])
        archive.cleanup()
    }

    func testZipRoundTrip() throws { try roundTrip(.zip) }
    func testSevenZipRoundTrip() throws { try roundTrip(.sevenZip) }
    func testTarRoundTrip() throws { try roundTrip(.tar) }
    func testTarGzipRoundTrip() throws { try roundTrip(.tarGzip) }
    func testTarBzip2RoundTrip() throws { try roundTrip(.tarBzip2) }
    func testTarXzRoundTrip() throws { try roundTrip(.tarXz) }
    func testTarZstdRoundTrip() throws { try roundTrip(.tarZstd) }
    func testXarRoundTrip() throws { try roundTrip(.xar) }
    func testCpioRoundTrip() throws { try roundTrip(.cpio) }
    func testEncryptedZipRoundTrip() throws { try roundTrip(.zip, password: "correct horse") }

    func testEncryptedSevenZipWithHiddenNames() throws {
        try XCTSkipUnless(ToolLocator.isAvailable(.sevenZip), "7-Zip not installed")
        let output = work.appendingPathComponent("secret.7z")
        try ArchiveCreator.create([source], at: output, options: CreateOptions(format: .sevenZip, password: "pw"))
        let archive = try Archive(url: output)
        XCTAssertThrowsError(try archive.load()) { XCTAssertEqual($0 as? ArchiveError, .passwordRequired) }
        XCTAssertFalse(archive.verify(password: "nope"))
        XCTAssertEqual(archive.tryPasswords(["a", "b", "pw"]), "pw")
        try archive.load()
        XCTAssertTrue(archive.hasEncryptedListing)
        XCTAssertNotNil(archive.root.node(at: "Project/readme.txt"))
    }

    func testEncryptedZipPasswordHandling() throws {
        try requireTools(.zip, encrypted: true)
        let output = work.appendingPathComponent("secret.zip")
        try ArchiveCreator.create([source], at: output, options: CreateOptions(format: .zip, password: "s3cret"))
        let archive = try Archive(url: output)
        try archive.load() // ZIP listings are not encrypted
        XCTAssertTrue(archive.isEncrypted)
        let destination = work.appendingPathComponent("x", isDirectory: true)
        XCTAssertThrowsError(try archive.extract(to: destination)) { XCTAssertEqual($0 as? ArchiveError, .passwordRequired) }
        archive.password = "wrong"
        XCTAssertThrowsError(try archive.extract(to: destination)) { XCTAssertEqual($0 as? ArchiveError, .wrongPassword) }
        XCTAssertTrue(archive.verify(password: "s3cret"))
        XCTAssertFalse(archive.verify(password: "wrong"))
        archive.password = "s3cret"
        let results = try archive.extract(to: destination)
        try assertTreeMatchesSource(results[0])
    }

    func testSelectiveExtractionFlattensToSelection() throws {
        try requireTools(.tarGzip)
        let output = work.appendingPathComponent("sel.tar.gz")
        try ArchiveCreator.create([source], at: output, options: CreateOptions(format: .tarGzip))
        let archive = try Archive(url: output)
        try archive.load()
        let destination = work.appendingPathComponent("sel", isDirectory: true)
        let results = try archive.extract(paths: ["Project/docs/Ünïcødé [1] *.md", "Project/readme.txt"], to: destination)
        XCTAssertEqual(Set(results.map(\.lastPathComponent)), ["Ünïcødé [1] *.md", "readme.txt"])
        // Extracting again does not overwrite: Finder-style unique names.
        let again = try archive.extract(paths: ["Project/readme.txt"], to: destination)
        XCTAssertEqual(again.map(\.lastPathComponent), ["readme 2.txt"])
        let folder = try archive.extract(paths: ["Project/docs"], to: destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder[0].appendingPathComponent("big.bin").path))

        let previews = try archive.extractForPreview(paths: ["Project/readme.txt"])
        XCTAssertEqual(try String(contentsOf: previews[0], encoding: .utf8), "hello world\n")
        XCTAssertEqual(try archive.extractForPreview(paths: ["Project/readme.txt"]), previews, "preview is cached")
    }

    func testFolderPolicies() throws {
        try requireTools(.zip)
        let other = work.appendingPathComponent("other.txt")
        try Data("x".utf8).write(to: other)
        let output = work.appendingPathComponent("multi.zip")
        try ArchiveCreator.create([source, other], at: output, options: CreateOptions(format: .zip))
        let archive = try Archive(url: output)
        try archive.load()
        XCTAssertEqual(archive.root.childNodes.map(\.name), ["Project", "other.txt"])

        let smart = try archive.extract(to: work.appendingPathComponent("smart"))
        XCTAssertEqual(smart.map(\.lastPathComponent), ["multi"])
        let never = try archive.extract(to: work.appendingPathComponent("never"), options: ExtractOptions(folderPolicy: .never))
        XCTAssertEqual(Set(never.map(\.lastPathComponent)), ["Project", "other.txt"])
    }

    func testFiltersAndExclusions() throws {
        try requireTools(.zip)
        var filter = FileFilter()
        filter.customPatterns = ["*.bin"]
        let output = work.appendingPathComponent("filtered.zip")
        try ArchiveCreator.create([source], at: output, options: CreateOptions(format: .zip, filter: filter))
        let names = Set(try ZipReader.list(output).map(\.path))
        XCTAssertTrue(names.contains("Project/readme.txt"))
        XCTAssertFalse(names.contains("Project/docs/big.bin"))
        XCTAssertFalse(names.contains("Project/.DS_Store"))
        XCTAssertTrue(names.contains("Project/docs/empty"), "empty folders are kept")

        let everything = work.appendingPathComponent("everything.zip")
        try ArchiveCreator.create([source], at: everything, options: CreateOptions(format: .zip, filter: .keepEverything))
        XCTAssertTrue(Set(try ZipReader.list(everything).map(\.path)).contains("Project/.DS_Store"))
    }

    private func modify(_ format: ArchiveFormat, password: String? = nil) throws {
        try requireTools(format, encrypted: password != nil)
        let output = work.appendingPathComponent("mod." + format.preferredExtension)
        try ArchiveCreator.create([source], at: output, options: CreateOptions(format: format, password: password))
        let archive = try Archive(url: output)
        archive.password = password
        try archive.load()
        XCTAssertTrue(archive.canModify)

        let extra = work.appendingPathComponent("added.txt")
        try Data("added".utf8).write(to: extra)
        try archive.add([extra], toFolder: "Project/new folder")
        XCTAssertNotNil(archive.root.node(at: "Project/new folder/added.txt"))

        try archive.delete(paths: ["Project/docs"])
        XCTAssertNil(archive.root.node(at: "Project/docs"))
        XCTAssertNil(archive.root.node(at: "Project/docs/big.bin"))

        try archive.rename(path: "Project/readme.txt", to: "README.md")
        XCTAssertNotNil(archive.root.node(at: "Project/README.md"))
        XCTAssertNil(archive.root.node(at: "Project/readme.txt"))

        let edited = work.appendingPathComponent("edited.md")
        try Data("edited!".utf8).write(to: edited)
        try archive.replace(path: "Project/README.md", with: edited)

        try archive.makeFolder(named: "Empty", inFolder: "Project")
        XCTAssertNotNil(archive.root.node(at: "Project/Empty"))

        try archive.test()
        if password != nil { XCTAssertTrue(archive.isEncrypted, "rebuild keeps encryption") }
        let out = try archive.extract(to: work.appendingPathComponent("mod-out-\(format.rawValue)"))
        XCTAssertEqual(try String(contentsOf: out[0].appendingPathComponent("README.md"), encoding: .utf8), "edited!")
        XCTAssertEqual(try String(contentsOf: out[0].appendingPathComponent("new folder/added.txt"), encoding: .utf8), "added")
        XCTAssertEqual(FileOps.contents(of: work).filter { $0.lastPathComponent.hasPrefix(".macitfree-") }, [], "no staging leftovers")
    }

    func testModifyZip() throws { try modify(.zip) }
    func testModifyEncryptedZip() throws { try modify(.zip, password: "pw") }
    func testModifyTarGzip() throws { try modify(.tarGzip) }
    func testModifySevenZip() throws { try modify(.sevenZip) }

    func testSingleFileCompressors() throws {
        let file = source.appendingPathComponent("docs/big.bin")
        for format in [ArchiveFormat.gzip, .bzip2, .xz, .zstd, .brotli, .lz4] {
            guard ArchiveCreator.canCreate(format) else { continue }
            let output = work.appendingPathComponent("big.bin." + format.preferredExtension)
            try ArchiveCreator.create([file], at: output, options: CreateOptions(format: format, compressionLevel: 9))
            XCTAssertLessThan(FileOps.fileSize(output), 50_000, format.rawValue)
            let archive = try Archive(url: output)
            try archive.load()
            XCTAssertEqual(archive.entries.map(\.path), ["big.bin"], format.rawValue)
            try archive.test()
            let results = try archive.extract(to: work.appendingPathComponent("single-\(format.rawValue)"))
            XCTAssertEqual(try Data(contentsOf: results[0]).count, 50_000, format.rawValue)
        }
        XCTAssertThrowsError(try ArchiveCreator.create([source], at: work.appendingPathComponent("dir.gz"), options: CreateOptions(format: .gzip)))
    }

    func testSplitArchiveOpensAsOne() throws {
        try requireTools(.zip)
        let output = work.appendingPathComponent("vol.zip")
        var options = CreateOptions(format: .zip, compressionLevel: 0)
        options.volumeSize = 20_000
        let result = try ArchiveCreator.create([source], at: output, options: options)
        XCTAssertGreaterThan(result.outputs.count, 1)
        XCTAssertEqual(result.outputs[0].lastPathComponent, "vol.zip.001")
        XCTAssertEqual(ArchiveFormat.detect(url: result.outputs[0]), .split)

        let archive = try Archive(url: result.outputs[0])
        try archive.load()
        XCTAssertEqual(archive.contentFormat, .zip)
        XCTAssertFalse(archive.canModify)
        let out = try archive.extract(to: work.appendingPathComponent("vol-out"))
        try assertTreeMatchesSource(out[0])
    }

    func testTNEFArchive() throws {
        let url = work.appendingPathComponent("winmail.dat")
        try TNEFTests.makeTNEF(title: "A.TXT", longName: "Attachment.txt", payload: Data("tnef!".utf8)).write(to: url)
        let archive = try Archive(url: url)
        try archive.load()
        XCTAssertEqual(archive.entries.map(\.path), ["Attachment.txt"])
        let out = try archive.extract(to: work.appendingPathComponent("tnef-out"))
        XCTAssertEqual(out.map(\.lastPathComponent), ["Attachment.txt"])
        XCTAssertEqual(try String(contentsOf: out[0], encoding: .utf8), "tnef!")
    }

    func testMultipleSourcesFromDifferentFolders() throws {
        try requireTools(.tarGzip)
        let other = work.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let note = other.appendingPathComponent("note.txt")
        try Data("n".utf8).write(to: note)
        let output = work.appendingPathComponent("mixed.tar.gz")
        try ArchiveCreator.create([source.appendingPathComponent("readme.txt"), note], at: output, options: CreateOptions(format: .tarGzip))
        let archive = try Archive(url: output)
        try archive.load()
        XCTAssertEqual(Set(archive.entries.map(\.path)), ["readme.txt", "note.txt"])
    }

    func testCorruptArchiveFailsTest() throws {
        try requireTools(.zip)
        let output = work.appendingPathComponent("corrupt.zip")
        try ArchiveCreator.create([source], at: output, options: CreateOptions(format: .zip, compressionLevel: 9))
        var bytes = try Data(contentsOf: output)
        // Flip bytes in the middle of the compressed data.
        for i in 200..<260 { bytes[i] ^= 0xFF }
        try bytes.write(to: output)
        let archive = try Archive(url: output)
        try archive.load()
        XCTAssertThrowsError(try archive.test())
    }
}
