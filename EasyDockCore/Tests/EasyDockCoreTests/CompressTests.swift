import Foundation
import Testing
@testable import EasyDockCore

@Suite struct CompressFormatTests {
    @Test func eachFormatHasItsExtensionAndWriter() {
        let expected: [(CompressFormat, String, String)] = [
            (.zip, "zip", "zip"), (.sevenZip, "7z", "7z"), (.tarGz, "tar.gz", "gzip"),
            (.tarXz, "tar.xz", "xz"), (.tarBz2, "tar.bz2", "bzip2"), (.tar, "tar", "tar"),
        ]
        for (format, fileExtension, type) in expected {
            #expect(format.fileExtension == fileExtension)
            #expect(format.sevenZipType == type)
        }
        #expect(CompressFormat.allCases.filter(\.takesPassword) == [.zip, .sevenZip])
        #expect(CompressFormat.allCases.filter(\.isCompressedTar) == [.tarGz, .tarXz, .tarBz2])
        #expect(CompressFormat.allCases.filter(\.canRename) == [.zip, .sevenZip])
    }

    /// The levels measured on real data: see `sevenZipLevel`.
    @Test func levelsFollowWhatWasMeasured() {
        func levels(_ format: CompressFormat) -> [Int?] { CompressLevel.allCases.map { format.sevenZipLevel($0) } }
        #expect(levels(.zip) == [1, 5, 9])
        #expect(levels(.sevenZip) == [1, 5, 7])
        #expect(levels(.tarXz) == [1, 5, 7])
        #expect(levels(.tarGz) == [1, 1, 9])
        #expect(levels(.tarBz2) == [1, 5, 9])
        #expect(levels(.tar) == [nil, nil, nil])
    }

    @Test func aZipPasswordIsASCII() {
        #expect(CompressFormat.zip.accepts(password: "Secret-1 !@#"))
        #expect(!CompressFormat.zip.accepts(password: "Bí mật"))
        #expect(CompressFormat.sevenZip.accepts(password: "Bí mật"))
    }

    @Test func partsAreNumberedAs7ZipDoes() {
        #expect(CompressSplit.partName("Ảnh.7z", index: 1) == "Ảnh.7z.001")
        #expect(CompressSplit.partName("a.zip", index: 12) == "a.zip.012")
        #expect(CompressSplit.presets.first == 0)
        #expect(CompressSplit.presets.last == 4_294_967_295)
    }
}

@Suite struct CompressNamingTests {
    @Test func oneItemNamesTheArchive() {
        let folder = { (path: String) in !path.contains(".") || path.hasSuffix(".app") }
        #expect(CompressNaming.defaultName(for: ["/a/Báo cáo.pdf"], several: "Archive", isFolder: folder) == "Báo cáo")
        #expect(CompressNaming.defaultName(for: ["/a/Dự án"], several: "Archive", isFolder: folder) == "Dự án")
        // A folder's dot is part of its name; so is an app's extension.
        #expect(CompressNaming.defaultName(for: ["/a/v1.2"], several: "Archive", isFolder: { _ in true }) == "v1.2")
        #expect(CompressNaming.defaultName(for: ["/a/EasyDock.app"], several: "Archive", isFolder: folder) == "EasyDock.app")
        #expect(CompressNaming.defaultName(for: ["/a/.env"], several: "Archive", isFolder: { _ in false }) == ".env")
        #expect(CompressNaming.defaultName(for: ["/a/x.txt", "/a/y.txt"], several: "Tệp nén", isFolder: folder) == "Tệp nén")
    }

    /// macOS often keeps the accents of a name as marks of their own.
    @Test func theDefaultNameIsNFC() {
        let decomposed = "Ba\u{301}o ca\u{301}o"
        let name = CompressNaming.defaultName(for: ["/a/\(decomposed)"], several: "", isFolder: { _ in true })
        #expect(name.unicodeScalars.elementsEqual("Báo cáo".precomposedStringWithCanonicalMapping.unicodeScalars))
    }

