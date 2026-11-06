import Foundation
import Testing
@testable import EasyDockCore

@Suite struct ArchiveFormatTests {
    private func header(_ bytes: [UInt8], at offset: Int = 0) -> Data {
        Data(repeating: 0, count: offset) + Data(bytes) + Data(repeating: 0, count: 16)
    }

    @Test func eachFormatIsKnownByItsFirstBytes() {
        let cases: [([UInt8], Int, ArchiveFormat)] = [
            ([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00], 0, .rar),
            ([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00], 0, .rar5),
            ([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C], 0, .sevenZip),
            ([0x50, 0x4B, 0x03, 0x04], 0, .zip),
            ([0x50, 0x4B, 0x05, 0x06], 0, .zip),
            ([0x50, 0x4B, 0x07, 0x08], 0, .zip),
            ([0x1F, 0x8B, 0x08], 0, .gzip),
            (Array("BZh9".utf8), 0, .bzip2),
            ([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00], 0, .xz),
            ([0x28, 0xB5, 0x2F, 0xFD], 0, .zstd),
            (Array("ustar".utf8), 257, .tar),
            (Array("MSCF".utf8), 0, .cab),
            (Array("CD001".utf8), 0x8001, .iso),
            ([0x60, 0xEA], 0, .arj),
            (Array("xx-lh5-".utf8), 0, .lzh),
        ]
        for (bytes, offset, format) in cases {
            #expect(ArchiveFormat.detect(header(bytes, at: offset)) == format, "\(format)")
        }
    }

    /// The name says RAR, the bytes say otherwise: 7-Zip never gets to guess.
    @Test func anythingElseIsNotAnArchive() {
        #expect(ArchiveFormat.detect(Data("!<arch>\n".utf8)) == nil)
        #expect(ArchiveFormat.detect(Data([0x4D, 0x5A, 0x90, 0x00])) == nil)
        #expect(ArchiveFormat.detect(Data()) == nil)
        #expect(ArchiveFormat.detect(Data([0x52, 0x61, 0x72, 0x21])) == nil)
    }

    @Test func onlyCompressedStreamsHoldOneFile() {
        #expect(ArchiveFormat.allCases.filter(\.isStream) == [.gzip, .bzip2, .xz, .zstd])
    }
}

@Suite struct ArchiveVolumesTests {
    @Test func anyPartOfANumberedRarSetStartsAtTheFirst() {
        let folder = ["Film.part3.rar", "Film.part1.rar", "Film.part2.rar", "Other.part1.rar", "Film.txt"]
        let volumes = ArchiveVolumes.resolve("Film.part2.rar", siblings: folder)
        #expect(volumes.first == "Film.part1.rar")
        #expect(volumes.parts == ["Film.part1.rar", "Film.part2.rar", "Film.part3.rar"])
        #expect(!volumes.isSplit)
    }

    @Test func zeroPaddedPartsAndAnyCase() {
        let folder = ["SET.PART01.RAR", "SET.PART02.RAR", "set.part10.rar"]
        let volumes = ArchiveVolumes.resolve("set.part10.rar", siblings: folder)
        #expect(volumes.first == "SET.PART01.RAR")
        #expect(volumes.parts == ["SET.PART01.RAR", "SET.PART02.RAR", "set.part10.rar"])
    }

    /// The first part is gone: still named, so the user is told which one.
    @Test func aMissingFirstPartIsStillTheOneToOpen() {
        let volumes = ArchiveVolumes.resolve("Film.part02.rar", siblings: ["Film.part02.rar", "Film.part03.rar"])
        #expect(volumes.first == "Film.part01.rar")
        #expect(volumes.parts == ["Film.part02.rar", "Film.part03.rar"])
    }

    @Test func oldStyleRarPartsFollowTheRarFile() {
        let folder = ["Old.r01", "Old.rar", "Old.r00", "Older.r00"]
        for name in ["Old.rar", "Old.r00", "Old.r01"] {
            let volumes = ArchiveVolumes.resolve(name, siblings: folder)
            #expect(volumes.first == "Old.rar")
            #expect(volumes.parts == ["Old.rar", "Old.r00", "Old.r01"])
        }
    }

