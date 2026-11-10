import Foundation

/// How EasyDock has `7zz` make an archive.
extension SevenZip {
    /// `7zz a`, run in the items' folder so the archive holds their names.
    /// Links are kept as links, never followed: one leading to `~/.ssh`
    /// would otherwise bring what it points to. A password is read from
    /// stdin when asked for, never put on the command line; a 7z's file
    /// names are hidden with it. `partSize` in bytes splits the archive.
    public static func compressArguments(format: CompressFormat, level: CompressLevel, threads: Int,
                                         encrypted: Bool, partSize: Int, archive: String, items: [String]) -> [String] {
        var arguments = ["a", "-t\(format.sevenZipType)"]
        if let mx = format.sevenZipLevel(level) { arguments.append("-mx\(mx)") }
        arguments += ["-mmt=\(threads)", "-snl", "-bso2", "-bse2", "-bsp1"] + exclusions
        if encrypted { arguments += passwordSwitches(format) }
        if partSize > 0 { arguments.append("-v\(partSize)b") }
        return arguments + ["--", archive] + items
    }

    /// The first half of a `.tar.gz` and its kin: the tar, to stdout.
    public static func tarStreamArguments(items: [String]) -> [String] {
        ["a", "-ttar", "-snl", "-so", "-an", "-bso0", "-bsp0", "-bse2"] + exclusions + ["--"] + items
    }

    /// The second half: the tar from stdin, compressed. It reports how many
    /// megabytes it has read, not a percentage: it can't know the total.
    public static func compressTarArguments(format: CompressFormat, level: CompressLevel, threads: Int,
                                            tarName: String, partSize: Int, archive: String) -> [String] {
        var arguments = ["a", "-t\(format.sevenZipType)"]
        if let mx = format.sevenZipLevel(level) { arguments.append("-mx\(mx)") }
        arguments += ["-mmt=\(threads)", "-si\(tarName)", "-bso2", "-bse2", "-bsp1"]
        if partSize > 0 { arguments.append("-v\(partSize)b") }
        return arguments + ["--", archive]
    }

    /// `7zz rn` with the pairs in `listFile`, one name per line; a name the
    /// archive doesn't hold is passed over. A 7z made with a password needs
    /// it again to read its hidden names, and to keep them hidden when it
    /// writes them back. A ZIP's names aren't encrypted.
    public static func renameArguments(format: CompressFormat, encrypted: Bool, archive: String, listFile: String) -> [String] {
        let password = encrypted && format == .sevenZip ? passwordSwitches(format) : []
        return ["rn", "-bso2", "-bse2", "-bsp0", "-scsUTF-8"] + password + [archive, "@" + listFile]
    }

    /// Threads for making `format`. LZMA2, in 7z and XZ, holds hundreds of
    /// megabytes per thread for little gain past four: those follow memory,
    /// as extracting does. ZIP's Deflate and BZIP2 take a few megabytes a
    /// thread and keep getting faster: ZIP took 5.9 s on 4 threads, 3.5 s
    /// on 11, in 240 MB. GZIP uses one whatever it is told.
    public static func compressThreads(format: CompressFormat, physicalMemory: UInt64, cores: Int) -> Int {
        switch format {
        case .sevenZip, .tarXz: threads(physicalMemory: physicalMemory, cores: cores)
        default: max(1, cores)
        }
    }

    /// AES-256 in both: ZIP's other choice, ZipCrypto, is easily broken.
    private static func passwordSwitches(_ format: CompressFormat) -> [String] {
        format == .sevenZip ? ["-p", "-mhe=on"] : ["-p", "-mem=AES256"]
    }

    private static var exclusions: [String] { CompressNaming.excluded.map { "-xr!" + $0 } }

    /// The megabytes the compressing half has read, from `-bsp1`:
    /// `49M + [Content]`.
    public static func streamedBytes(in text: String) -> Int64? {
        for line in text.split(whereSeparator: { $0 == "\u{8}" || $0 == "\r" || $0 == "\n" }).reversed() {
            if let match = line.wholeMatch(of: /\s*(\d+)M(?:\s+\+\s+.*)?\s*/), let megabytes = Int64(match.1) {
                return megabytes << 20
            }
        }
        return nil
    }

    /// The files 7-Zip couldn't read and left out, from its warnings:
    /// `path : errno=13 : Permission denied`.
    public static func unreadableFiles(in stderr: String) -> [String] {
        guard let start = stderr.range(of: "WARNINGS for files:") else { return [] }
        return stderr[start.upperBound...].split(whereSeparator: \.isNewline).compactMap { line in
            guard let range = line.range(of: " : errno=") else { return nil }
            return String(line[..<range.lowerBound])
        }
    }

    /// What went wrong making an archive; nil when it was made. Status 1 is
    /// a warning: files it couldn't read were left out, see
    /// `unreadableFiles`.
    public static func compressFailure(status: Int32, stderr: String) -> CompressFailure? {
        guard status != 0, status != 1 else { return nil }
        if stderr.contains("errno=28") || stderr.contains("No space left") { return .noSpace }
        if let match = stderr.firstMatch(of: /Duplicate filename on disk:\s*\n([^\r\n]+)/) {
            return .clashingNames([String(match.1)])
        }
        let message = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && $0 != "ERROR:" && $0 != "System ERROR:" && !$0.hasPrefix("errno=") }
        return .other(message ?? "")
    }
}

/// Why an archive could not be made.
public enum CompressFailure: Equatable, Sendable {
    case noSpace
    /// Items from different folders with the same name.
    case clashingNames([String])
    /// 7-Zip's own last line.
    case other(String)
}
