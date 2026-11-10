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

    /// `fileName`, or the first of "Name 2.tar.gz", "Name 3.tar.gz"… that
    /// isn't `taken`. The format's extension stays whole after the number.
    public static func uniqueFileName(_ fileName: String, format: CompressFormat, taken: (String) -> Bool) -> String {
        guard taken(fileName) else { return fileName }
        let suffix = "." + format.fileExtension
        let stem = fileName.lowercased().hasSuffix(suffix) ? String(fileName.dropLast(suffix.count)) : fileName
        var number = 2
        while taken("\(stem) \(number)\(suffix)") { number += 1 }
        return "\(stem) \(number)\(suffix)"
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

    /// Where `path`, as 7-Zip names a file it couldn't read, is inside the
    /// archive: under the name of the item that holds it.
    public static func entry(for path: String, items: [String]) -> String {
        guard let item = items.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return path }
        return (item as NSString).lastPathComponent + path.dropFirst(item.count)
    }

    /// Finder's own files, never wanted in an archive: folder settings,
    /// the `._` copies of attributes on other disks, and a ZIP's
    /// `__MACOSX` folder. `Icon\r` holds a folder's custom icon.
    public static let excluded = [".DS_Store", "._*", "__MACOSX", "Icon\r"]
}