    @Test func piecesCutAtASizeAreJoined() {
        let folder = ["Backup.7z.002", "Backup.7z.001", "Backup.7z.003"]
        let volumes = ArchiveVolumes.resolve("Backup.7z.003", siblings: folder)
        #expect(volumes.first == "Backup.7z.001")
        #expect(volumes.parts == ["Backup.7z.001", "Backup.7z.002", "Backup.7z.003"])
        #expect(volumes.isSplit)
    }

    @Test func spannedZipOpensAtTheZipFile() {
        let folder = ["Docs.z02", "Docs.zip", "Docs.z01"]
        let volumes = ArchiveVolumes.resolve("Docs.z01", siblings: folder)
        #expect(volumes.first == "Docs.zip")
        #expect(volumes.parts == ["Docs.zip", "Docs.z01", "Docs.z02"])
    }

    @Test func aSingleArchiveIsItsOnlyPart() {
        for name in ["Photos.zip", "Photos.rar", "Photos.7z", "Photos.tar.gz"] {
            let volumes = ArchiveVolumes.resolve(name, siblings: [name, "Photos.txt"])
            #expect(volumes == ArchiveVolumes(first: name, parts: [name], isSplit: false))
        }
    }
}

@Suite struct ExtractNamingTests {
    @Test func theFolderIsTheArchiveWithoutItsExtensions() {
        let cases = [
            "Photos.zip": "Photos", "Photos.rar": "Photos", "Ảnh cưới.7z": "Ảnh cưới",
            "Film.part1.rar": "Film", "Film.PART01.RAR": "Film", "Backup.7z.001": "Backup",
            "src.tar.gz": "src", "src.tgz": "src", "src.tar.zst": "src", "logs.tar.xz": "logs",
            "v1.2.zip": "v1.2", "noextension": "noextension", ".hidden": ".hidden",
        ]
        for (archive, folder) in cases {
            #expect(ExtractNaming.folderName(forArchive: archive) == folder, "\(archive)")
        }
    }

    @Test func tarInsideAStreamIsRecognizedByName() {
        for name in ["a.tar.gz", "a.TGZ", "a.tar.bz2", "a.tbz2", "a.tbz", "a.tar.xz", "a.txz", "a.tar.zst", "a.tzst"] {
            #expect(ExtractNaming.holdsTar(name), "\(name)")
        }
        for name in ["a.gz", "a.zip", "a.tar", "tar.gz.txt"] {
            #expect(!ExtractNaming.holdsTar(name), "\(name)")
        }
    }

    @Test func archivesAreOfferedByName() {
        for name in ["a.zip", "A.RAR", "a.7z", "a.tar.gz", "a.tgz", "a.zst", "a.part2.rar", "a.r00", "a.z01", "a.7z.001", "a.iso", "a.lha"] {
            #expect(ExtractNaming.looksLikeArchive(name), "\(name)")
        }
        for name in ["a.txt", "a.dmg", "a.pkg", "a.app", "a.jpg", "rar", "a.r0"] {
            #expect(!ExtractNaming.looksLikeArchive(name), "\(name)")
        }
    }

    @Test func nothingIsWrittenOver() {
        let taken: Set<String> = ["/d/Photos", "/d/Photos 2", "/d/a.txt", "/d/v1.2"]
        #expect(ExtractNaming.uniquePath("/d/New", isDirectory: true, exists: taken.contains) == "/d/New")
        #expect(ExtractNaming.uniquePath("/d/Photos", isDirectory: true, exists: taken.contains) == "/d/Photos 3")
        #expect(ExtractNaming.uniquePath("/d/a.txt", isDirectory: false, exists: taken.contains) == "/d/a 2.txt")
        // A folder named like a version keeps its dot.
        #expect(ExtractNaming.uniquePath("/d/v1.2", isDirectory: true, exists: taken.contains) == "/d/v1.2 2")
    }
}

@Suite struct SevenZipTests {
    @Test func extractionUsesOneReaderAndStopsReadingSwitchesBeforeThePath() {
        let arguments = SevenZip.extractArguments(type: "Rar5", archive: "-tricky.rar", output: "/t/out", threads: 4)
        #expect(arguments.contains("-tRar5"))
        #expect(arguments.contains("-o/t/out"))
        #expect(arguments.contains("-mmt=4"))
        #expect(arguments.contains("-snld10"))
        #expect(arguments.suffix(2) == ["--", "-tricky.rar"])
        #expect(!arguments.contains { $0.hasPrefix("-p") })
    }

