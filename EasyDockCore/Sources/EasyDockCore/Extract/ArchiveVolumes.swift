import Foundation

/// An archive and the other parts it was split into, found from any one of
/// them: 7-Zip can only start at the first part.
///
/// The names it knows: `Name.part1.rar` (or `part01`, `part001`…),
/// `Name.rar` with `Name.r00`…, `Name.7z.001`… (any archive cut into equal
/// pieces) and `Name.zip` with `Name.z01`….
public struct ArchiveVolumes: Equatable, Sendable {
    /// The file name to open. It may be missing from the folder, when the
    /// user has every part but the first.
    public let first: String
    /// Every part found in the folder, `first` too when it is there, in order.
    public let parts: [String]
    /// Pieces of one file cut at a size (`.001`): 7-Zip joins them before
    /// it reads the archive inside.
    public let isSplit: Bool

    /// `name` is the file's name; `siblings` every name in its folder.
    public static func resolve(_ name: String, siblings: [String]) -> ArchiveVolumes {
        if let match = name.wholeMatch(of: /(?i)(.+)\.part(\d+)\.rar/) {
            let stem = String(match.1), width = match.2.count
            let parts = numbered(siblings, /(?i)(.+)\.part(\d+)\.rar/, stem: stem)
            let first = parts.first { number(of: $0, /(?i)(.+)\.part(\d+)\.rar/) == 1 }
            return ArchiveVolumes(first: first ?? "\(stem).part\(padded(1, width)).rar", parts: parts, isSplit: false)
        }
        if let match = name.wholeMatch(of: /(?i)(.+)\.(\d{3})/) {
            let stem = String(match.1)
            let parts = numbered(siblings, /(?i)(.+)\.(\d{3})/, stem: stem)
            let first = parts.first { number(of: $0, /(?i)(.+)\.(\d{3})/) == 1 }
            return ArchiveVolumes(first: first ?? "\(stem).001", parts: parts, isSplit: true)
        }
        // Name.rar comes first, then Name.r00, Name.r01…; likewise Name.zip
        // last, after Name.z01… but 7-Zip opens it first all the same.
        for (main, piece) in [("rar", /(?i)(.+)\.r(\d{2})/), ("zip", /(?i)(.+)\.z(\d{2})/)] {
            let stem: String
            if let match = name.wholeMatch(of: piece) {
                stem = String(match.1)
            } else if name.lowercased().hasSuffix(".\(main)") {
                stem = String(name.dropLast(main.count + 1))
            } else {
                continue
            }
            let pieces = numbered(siblings, piece, stem: stem)
            guard !pieces.isEmpty else { break }
            let first = siblings.first { $0.lowercased() == "\(stem).\(main)".lowercased() }
            return ArchiveVolumes(first: first ?? "\(stem).\(main)", parts: (first.map { [$0] } ?? []) + pieces, isSplit: false)
        }
        return ArchiveVolumes(first: name, parts: [name], isSplit: false)
    }

    /// The siblings with the same stem and a number where `pattern` has
    /// one, in the order of that number.
    private static func numbered(_ siblings: [String], _ pattern: Regex<(Substring, Substring, Substring)>, stem: String) -> [String] {
        siblings
            .compactMap { sibling -> (Int, String)? in
                guard let match = sibling.wholeMatch(of: pattern), match.1.lowercased() == stem.lowercased(),
                      let number = Int(match.2) else { return nil }
                return (number, sibling)
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
    }

    private static func number(of name: String, _ pattern: Regex<(Substring, Substring, Substring)>) -> Int? {
        name.wholeMatch(of: pattern).flatMap { Int($0.2) }
    }

    private static func padded(_ number: Int, _ width: Int) -> String {
        let digits = String(number)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