    @Test func theTypedNameGetsTheFormatsExtensionOnce() {
        #expect(CompressNaming.fileName("Ảnh", format: .zip, fallback: "Archive") == "Ảnh.zip")
        #expect(CompressNaming.fileName("Ảnh.ZIP", format: .zip, fallback: "Archive") == "Ảnh.zip")
        #expect(CompressNaming.fileName("logs.tar.gz", format: .tarGz, fallback: "Archive") == "logs.tar.gz")
        #expect(CompressNaming.fileName("logs.tar", format: .tarGz, fallback: "Archive") == "logs.tar.tar.gz")
        #expect(CompressNaming.fileName("  a/b:c  ", format: .sevenZip, fallback: "Archive") == "a-b-c.7z")
        #expect(CompressNaming.fileName("", format: .sevenZip, fallback: "Archive") == "Archive.7z")
        #expect(CompressNaming.fileName("..", format: .tar, fallback: "Archive") == "Archive.tar")
        #expect(CompressNaming.fileName(".zip", format: .zip, fallback: "Archive") == "Archive.zip")
    }

    @Test func aTakenNameGetsANumberBeforeTheWholeExtension() {
        let taken: Set = ["logs.tar.gz", "logs 2.tar.gz", "a.zip"]
        #expect(CompressNaming.uniqueFileName("logs.tar.gz", format: .tarGz) { taken.contains($0) } == "logs 3.tar.gz")
        #expect(CompressNaming.uniqueFileName("a.zip", format: .zip) { taken.contains($0) } == "a 2.zip")
        #expect(CompressNaming.uniqueFileName("b.7z", format: .sevenZip) { taken.contains($0) } == "b.7z")
    }

    /// 7-Zip names a file it left out by the path it was given.
    @Test func aFileLeftOutIsNamedAsInsideTheArchive() {
        let items = ["/d/Dự án", "/e/note.txt"]
        #expect(CompressNaming.entry(for: "/d/Dự án/sub/a.txt", items: items) == "Dự án/sub/a.txt")
        #expect(CompressNaming.entry(for: "/e/note.txt", items: items) == "note.txt")
        #expect(CompressNaming.entry(for: "/d/Dự án 2/a.txt", items: items) == "/d/Dự án 2/a.txt")
    }

    @Test func itemsWithTheSameNameAreFound() {
        #expect(CompressNaming.clashingNames(["/a/x.txt", "/b/y.txt"]).isEmpty)
        #expect(CompressNaming.clashingNames(["/a/x.txt", "/b/x.txt", "/c/x.txt"]) == ["x.txt"])
        // As Finder and Windows see them.
        #expect(CompressNaming.clashingNames(["/a/Báo.txt", "/b/BA\u{301}O.txt"]) == ["BA\u{301}O.txt"])
    }

    @Test func renamesToNFCGoDeepestFirst() {
        let folder = "Thu\u{31B} mu\u{323}c"
        let file = folder + "/Ta\u{300}i lie\u{302}\u{323}u.txt"
        let renames = CompressNaming.nfcRenames([folder, file, "plain.txt", "Ảnh.jpg"])
        #expect(renames.map(\.from) == [file, folder])
        // Swift's == holds both spellings equal: compare the scalars.
        #expect(renames.map { Array($0.to.unicodeScalars) } == ["Thư mục/Tài liệu.txt", "Thư mục"].map { Array($0.precomposedStringWithCanonicalMapping.unicodeScalars) })
        #expect(renames.allSatisfy { !Array($0.from.unicodeScalars).elementsEqual($0.to.unicodeScalars) })
        #expect(CompressNaming.nfcRenames(["a", "Ảnh"]).isEmpty)
    }
}