    @Test func aTarInAStreamTakesTwoProcesses() {
        #expect(SevenZip.streamArguments(type: "gzip", archive: "a.tar.gz") == ["x", "-so", "-bsp2", "-bse2", "-tgzip", "--", "a.tar.gz"])
        #expect(SevenZip.tarArguments(output: "/t").contains("-si"))
        #expect(SevenZip.tarArguments(output: "/t").contains("-ttar"))
    }

    @Test func threadsFollowMemory() {
        let gigabyte: UInt64 = 1 << 30
        #expect(SevenZip.threads(physicalMemory: 8 * gigabyte, cores: 8) == 2)
        #expect(SevenZip.threads(physicalMemory: 18 * gigabyte, cores: 11) == 4)
        #expect(SevenZip.threads(physicalMemory: 128 * gigabyte, cores: 16) == 16)
        #expect(SevenZip.threads(physicalMemory: 2 * gigabyte, cores: 4) == 1)
    }

    /// As 7zz writes it: each update overwrites the last with backspaces.
    @Test func progressIsTheLastPercentage() {
        let bs = "\u{8}"
        let text = "  0M Scan /tmp/\(bs)\(bs)\(bs)    \(bs)\(bs)  0%\(bs)\(bs)\(bs)\(bs) 63% 2 - Bộ ảnh/rand.bin\(bs)\(bs)\(bs)      \(bs)\(bs)"
        let progress = SevenZip.progress(in: text)
        #expect(progress?.percent == 63)
        #expect(progress?.item == "Bộ ảnh/rand.bin")
        #expect(SevenZip.progress(in: "  4% - c.tar")?.item == "c.tar")
        #expect(SevenZip.progress(in: "Scanning the drive")  == nil)
    }

    @Test func thePasswordPromptIsSeen() {
        #expect(SevenZip.asksForPassword("Extracting archive: /a.rar\n\nEnter password:"))
        #expect(!SevenZip.asksForPassword("Everything is Ok"))
    }

    /// 7zz's own words, from archives that fail in each way.
    @Test func failuresAreToldApart() {
        #expect(SevenZip.failure(in: "ERROR: Wrong password : Bộ ảnh/run.sh\n") == .wrongPassword)
        #expect(SevenZip.failure(in: "ERROR: /a/r5hp.rar : Cannot open encrypted archive. Wrong password?") == .wrongPassword)
        #expect(SevenZip.failure(in: "ERRORS:\nMissing volume : /d/Film.part2.rar\nERROR: Data Error : x") == .missingPart("Film.part2.rar"))
        #expect(SevenZip.failure(in: "ERROR: errno=28 : No space left on device : big.bin") == .noSpace)
        #expect(SevenZip.failure(in: "ERROR: /a.rar\nCannot open the file as [Rar5] archive") == .notAnArchive)
        #expect(SevenZip.failure(in: "ERROR: CRC Failed : a.txt") == .damaged)
        #expect(SevenZip.failure(in: "ERROR:\nSomething new\n\n") == .other("Something new"))
    }

    @Test func exitStatusDecidesWhetherAnythingFailed() {
        #expect(SevenZip.failure(status: 0, stderr: "") == nil)
        // 1 is a warning: the files are out.
        #expect(SevenZip.failure(status: 1, stderr: "WARNING: x") == nil)
        #expect(SevenZip.failure(status: 2, stderr: "ERROR: CRC Failed : a.bin") == .damaged)
        #expect(SevenZip.failure(status: 255, stderr: "Break signaled") == .other("Break signaled"))
    }

