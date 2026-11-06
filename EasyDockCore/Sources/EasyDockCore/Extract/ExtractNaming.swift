import Foundation

/// Where an archive's contents end up, next to it: a lone item inside goes
/// there as it is, several go into a folder named after the archive, and
/// nothing is ever written over.
public enum ExtractNaming {
    /// Names that hold a tar inside a compressed stream.
    private static let tarStreams = [".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tbz", ".tar.xz", ".txz", ".tar.zst", ".tzst"]

    /// A `.tar.gz` and its kin are unpacked in one pass, without a `.tar`
    /// left in between.
    public static func holdsTar(_ archiveName: String) -> Bool {
        let name = archiveName.lowercased()
        return tarStreams.contains { name.hasSuffix($0) }
    }

    /// Names EasyDock offers to extract, by name alone so a menu needn't
    /// read the disk: the formats it reads and the parts of split archives.
    /// What the file really holds is checked when it is extracted.
    public static func looksLikeArchive(_ fileName: String) -> Bool {
        let name = fileName.lowercased()
        let extensions = ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "zst", "cab", "iso", "arj", "lzh", "lha"]
        return holdsTar(name) || extensions.contains((name as NSString).pathExtension)
            || name.wholeMatch(of: /.+\.[rz]\d{2}/) != nil || name.wholeMatch(of: /.+\.\d{3}/) != nil
    }

    /// The folder for an archive with several items: its name without the
    /// archive's extensions and part numbers.
    public static func folderName(forArchive archiveName: String) -> String {
        var name = archiveName
        if let match = name.wholeMatch(of: /(?i)(.+)\.part\d+\.rar/) {
            return String(match.1)
        }
        if let match = name.wholeMatch(of: /(?i)(.+)\.\d{3}/) {
            name = String(match.1)
        }
        if let suffix = tarStreams.first(where: { name.lowercased().hasSuffix($0) }) {
            return String(name.dropLast(suffix.count))
        }
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// `path`, or the first of "Name 2", "Name 3"… that isn't taken. A
    /// file keeps its extension after the number; a folder's name is never
    /// split at a dot.
    public static func uniquePath(_ path: String, isDirectory: Bool, exists: (String) -> Bool) -> String {
        guard exists(path) else { return path }
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let ext = isDirectory ? "" : (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var number = 2
        while true {
            let candidate = (folder as NSString).appendingPathComponent(ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            if !exists(candidate) { return candidate }
            number += 1
        }
    }
}
