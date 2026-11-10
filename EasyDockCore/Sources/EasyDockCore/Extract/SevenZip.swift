import Foundation

/// How EasyDock runs 7-Zip's `7zz` and reads what it says back.
public enum SevenZip {
    /// What `7zz x` extracts into `output`. Messages and the password prompt
    /// go to stderr, progress to stdout. Finder's `__MACOSX` and `.DS_Store`
    /// are left out.
    public static func extractArguments(type: String, archive: String, output: String, threads: Int) -> [String] {
        ["x", "-y", "-bso2", "-bse2", "-bsp1", linkLevel, "-mmt=\(threads)", "-t\(type)", "-o\(output)",
         "-xr!__MACOSX", "-xr!.DS_Store", "--", archive]
    }

    /// How careful 7-Zip is with links. Its default drops every link that
    /// passes through another link or steps up with `..`, which is most of
    /// a framework's (`Headers → Versions/Current/Headers`): an app inside
    /// an archive came out broken. Level 10 keeps every link that stays
    /// inside the archive and still refuses one that leads outside.
    static let linkLevel = "-snld10"

    /// The first half of a `.tar.gz` and its kin: the stream unpacked to
    /// stdout, its progress on stderr.
    public static func streamArguments(type: String, archive: String) -> [String] {
        ["x", "-so", "-bsp2", "-bse2", "-t\(type)", "--", archive]
    }

    /// The second half: the tar read from stdin.
    public static func tarArguments(output: String) -> [String] {
        ["x", "-si", "-y", "-bso0", "-bsp0", "-bse2", linkLevel, "-ttar", "-o\(output)", "-xr!__MACOSX", "-xr!.DS_Store"]
    }

    /// One thread for every 4 GB of memory, as many as there are cores at
    /// most. 7-Zip otherwise takes every core, and each thread that unpacks
    /// a 7z holds about 145 MB: 1.4 GB on a 12-core Mac for little gain.
    public static func threads(physicalMemory: UInt64, cores: Int) -> Int {
        max(1, min(cores, Int(physicalMemory / (4 << 30))))
    }

    /// The last progress `7zz -bsp1` printed in `text`: the percentage, and
    /// the item it was on when it said, after `-` when extracting and `+`
    /// when adding. 7-Zip rewrites the line in place with backspaces.
    public static func progress(in text: String) -> (percent: Int, item: String?)? {
        for line in text.split(whereSeparator: { $0 == "\u{8}" || $0 == "\r" || $0 == "\n" }).reversed() {
            guard let match = line.wholeMatch(of: /\s*(\d{1,3})%(?:\s+\d+)?(?:\s+[-+]\s+(.+?))?\s*/),
                  let percent = Int(match.1) else { continue }
            return (min(percent, 100), match.2.map(String.init))
        }
        return nil
    }

    /// 7-Zip has stopped to ask for the password, on stderr without a newline.
    public static func asksForPassword(_ stderr: String) -> Bool {
        stderr.contains("Enter password")
    }

    /// What went wrong, from 7-Zip's exit status and what it printed on
    /// stderr; nil when nothing did. A link it refused to create because it
    /// leads outside is the safety net working, not a failure.
    public static func failure(status: Int32, stderr: String) -> ExtractFailure? {
        guard status != 0, status != 1 else { return nil }
        let errors = stderr.split(whereSeparator: \.isNewline).filter { !isSkippedLink($0) }.joined(separator: "\n")
        if status == 2, !skippedLinks(in: stderr).isEmpty, !errors.contains("ERROR: ") { return nil }
        return failure(in: errors)
    }

    /// "Dangerous link path was ignored : …" or "Dangerous link via another
    /// link was ignored : …".
    private static func isSkippedLink(_ line: Substring) -> Bool {
        line.contains("Dangerous link ") && line.contains(" was ignored : ")
    }

    /// The items 7-Zip left as empty files where it refused to create a link
    /// leading outside, as paths inside the archive.
    public static func skippedLinks(in stderr: String) -> [String] {
        stderr.split(whereSeparator: \.isNewline).compactMap { line in
            guard isSkippedLink(line), let range = line.range(of: " was ignored : ") else { return nil }
            let rest = line[range.upperBound...]
            // "path : target"; the target is the last " : " part.
            guard let separator = rest.range(of: " : ", options: .backwards) else { return nil }
            return String(rest[..<separator.lowerBound])
        }
    }

    static func failure(in stderr: String) -> ExtractFailure {
        if stderr.contains("Wrong password") { return .wrongPassword }
        if let match = stderr.firstMatch(of: /Missing volume : ([^\r\n]+)/) {
            return .missingPart((String(match.1) as NSString).lastPathComponent)
        }
        if stderr.contains("errno=28") || stderr.contains("No space left") { return .noSpace }
        if stderr.contains("Cannot open the file as") || stderr.contains("Can not open the file as")
            || stderr.contains("Unsupported archive type") { return .notAnArchive }
        if ["Data Error", "CRC Failed", "Headers Error", "Unexpected end of archive"].contains(where: stderr.contains) {
            return .damaged
        }
        let message = stderr.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty && $0 != "ERROR:" && $0 != "ERRORS:" }
        return .other(message ?? "")
    }

    /// The sandbox `7zz` runs in: it can read the archive's parts, or the
    /// items and everything inside them (`readableTrees`) it compresses,
    /// and the system; write only to `writable` and nothing else. No
    /// network, no other files, no other services. `/` itself must be
    /// readable or the program stops at launch.
    public static func sandboxProfile(helper: String, readable: [String], readableTrees: [String] = [], writable: String?) -> String {
        var lines = [
            "(version 1)",
            "(deny default)",
            "(allow process-exec (literal \(quoted(helper))))",
            "(allow file-read* (literal \"/\") (subpath \"/System\") (subpath \"/usr/lib\") (subpath \"/private/var/db/dyld\")"
                + " (literal \"/dev/null\") (literal \"/dev/urandom\") (literal \"/dev/random\"))",
            "(allow file-read* " + ([helper] + readable).map { "(literal \(quoted($0)))" }.joined(separator: " ") + ")",
            "(allow file-read-metadata)",
            "(allow sysctl-read)",
        ]
        if !readableTrees.isEmpty {
            lines.append("(allow file-read* " + readableTrees.map { "(subpath \(quoted($0)))" }.joined(separator: " ") + ")")
            // Adding a file asks for its local time. Without the notification
            // center, which says when the time zone changes, the system reads
            // the time zone again for every file: ZIP took 5.2 s instead of
            // 3.5 s on 11 000 files. Extracting doesn't ask.
            lines.append("(allow mach-lookup (global-name \"com.apple.system.notification_center\"))")
            lines.append("(allow ipc-posix-shm-read* (ipc-posix-name \"apple.shm.notification_center\"))")
        }
        if let writable {
            lines.append("(allow file-read* file-write* (subpath \(quoted(writable))))")
        }
        return lines.joined(separator: "\n")
    }

    /// A string in the sandbox profile's Scheme syntax.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Why an archive could not be extracted.
public enum ExtractFailure: Equatable, Sendable {
    case wrongPassword
    /// The file name of the part that isn't there.
    case missingPart(String)
    case noSpace
    case notAnArchive
    case damaged
    /// 7-Zip's own last line.
    case other(String)
}
