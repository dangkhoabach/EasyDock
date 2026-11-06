import CryptoKit
import Darwin
import EasyDockCore
import Foundation
import os
import Testing
@testable import EasyDock

/// Real archives through the real 7-Zip helper in its sandbox.
///
/// The fixtures (in Fixtures/) hold the same small tree: `Bộ ảnh/tiếng
/// việt.txt` (dated 2 January 2020), `Bộ ảnh/run.sh` (executable) and
/// `Bộ ảnh/thư mục con/data.bin` (20 000 random bytes). They were made with
/// RAR 7.23 (`rar a -ma5`, `-pSecret`, `-hpSecret`, `-v8k`), 7-Zip 26.05
/// (`-pSecret -mhe=on`, `-v8k`, `-tzip -mem=AES256 -pSecret`) and macOS's
/// `tar`, `macos.tar.gz` with a test attribute on the text file so that it
/// carries `._` files. `plain.tar.zst` is a zstd frame of raw blocks,
/// `links.tar` a tar with links inside and outside and `framework.tar` one
/// shaped like a framework (both made with Python's `tarfile`),
/// `damaged.rar` the plain one with one byte flipped in the middle.
@Suite(.serialized, .timeLimit(.minutes(1))) struct ArchiveExtractorTests {
    private final class Token {}
    private static let dataSHA256 = "774deab1066bd4d367cb45c68300df8cdf4b015baedb04c337145fc263e1971c"

    /// A new folder holding copies of the named fixtures.
    private func folder(with fixtures: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("extract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bundle = Bundle(for: Token.self)
        for name in fixtures {
            let source = try #require(bundle.url(forResource: name, withExtension: nil), "fixture \(name)")
            try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
        }
        return folder
    }

    private func extract(_ archive: URL, into destination: URL? = nil, password: String? = nil,
                         asked: OSAllocatedUnfairLock<Int> = .init(initialState: 0)) async throws(ArchiveExtractor.Failure) -> ArchiveExtractor.Result {
        try await ArchiveExtractor.extract(archive, into: destination, progress: { _, _ in }) {
            asked.withLock { $0 += 1 }
            return password
        }
    }

    /// The tree every fixture holds, as it was.
    private func expectTree(_ root: URL) throws {
        let text = try String(contentsOf: root.appendingPathComponent("tiếng việt.txt"), encoding: .utf8)
        #expect(text == "xin chào thế giới\n")
        let data = try Data(contentsOf: root.appendingPathComponent("thư mục con/data.bin"))
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == Self.dataSHA256)
        #expect(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("run.sh").path))
        let modified = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("tiếng việt.txt").path)[.modificationDate] as? Date
        #expect(modified.map { Calendar.current.component(.year, from: $0) } == 2020)
    }

    /// Nothing half-done left beside the archive.
    private func expectNoLeftovers(_ folder: URL) throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!names.contains { $0.hasPrefix(".EasyDock-") }, "\(names)")
    }

    @Test(arguments: ["plain.rar", "plain.tar.zst"])
    func aLoneFolderInsideGoesNextToTheArchive(_ name: String) async throws {
        let folder = try folder(with: [name])
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try await extract(folder.appendingPathComponent(name))
        #expect(result.item?.lastPathComponent == "Bộ ảnh")
        #expect(result.item?.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(!result.damaged)
        try expectTree(try #require(result.item))
        try expectNoLeftovers(folder)
    }

    @Test(arguments: ["password.rar", "headers.rar", "password.7z", "password.zip"])
    func thePasswordIsAskedOnceAndNeverGoesOnTheCommandLine(_ name: String) async throws {
        let folder = try folder(with: [name])
        defer { try? FileManager.default.removeItem(at: folder) }
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let result = try await extract(folder.appendingPathComponent(name), password: "Secret", asked: asked)
        try expectTree(try #require(result.item))
        #expect(asked.withLock { $0 } == 1)
    }

    @Test(arguments: ["password.rar", "headers.rar", "password.7z", "password.zip"])
    func aWrongPasswordFailsAndLeavesNothing(_ name: String) async throws {
        let folder = try folder(with: [name])
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(throws: ArchiveExtractor.Failure.sevenZip(.wrongPassword)) {
            try await extract(folder.appendingPathComponent(name), password: "wrong")
        }
        try expectNoLeftovers(folder)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [name])
    }

    @Test func noPasswordStopsIt() async throws {
        let folder = try folder(with: ["headers.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(throws: ArchiveExtractor.Failure.cancelled) {
            try await extract(folder.appendingPathComponent("headers.rar"), password: nil)
        }
        try expectNoLeftovers(folder)
    }

    /// Cancelled while it waits for the password: the helper stops and its
    /// folder goes.
    @Test func cancellingStopsTheHelper() async throws {
        let folder = try folder(with: ["password.7z"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let task = Task {
            try await ArchiveExtractor.extract(folder.appendingPathComponent("password.7z"), progress: { _, _ in }) {
                try? await Task.sleep(for: .seconds(30))
                return "Secret"
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        task.cancel()
        let started = Date()
        await #expect(throws: ArchiveExtractor.Failure.cancelled) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 5)
        try expectNoLeftovers(folder)
    }

    @Test(arguments: ["volumes.part1.rar", "volumes.part2.rar", "volumes.part3.rar", "split.7z.001", "split.7z.003"])
    func anyPartExtractsTheWholeSet(_ name: String) async throws {
        let parts = name.hasPrefix("volumes")
            ? ["volumes.part1.rar", "volumes.part2.rar", "volumes.part3.rar"]
            : ["split.7z.001", "split.7z.002", "split.7z.003"]
        let folder = try folder(with: parts)
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try await extract(folder.appendingPathComponent(name))
        try expectTree(try #require(result.item))
        #expect(result.parts.map(\.lastPathComponent) == parts)
    }

    @Test func aMissingPartIsNamed() async throws {
        let folder = try folder(with: ["volumes.part1.rar", "volumes.part3.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(throws: ArchiveExtractor.Failure.sevenZip(.missingPart("volumes.part2.rar"))) {
            try await extract(folder.appendingPathComponent("volumes.part3.rar"))
        }
        try expectNoLeftovers(folder)
        await #expect(throws: ArchiveExtractor.Failure.sevenZip(.missingPart("volumes.part01.rar"))) {
            let rest = try self.folder(with: ["volumes.part2.rar"])
            defer { try? FileManager.default.removeItem(at: rest) }
            try FileManager.default.moveItem(at: rest.appendingPathComponent("volumes.part2.rar"), to: rest.appendingPathComponent("volumes.part02.rar"))
            _ = try await extract(rest.appendingPathComponent("volumes.part02.rar"))
        }
    }

    /// Finder's `._` files go back into the attributes of their files.
    @Test func macOSMetadataIsMergedBack() async throws {
        let folder = try folder(with: ["macos.tar.gz"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try await extract(folder.appendingPathComponent("macos.tar.gz"))
        let root = try #require(result.item)
        #expect(root.lastPathComponent == "Bộ ảnh")
        try expectTree(root)
        // FileManager's listings hide `._name` beside `name`; asking for each by name doesn't.
        for appleDouble in ["._Bộ ảnh", "Bộ ảnh/._tiếng việt.txt", "Bộ ảnh/._run.sh", "Bộ ảnh/thư mục con/._data.bin"] {
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(appleDouble).path), "\(appleDouble)")
        }
        #expect(attribute("com.dangkhoabach.easydock.test", of: root.appendingPathComponent("tiếng việt.txt")) == Data("kept".utf8))
    }

    @Test func aCompressedFileComesOutAsItself() async throws {
        let folder = try folder(with: ["note.txt.gz"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try await extract(folder.appendingPathComponent("note.txt.gz"))
        let item = try #require(result.item)
        #expect(item.lastPathComponent == "note.txt")
        #expect(try String(contentsOf: item, encoding: .utf8) == "just one file\n")
    }

    /// Links inside the archive stay; any that leads outside, or anywhere
    /// by an absolute path, is gone without an empty file in its place.
    @Test func linksNeverLeadOutside() async throws {
        let folder = try folder(with: ["links.tar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try await extract(folder.appendingPathComponent("links.tar"))
        let root = try #require(result.item)
        let manager = FileManager.default
        #expect(try manager.destinationOfSymbolicLink(atPath: root.appendingPathComponent("same-folder").path) == "inner.txt")
        #expect(try manager.destinationOfSymbolicLink(atPath: root.appendingPathComponent("sub/up-inside").path) == "../inner.txt")
        #expect(try String(contentsOf: root.appendingPathComponent("sub/up-inside"), encoding: .utf8) == "inner\n")
        #expect(try manager.destinationOfSymbolicLink(atPath: root.appendingPathComponent("d/y").path) == ".")
        // `x → d/y/../../..` reads as inside, but `d/y` is `d` itself, so
        // the system resolves it one folder further out.
        for gone in ["up-outside", "absolute", "x"] {
            #expect((try? manager.attributesOfItem(atPath: root.appendingPathComponent(gone).path)) == nil, "\(gone)")
        }
        #expect(!manager.fileExists(atPath: folder.deletingLastPathComponent().appendingPathComponent("outside").path))
    }

    /// A framework's links go through other links (`Headers →
    /// Versions/Current/Headers`, `Current → A`); 7-Zip's default dropped
    /// them all, leaving an app inside an archive broken.
    @Test func aFrameworkKeepsEveryLink() async throws {
        let folder = try folder(with: ["framework.tar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = try #require(try await extract(folder.appendingPathComponent("framework.tar")).item)
        #expect(root.lastPathComponent == "Demo.framework")
        let manager = FileManager.default
        for (link, target) in [("Versions/Current", "A"), ("Demo", "Versions/Current/Demo"),
                               ("Headers", "Versions/Current/Headers"), ("Versions/A/Modules", "../Current/Headers")] {
            #expect(try manager.destinationOfSymbolicLink(atPath: root.appendingPathComponent(link).path) == target, "\(link)")
        }
        #expect(try String(contentsOf: root.appendingPathComponent("Headers/Demo.h"), encoding: .utf8) == "header\n")
        #expect(try String(contentsOf: root.appendingPathComponent("Versions/A/Modules/Demo.h"), encoding: .utf8) == "header\n")
        #expect(try String(contentsOf: root.appendingPathComponent("Demo"), encoding: .utf8) == "binary\n")
    }

    @Test func aDownloadedArchiveGivesItsQuarantineToEverythingInside() async throws {
        let folder = try folder(with: ["plain.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appendingPathComponent("plain.rar")
        let quarantine = Data("0083;6727a1b0;Safari;".utf8)
        try #require(quarantine.withUnsafeBytes { setxattr(archive.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) } == 0)
        let root = try #require(try await extract(archive).item)
        for path in ["", "tiếng việt.txt", "run.sh", "thư mục con", "thư mục con/data.bin"] {
            #expect(attribute("com.apple.quarantine", of: root.appendingPathComponent(path)) == quarantine, "\(path)")
        }
    }

    @Test func aSecondExtractionNeverWritesOverTheFirst() async throws {
        let folder = try folder(with: ["plain.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try await extract(folder.appendingPathComponent("plain.rar"))
        let second = try await extract(folder.appendingPathComponent("plain.rar"))
        #expect(first.item?.lastPathComponent == "Bộ ảnh")
        #expect(second.item?.lastPathComponent == "Bộ ảnh 2")
        try expectTree(try #require(second.item))
    }

    /// Several items at the top go into a folder named after the archive.
    @Test func severalItemsGoIntoAFolderNamedAfterTheArchive() async throws {
        let folder = try folder(with: [])
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["a.txt", "b.txt"] { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }
        let make = Process()
        make.executableURL = SevenZipProcess.helper
        make.arguments = ["a", "-bso0", "-bsp0", "-tzip", folder.appendingPathComponent("Hai tệp.zip").path,
                          folder.appendingPathComponent("a.txt").path, folder.appendingPathComponent("b.txt").path]
        try make.run()
        make.waitUntilExit()
        let result = try await extract(folder.appendingPathComponent("Hai tệp.zip"))
        let item = try #require(result.item)
        #expect(item.lastPathComponent == "Hai tệp")
        #expect(try FileManager.default.contentsOfDirectory(atPath: item.path).sorted() == ["a.txt", "b.txt"])
    }

    @Test func aDamagedArchiveStillGivesWhatItCan() async throws {
        let folder = try folder(with: ["damaged.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = try await extract(folder.appendingPathComponent("damaged.rar"))
        #expect(result.damaged)
        let root = try #require(result.item)
        #expect(try String(contentsOf: root.appendingPathComponent("tiếng việt.txt"), encoding: .utf8) == "xin chào thế giới\n")
    }

    @Test func aFileThatIsNoArchiveIsNotOpened() async throws {
        let folder = try folder(with: ["not-an-archive.rar"])
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect(throws: ArchiveExtractor.Failure.sevenZip(.notAnArchive)) {
            try await extract(folder.appendingPathComponent("not-an-archive.rar"))
        }
    }

    @Test func aFolderItCannotWriteToIsReported() async throws {
        let folder = try folder(with: ["plain.rar"])
        let locked = folder.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: folder)
        }
        await #expect(throws: ArchiveExtractor.Failure.cannotWrite) {
            try await extract(folder.appendingPathComponent("plain.rar"), into: locked)
        }
        let result = try await extract(folder.appendingPathComponent("plain.rar"), into: folder)
        try expectTree(try #require(result.item))
    }

    /// ZIPs whose names an older tool stored in its own code page, without
    /// the UTF-8 flag (made with Python's `zipfile` from those bytes).
    @Test(arguments: [
        ("windows-vietnamese.zip", ["Tài liệu tiếng Việt.txt", "Thư mục", "Thư mục/Ảnh đẹp.txt"]),
        ("windows-japanese.zip", ["日本語のファイル.txt", "フォルダ", "フォルダ/写真.jpg"]),
        ("windows-western.zip", ["Café résumé.txt", "Über Größe.txt"]),
        ("utf8-without-flag.zip", ["Tài liệu tiếng Việt.txt", "日本語.txt"]),
    ])
    func zipNamesComeOutInTheirOwnLanguage(_ name: String, _ expected: [String]) async throws {
        let folder = try folder(with: [name])
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = try #require(try await extract(folder.appendingPathComponent(name)).item)
        #expect(root.lastPathComponent == (name as NSString).deletingPathExtension)
        let found = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? [])
            .map(\.precomposedStringWithCanonicalMapping).sorted()
        #expect(found == expected.map(\.precomposedStringWithCanonicalMapping).sorted())
    }

    private func attribute(_ name: String, of url: URL) -> Data? {
        let size = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var value = Data(count: size)
        _ = value.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return value
    }
}
