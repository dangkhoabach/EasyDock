import CryptoKit
import Darwin
import EasyDockCore
import Foundation
import os
import Testing
@testable import EasyDock

/// Real archives made by the real 7-Zip helper in its sandbox, then opened
/// again by EasyDock's own extractor.
///
/// The tree: `Dự án/` holding `Tài liệu.txt` with its accents as separate
/// marks, as macOS often stores them, an executable `run.sh`, `sub/data.bin`
/// (200 000 random bytes), a link to `run.sh` and one to `/etc/hosts`, and
/// Finder's `.DS_Store` and `._run.sh`.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ArchiveCompressorTests {
    private static let document = "Ta\u{300}i lie\u{302}\u{323}u.txt"
    private static let project = "Du\u{31B}\u{323} a\u{301}n"

    private struct Tree {
        let folder: URL
        let item: URL
        let dataSHA256: String
    }

    /// A new folder holding the tree, or `files` (name to size) of random bytes.
    private func makeTree(files: [String: Int] = [:]) throws -> Tree {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("compress-\(UUID().uuidString)")
        let item = folder.appendingPathComponent(Self.project)
        try FileManager.default.createDirectory(at: item.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("xin chào thế giới\n".utf8).write(to: item.appendingPathComponent(Self.document))
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: item.appendingPathComponent("run.sh"))
        chmod(item.appendingPathComponent("run.sh").path, 0o755)
        let data = random(200_000)
        try data.write(to: item.appendingPathComponent("sub/data.bin"))
        for (name, size) in files { try random(size).write(to: item.appendingPathComponent(name)) }
        try FileManager.default.createSymbolicLink(atPath: item.appendingPathComponent("link-in").path, withDestinationPath: "run.sh")
        try FileManager.default.createSymbolicLink(atPath: item.appendingPathComponent("link-out").path, withDestinationPath: "/etc/hosts")
        try Data("finder".utf8).write(to: item.appendingPathComponent(".DS_Store"))
        try Data("appledouble".utf8).write(to: item.appendingPathComponent("._run.sh"))
        return Tree(folder: folder, item: item, dataSHA256: sha256(data))
    }

    private func random(_ count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, count) }
        return data
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func compress(_ items: [URL], as name: String = "Archive", format: CompressFormat, password: String = "",
                          partSize: Int = 0, into destination: URL? = nil) async throws(ArchiveCompressor.Failure) -> ArchiveCompressor.Result {
        let fileName = CompressNaming.fileName(name, format: format, fallback: "Archive")
        let options = ArchiveCompressor.Options(format: format, level: .fast, password: password, partSize: partSize)
        return try await ArchiveCompressor.compress(items, fileName: fileName, into: destination ?? items[0].deletingLastPathComponent(),
                                                    options: options) { _, _ in }
    }

    /// Opens `archive` into a new folder with EasyDock's extractor.
    private func extract(_ archive: URL, password: String? = nil,
                         asked: OSAllocatedUnfairLock<Int> = .init(initialState: 0)) async throws(ArchiveExtractor.Failure) -> URL? {
        let destination = archive.deletingLastPathComponent().appendingPathComponent("out-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        return try await ArchiveExtractor.extract(archive, into: destination, progress: { _, _ in }) {
            asked.withLock { $0 += 1 }
            return password
        }.item
    }

    /// The tree as it went in, less Finder's files; the link to the outside
    /// was kept as a link, never as the file it points to.
    private func expectTree(_ root: URL, _ tree: Tree, nfc: Bool) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let document = try #require(names.first { $0 == Self.document }, "\(names)")
        // On disk the name is as the archive holds it: NFC after renaming, else as
        // Foundation wrote it, accents apart in canonical order.
        let expected = nfc ? Self.document.precomposedStringWithCanonicalMapping : Self.document.decomposedStringWithCanonicalMapping
        #expect(Array(document.unicodeScalars) == Array(expected.unicodeScalars), "NFC: \(nfc)")
        #expect(try String(contentsOf: root.appendingPathComponent(Self.document), encoding: .utf8) == "xin chào thế giới\n")
        #expect(sha256(try Data(contentsOf: root.appendingPathComponent("sub/data.bin"))) == tree.dataSHA256)
        #expect(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("run.sh").path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("link-in").path) == "run.sh")
        // EasyDock's extractor drops a link to the outside; a file there would be /etc/hosts itself.
        let outside = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("link-out").path)
        #expect(outside == nil || outside?[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(!names.contains(".DS_Store"))
        #expect(!names.contains("._run.sh"))
    }

    /// Only the archive is new beside the items: no hidden folder left.
    private func expectNoLeftovers(_ folder: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!names.contains { $0.hasPrefix(".EasyDock-") }, "\(names)")
    }

    @Test(arguments: CompressFormat.allCases)
    func everyFormatComesBackAsItWent(_ format: CompressFormat) async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.folder) }
        let result = try await compress([tree.item], as: Self.project, format: format)
        let archive = try #require(result.parts.first)
        #expect(result.parts.count == 1)
        #expect(result.leftOut.isEmpty)
        // The archive's own name is NFC on disk, whatever the item's was. URL
        // itself parts the accents, so the folder's listing is what tells.
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: tree.folder.path).filter { $0.hasSuffix(format.fileExtension) }
        #expect(onDisk.map { Array($0.unicodeScalars) } == [Array("Dự án.\(format.fileExtension)".precomposedStringWithCanonicalMapping.unicodeScalars)])
        #expect(archive.deletingLastPathComponent().standardizedFileURL == tree.folder.standardizedFileURL)
        try expectNoLeftovers(tree.folder)
        let root = try #require(try await extract(archive))
        try expectTree(root, tree, nfc: format.canRename)
    }

    /// A 7z takes a password with accents; a ZIP's is ASCII, see `CompressFormat.accepts`.
    @Test(arguments: [(CompressFormat.zip, "Secret 1!"), (.sevenZip, "Bí mật 1")])
    func aPasswordProtectsTheArchive(_ format: CompressFormat, _ password: String) async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.folder) }
        let archive = try #require(try await compress([tree.item], format: format, password: password).parts.first)
        await #expect(throws: ArchiveExtractor.Failure.sevenZip(.wrongPassword)) { try await extract(archive, password: "wrong") }
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let root = try #require(try await extract(archive, password: password, asked: asked))
        try expectTree(root, tree, nfc: true)
        #expect(asked.withLock { $0 } == 1)
    }

    /// Renamed to NFC after it was made, a 7z still hides its names: it
    /// can't be opened at all without the password.
    @Test func a7zKeepsItsNamesHiddenAfterRenaming() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.folder) }
        let archive = try #require(try await compress([tree.item], format: .sevenZip, password: "pw").parts.first)
        let asked = OSAllocatedUnfairLock(initialState: 0)
        await #expect(throws: ArchiveExtractor.Failure.self) { try await extract(archive, password: nil, asked: asked) }
        #expect(asked.withLock { $0 } == 1)
    }

    /// With accented names EasyDock cuts the parts itself after renaming;
    /// without, 7-Zip does. Either way they open from the first part.
    @Test(arguments: [true, false])
    func partsOpenFromTheFirst(_ accented: Bool) async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.folder) }
        var item = tree.item
        if !accented {
            item = tree.folder.appendingPathComponent("Project")
            try FileManager.default.moveItem(at: tree.item, to: item)
            try FileManager.default.moveItem(at: item.appendingPathComponent(Self.document), to: item.appendingPathComponent("doc.txt"))
        }
        let result = try await compress([item], as: "Parts", format: .sevenZip, partSize: 60_000)
        #expect(result.parts.map(\.lastPathComponent) == ["Parts.7z.001", "Parts.7z.002", "Parts.7z.003", "Parts.7z.004"])
        try expectNoLeftovers(tree.folder)
        let root = try #require(try await extract(result.parts[2]))
        #expect(sha256(try Data(contentsOf: root.appendingPathComponent("sub/data.bin"))) == tree.dataSHA256)
    }

    @Test func aSplitThatFitsInOnePartIsJustTheArchive() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.folder) }
        let result = try await compress([tree.item], as: "One", format: .zip, partSize: 20_000_000)
        #expect(result.parts.map(\.lastPathComponent) == ["One.zip"])
    }

    @Test func aFileItCannotReadIsLeftOutAndNamed() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.folder) }
        let locked = tree.item.appendingPathComponent("locked.txt")
        try Data("secret".utf8).write(to: locked)
        chmod(locked.path, 0)
        defer { chmod(locked.path, 0o644) }
        for format in [CompressFormat.zip, .tarGz] {
            let result = try await compress([tree.item], as: "Locked", format: format)
            #expect(result.parts.count == 1)
            #expect(result.leftOut == ["\(Self.project)/locked.txt"], "\(format)")
        }
    }

    @Test func severalItemsGoInOneArchive() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.folder) }
        let note = tree.folder.appendingPathComponent("note.txt")
        try Data("note".utf8).write(to: note)
        let archive = try #require(try await compress([tree.item, note], format: .zip).parts.first)
        #expect(archive.lastPathComponent == "Archive.zip")
        let root = try #require(try await extract(archive))
        // Several items come out in a folder named after the archive.
        #expect(root.lastPathComponent == "Archive")
        #expect(try String(contentsOf: root.appendingPathComponent("note.txt"), encoding: .utf8) == "note")
        try expectTree(root.appendingPathComponent(Self.project.precomposedStringWithCanonicalMapping), tree, nfc: true)
    }

    @Test func itemsWithTheSameNameAreRefusedBeforeAnythingRuns() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.folder) }
        let other = tree.folder.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try Data("2".utf8).write(to: other.appendingPathComponent("run.sh"))
        await #expect(throws: ArchiveCompressor.Failure.sevenZip(.clashingNames(["run.sh"]))) {
            try await compress([tree.item.appendingPathComponent("run.sh"), other.appendingPathComponent("run.sh")], format: .zip,
                               into: tree.folder)
        }
        try expectNoLeftovers(tree.folder)
    }

    @Test func aNameAlreadyTakenIsNeverWrittenOver() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.folder) }
        for format in [CompressFormat.tarGz, .zip] {
            let first = try #require(try await compress([tree.item], as: "Logs", format: format).parts.first)
            let second = try #require(try await compress([tree.item], as: "Logs", format: format).parts.first)
            #expect(first.lastPathComponent == "Logs.\(format.fileExtension)")
            #expect(second.lastPathComponent == "Logs 2.\(format.fileExtension)")
        }
    }

    @Test func aFolderItCannotWriteToIsReported() async throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(at: tree.folder) }
        let locked = tree.folder.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        chmod(locked.path, 0o555)
        defer { chmod(locked.path, 0o755) }
        await #expect(throws: ArchiveCompressor.Failure.cannotWrite) {
            try await compress([tree.item], format: .zip, into: locked)
        }
    }

    @Test func stoppingLeavesNothingBehind() async throws {
        let tree = try makeTree(files: ["big.bin": 120_000_000])
        defer { try? FileManager.default.removeItem(at: tree.folder) }
        let started = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            let options = ArchiveCompressor.Options(format: .sevenZip, level: .smallest, password: "", partSize: 0)
            return try await ArchiveCompressor.compress([tree.item], fileName: "Big.7z", into: tree.folder, options: options) { _, _ in
                started.withLock { $0 = true }
            }
        }
        while !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(20)) }
        task.cancel()
        await #expect(throws: ArchiveCompressor.Failure.cancelled) { try await task.value }
        let names = try FileManager.default.contentsOfDirectory(atPath: tree.folder.path)
        #expect(names == [Self.project], "\(names)")
    }
}
