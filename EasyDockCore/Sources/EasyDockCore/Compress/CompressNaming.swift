import Foundation

/// What an archive is called and what the names inside it look like.
public enum CompressNaming {
    /// One item: its name, without a file's extension, as Windows does.
    /// Several: `several`, the app's word for an archive. Always NFC.
    public static func defaultName(for itemPaths: [String], several: String, isFolder: (String) -> Bool) -> String {
        guard itemPaths.count == 1, let path = itemPaths.first else { return several.precomposedStringWithCanonicalMapping }
        let name = (path as NSString).lastPathComponent
        let stem = isFolder(path) ? name : (name as NSString).deletingPathExtension
        return (stem.isEmpty ? name : stem).precomposedStringWithCanonicalMapping
    }

    /// The archive's file name for what the user typed: `/` and `:` can't
    /// be in a name, the format's own extension isn't doubled, and an
    /// empty name falls back to `fallback`.
    public static func fileName(_ typed: String, format: CompressFormat, fallback: String) -> String {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .precomposedStringWithCanonicalMapping
        let suffix = "." + format.fileExtension
        if name.lowercased().hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        if name.isEmpty || name.allSatisfy({ $0 == "." }) { name = fallback }
        return name + suffix
    }

    /// Names that more than one item has, as Finder and Windows compare
    /// them: case and accents written either way count as the same. Items
    /// from different folders can share one, and an archive holds names.
    public static func clashingNames(_ itemPaths: [String]) -> [String] {
        var seen: [String: String] = [:]
        var clashes: [String] = []
        for path in itemPaths {
            let name = (path as NSString).lastPathComponent
            let key = name.precomposedStringWithCanonicalMapping.lowercased()
            if seen[key] == nil {
                seen[key] = name
            } else if !clashes.contains(name) {
                clashes.append(name)
            }
        }
        return clashes
    }

    /// The renames that make every name in an archive NFC, as Windows and
    /// the web write them; macOS often keeps accents as separate marks.
    /// Deepest first: renaming a folder renames everything under it, so
    /// its items must already be done. Compared scalar by scalar: Swift's
    /// `==` holds the two spellings equal.
    public static func nfcRenames(_ entries: [String]) -> [(from: String, to: String)] {
        entries
            .filter { !$0.unicodeScalars.elementsEqual($0.precomposedStringWithCanonicalMapping.unicodeScalars) }
            .sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
            .map { ($0, $0.precomposedStringWithCanonicalMapping) }
    }

    /// Finder's own files, never wanted in an archive: folder settings,
    /// the `._` copies of attributes on other disks, and a ZIP's
    /// `__MACOSX` folder. `Icon\r` holds a folder's custom icon.
    public static let excluded = [".DS_Store", "._*", "__MACOSX", "Icon\r"]
}