    /// As 7zz said it for a tar with one link to `../../outside`.
    @Test func aRefusedLinkIsNotAFailure() {
        let stderr = "ERROR: Dangerous link path was ignored : top/out : ../../outside\n"
        #expect(SevenZip.failure(status: 2, stderr: stderr) == nil)
        #expect(SevenZip.skippedLinks(in: stderr) == ["top/out"])
        #expect(SevenZip.skippedLinks(in: "ERROR: Dangerous link path was ignored : a : b : ../c\n") == ["a : b"])
        let viaLink = "ERROR: Dangerous link via another link was ignored : A/Headers : ../B/Headers\n"
        #expect(SevenZip.failure(status: 2, stderr: viaLink) == nil)
        #expect(SevenZip.skippedLinks(in: viaLink) == ["A/Headers"])
        // A real error beside it still counts.
        #expect(SevenZip.failure(status: 2, stderr: stderr + "ERROR: CRC Failed : a.bin\n") == .damaged)
    }

    @Test func theSandboxReadsTheArchiveAndWritesOneFolder() {
        let profile = SevenZip.sandboxProfile(helper: "/A.app/Contents/Helpers/7zz", readable: ["/d/a.part1.rar", "/d/a.part2.rar"], writable: "/d/.tmp")
        #expect(profile.hasPrefix("(version 1)\n(deny default)"))
        #expect(profile.contains("(allow process-exec (literal \"/A.app/Contents/Helpers/7zz\"))"))
        #expect(profile.contains("(literal \"/d/a.part1.rar\") (literal \"/d/a.part2.rar\")"))
        #expect(profile.contains("(allow file-read* file-write* (subpath \"/d/.tmp\"))"))
        #expect(!profile.contains("network"))
        #expect(!SevenZip.sandboxProfile(helper: "/h", readable: [], writable: nil).contains("file-write"))
    }

    /// A quote or backslash in a file name can't end the string early and
    /// add a rule of its own.
    @Test func pathsCannotBreakOutOfTheProfile() {
        let name = "/d/a\") (allow default) (\"\\.rar"
        let profile = SevenZip.sandboxProfile(helper: "/h", readable: [name], writable: nil)
        #expect(profile.contains("(literal \"/d/a\\\") (allow default) (\\\"\\\\.rar\")"))
        #expect(SevenZip.quoted("a\"b\\c") == "\"a\\\"b\\\\c\"")
    }
}

@Suite struct ZipNamesTests {
    /// What 7-Zip makes of these bytes: DOS Latin, character for character.
    private func asSevenZipReadsIt(_ bytes: [UInt8]) -> String {
        String(data: Data(bytes), encoding: ZipNames.cp437)!
    }

    /// Names as old Windows tools stored them, without the UTF-8 flag. The
    /// short ones are where a general detector goes wrong.
    private let legacy: [(name: String, bytes: [UInt8])] = [
        ("Ảnh.jpg", [0x41, 0xD2, 0x6E, 0x68, 0x2E, 0x6A, 0x70, 0x67]),
        ("Báo cáo.docx", [0x42, 0x61, 0xEC, 0x6F, 0x20, 0x63, 0x61, 0xEC, 0x6F, 0x2E, 0x64, 0x6F, 0x63, 0x78]),
        ("Tài liệu tiếng Việt.txt", [0x54, 0x61, 0xCC, 0x69, 0x20, 0x6C, 0x69, 0xEA, 0xF2, 0x75, 0x20, 0x74, 0x69, 0xEA, 0xEC, 0x6E,
                                     0x67, 0x20, 0x56, 0x69, 0xEA, 0xF2, 0x74, 0x2E, 0x74, 0x78, 0x74]),
        ("写真.jpg", [0x8E, 0xCA, 0x90, 0x5E, 0x2E, 0x6A, 0x70, 0x67]),
        ("日本語のファイル.txt", [0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA, 0x82, 0xCC, 0x83, 0x74, 0x83, 0x40, 0x83, 0x43, 0x83, 0x8B, 0x2E, 0x74, 0x78, 0x74]),
        ("中文文件.txt", [0xD6, 0xD0, 0xCE, 0xC4, 0xCE, 0xC4, 0xBC, 0xFE, 0x2E, 0x74, 0x78, 0x74]),
        ("한국어 문서.txt", [0xC7, 0xD1, 0xB1, 0xB9, 0xBE, 0xEE, 0x20, 0xB9, 0xAE, 0xBC, 0xAD, 0x2E, 0x74, 0x78, 0x74]),
        ("繁體中文.txt", [0xC1, 0x63, 0xC5, 0xE9, 0xA4, 0xA4, 0xA4, 0xE5, 0x2E, 0x74, 0x78, 0x74]),
        ("Документ.txt", [0xC4, 0xEE, 0xEA, 0xF3, 0xEC, 0xE5, 0xED, 0xF2, 0x2E, 0x74, 0x78, 0x74]),
        ("Документ.txt", [0x84, 0xAE, 0xAA, 0xE3, 0xAC, 0xA5, 0xAD, 0xE2, 0x2E, 0x74, 0x78, 0x74]),
        ("ภาษาไทย.txt", [0xC0, 0xD2, 0xC9, 0xD2, 0xE4, 0xB7, 0xC2, 0x2E, 0x74, 0x78, 0x74]),
        ("Žluťoučký kůň.txt", [0xA6, 0x6C, 0x75, 0x9C, 0x6F, 0x75, 0x9F, 0x6B, 0xEC, 0x20, 0x6B, 0x85, 0xE5, 0x2E, 0x74, 0x78, 0x74]),
    ]