@Suite struct SevenZipCompressTests {
    @Test func aZipKeepsLinksAndLeavesFindersFilesOut() {
        let arguments = SevenZip.compressArguments(format: .zip, level: .balanced, threads: 4, encrypted: false, partSize: 0,
                                                   archive: "/d/.tmp/a.zip", items: ["Dự án", "b.txt"])
        #expect(arguments == ["a", "-tzip", "-mx5", "-mmt=4", "-snl", "-bso2", "-bse2", "-bsp1",
                              "-xr!.DS_Store", "-xr!._*", "-xr!__MACOSX", "-xr!Icon\r", "--", "/d/.tmp/a.zip", "Dự án", "b.txt"])
    }

    /// The password itself is never an argument: 7-Zip asks for it.
    @Test func aPasswordIsAskedForAndIsAES() {
        let zip = SevenZip.compressArguments(format: .zip, level: .fast, threads: 1, encrypted: true, partSize: 0, archive: "a.zip", items: ["x"])
        #expect(zip.contains("-p") && zip.contains("-mem=AES256") && !zip.contains("-mhe=on"))
        let sevenZip = SevenZip.compressArguments(format: .sevenZip, level: .smallest, threads: 2, encrypted: true, partSize: 0, archive: "a.7z", items: ["x"])
        #expect(sevenZip.contains("-p") && sevenZip.contains("-mhe=on") && sevenZip.contains("-mx7"))
        let plain = SevenZip.compressArguments(format: .sevenZip, level: .fast, threads: 2, encrypted: false, partSize: 0, archive: "a.7z", items: ["x"])
        #expect(!plain.contains { $0.hasPrefix("-p") || $0.hasPrefix("-mhe") || $0.hasPrefix("-mem") })
    }

    @Test func partsAndAPlainTar() {
        let split = SevenZip.compressArguments(format: .sevenZip, level: .balanced, threads: 2, encrypted: false, partSize: 20_000_000, archive: "a.7z", items: ["x"])
        #expect(split.contains("-v20000000b"))
        let tar = SevenZip.compressArguments(format: .tar, level: .smallest, threads: 2, encrypted: false, partSize: 0, archive: "a.tar", items: ["x"])
        #expect(!tar.contains { $0.hasPrefix("-mx") })
        #expect(tar.contains("-ttar"))
    }

    @Test func onlyLZMA2IsHeldBackByMemory() {
        let gigabyte: UInt64 = 1 << 30
        #expect(SevenZip.compressThreads(format: .sevenZip, physicalMemory: 18 * gigabyte, cores: 11) == 4)
        #expect(SevenZip.compressThreads(format: .tarXz, physicalMemory: 8 * gigabyte, cores: 8) == 2)
        #expect(SevenZip.compressThreads(format: .zip, physicalMemory: 8 * gigabyte, cores: 8) == 8)
        #expect(SevenZip.compressThreads(format: .tarBz2, physicalMemory: 18 * gigabyte, cores: 11) == 11)
    }

    @Test func aCompressedTarTakesTwoProcesses() {
        let first = SevenZip.tarStreamArguments(items: ["Dự án"])
        #expect(first.prefix(5) == ["a", "-ttar", "-snl", "-so", "-an"])
        #expect(first.contains("-xr!.DS_Store"))
        #expect(first.suffix(2) == ["--", "Dự án"])
        let second = SevenZip.compressTarArguments(format: .tarXz, level: .balanced, threads: 4, tarName: "Dự án.tar", partSize: 0, archive: "/t/Dự án.tar.xz")
        #expect(second == ["a", "-txz", "-mx5", "-mmt=4", "-siDự án.tar", "-bso2", "-bse2", "-bsp1", "--", "/t/Dự án.tar.xz"])
    }

    @Test func renamingNeedsThePasswordOnlyForA7z() {
        let sevenZip = SevenZip.renameArguments(format: .sevenZip, encrypted: true, archive: "/t/a.7z", listFile: "/t/names")
        #expect(sevenZip == ["rn", "-bso2", "-bse2", "-bsp0", "-scsUTF-8", "-p", "-mhe=on", "/t/a.7z", "@/t/names"])
        let zip = SevenZip.renameArguments(format: .zip, encrypted: true, archive: "/t/a.zip", listFile: "/t/names")
        #expect(!zip.contains("-p"))
    }

    /// As 7zz writes it when adding: `+`, and long names cut with ` . `.
    @Test func progressWhenAdding() {
        let bs = "\u{8}"
        let text = "  0%\(bs)\(bs)\(bs)\(bs)  8% 735 + Frameworks/AppKit.framework/Versions/C/Headers/NSSlider.h\(bs)\(bs)"
        #expect(SevenZip.progress(in: text)?.percent == 8)
        #expect(SevenZip.progress(in: text)?.item == "Frameworks/AppKit.framework/Versions/C/Headers/NSSlider.h")
        #expect(SevenZip.progress(in: " 99% 11130 + bin/xml2man")?.item == "bin/xml2man")
    }

    @Test func theCompressingHalfCountsMegabytes() {
        let bs = "\u{8}"
        #expect(SevenZip.streamedBytes(in: "  0M + [Content]\(bs)\(bs)\(bs) 49M + [Content]\(bs)\(bs)") == 49 << 20)
        #expect(SevenZip.streamedBytes(in: "Scanning") == nil)
        #expect(SevenZip.streamedBytes(in: " 12%") == nil)
    }

    /// As 7zz said it for a folder with one file it couldn't read.
    @Test func filesLeftOutAreNamed() {
        let stderr = """

        WARNING: errno=13 : Permission denied
        ro/secret.txt


        WARNINGS for files:

        ro/secret.txt : errno=13 : Permission denied
        Dự án/khoá : errno=1 : Operation not permitted
        ----------------
        WARNING: Cannot open 2 files
        """
        #expect(SevenZip.unreadableFiles(in: stderr) == ["ro/secret.txt", "Dự án/khoá"])
        #expect(SevenZip.unreadableFiles(in: "Everything is Ok") == [])
        #expect(SevenZip.compressFailure(status: 1, stderr: stderr) == nil)
    }

    @Test func failuresWhenCompressing() {
        #expect(SevenZip.compressFailure(status: 0, stderr: "") == nil)
        #expect(SevenZip.compressFailure(status: 2, stderr: "ERROR:\nDuplicate filename on disk:\nsame.txt\nsame.txt\n") == .clashingNames(["same.txt"]))
        #expect(SevenZip.compressFailure(status: 2, stderr: "ERROR: errno=28 : No space left on device") == .noSpace)
        let writeDenied = "\nError:\ncannot open file\n/d/z.zip\nerrno=1 : Operation not permitted\n\n\nSystem ERROR:\nerrno=1 : Operation not permitted\n"
        #expect(SevenZip.compressFailure(status: 2, stderr: writeDenied) == .other("/d/z.zip"))
        #expect(SevenZip.compressFailure(status: 255, stderr: "Break signaled") == .other("Break signaled"))
    }

    @Test func theSandboxReadsWholeItemsWhenCompressing() {
        let profile = SevenZip.sandboxProfile(helper: "/h", readable: [], readableTrees: ["/d/Dự án", "/d/b.txt"], writable: "/d/.tmp")
        #expect(profile.contains("(allow file-read* (subpath \"/d/Dự án\") (subpath \"/d/b.txt\"))"))
        #expect(profile.contains("(allow mach-lookup (global-name \"com.apple.system.notification_center\"))"))
        // Extracting, which reads what may be hostile, gets neither.
        let extracting = SevenZip.sandboxProfile(helper: "/h", readable: ["/a"], writable: nil)
        #expect(!extracting.contains("subpath \"/a\""))
        #expect(!extracting.contains("mach-lookup") && !extracting.contains("ipc-posix"))
    }
}