    @Test func eachLegacyNameIsReadInItsOwnCodePage() throws {
        for (name, bytes) in legacy {
            let read = asSevenZipReadsIt(bytes)
            #expect(read != name)
            let encoding = try #require(ZipNames.encoding(of: [read], preferredLanguages: ["en-US"]), "\(name)")
            #expect(ZipNames.recovered(read, in: encoding) == name, "\(name) in \(String.localizedName(of: encoding))")
        }
    }

    @Test func theUsersLanguageDoesNotChangeAClearAnswer() throws {
        for (name, bytes) in legacy {
            let read = asSevenZipReadsIt(bytes)
            let encoding = try #require(ZipNames.encoding(of: [read], preferredLanguages: ["vi-VN", "en"]), "\(name)")
            #expect(ZipNames.recovered(read, in: encoding) == name, "\(name)")
        }
    }

    /// Western names really written in DOS Latin read right as they are.
    @Test func dosLatinNamesStayAsTheyAre() {
        let names = [[0x43, 0x61, 0x66, 0x82, 0x20, 0x72, 0x82, 0x73, 0x75, 0x6D, 0x82, 0x2E, 0x74, 0x78, 0x74],
                     [0x9A, 0x62, 0x65, 0x72, 0x20, 0x47, 0x72, 0x94, 0xE1, 0x65, 0x2E, 0x74, 0x78, 0x74]].map(asSevenZipReadsIt)
        #expect(names == ["Café résumé.txt", "Über Größe.txt"])
        #expect(ZipNames.encoding(of: names, preferredLanguages: ["en"]) == nil)
        #expect(ZipNames.encoding(of: names, preferredLanguages: ["vi"]) == nil)
    }

    /// Unix zip tools write UTF-8 without the flag.
    @Test func utf8WithoutTheFlagIsRecognized() {
        let read = asSevenZipReadsIt([0x54, 0xC3, 0xA0, 0x69, 0x20, 0x6C, 0x69, 0xE1, 0xBB, 0x87, 0x75, 0x2E, 0x74, 0x78, 0x74])
        #expect(ZipNames.encoding(of: [read], preferredLanguages: []) == .utf8)
        #expect(ZipNames.recovered(read, in: .utf8) == "Tài liệu.txt")
    }

    /// Names with the UTF-8 flag already read right and are left alone,
    /// even one that happens to fit CP437 and would read worse otherwise.
    @Test func namesThatReadRightAreLeftAlone() throws {
        #expect(ZipNames.encoding(of: ["Ảnh cưới.jpg", "日本.txt", "plain.txt"], preferredLanguages: ["vi"]) == nil)
        let legacyName = asSevenZipReadsIt([0x42, 0x61, 0xEC, 0x6F, 0x20, 0x63, 0x61, 0xEC, 0x6F, 0x2E, 0x64, 0x6F, 0x63, 0x78])
        let encoding = try #require(ZipNames.encoding(of: [legacyName], preferredLanguages: []))
        #expect(ZipNames.recovered(legacyName, in: encoding) == "Báo cáo.docx")
        #expect(ZipNames.recovered("Café.txt", in: encoding) == nil)
        #expect(ZipNames.recovered("a.txt", in: encoding) == nil)
    }
}
