import Foundation

/// The folders behind what Finder shows as the Trash, and deleting from
/// them for good.
public enum TrashFolders {
    /// The folders Finder merges into its Trash that EasyDock empties
    /// itself: `~/.Trash`, and `.Trashes/<uid>` at the top of every other
    /// volume, where items deleted from that volume go.
    public static func local(homeDirectory: String, volumes: [String], userID: UInt32) -> [String] {
        [homeDirectory + "/.Trash"] + volumes.map { ($0.hasSuffix("/") ? String($0.dropLast()) : $0) + "/.Trashes/\(userID)" }
    }

    /// iCloud Drive's own Trash, also merged into Finder's. Its items
    /// carry what iCloud needs for Put Back and for the deletion to reach
    /// iCloud, so Finder empties it rather than EasyDock. Where it sits has
    /// varied between macOS versions; both places are counted.
    public static func iCloud(homeDirectory: String) -> [String] {
        [homeDirectory + "/Library/Mobile Documents/.Trash",
         homeDirectory + "/Library/Mobile Documents/com~apple~CloudDocs/.Trash"]
    }

    /// Deletes `url` for good, even when it is locked or holds folders that
    /// can't be written to: items in the Trash often are, an app bundle or a
    /// package cache, and `removeItem` gives up on those with "you don't
    /// have permission". The owner's lock (`uchg`, `uappnd`) is lifted and
    /// the owner given write access to every folder inside, then it tries
    /// again. Links are never followed. What belongs to another user or is
    /// locked by the system stays, and the error says so.
    public static func removePermanently(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            makeRemovable(url.path)
            try FileManager.default.removeItem(at: url)
        }
    }

    /// The owner's flags that stop an item from being deleted.
    private static let ownerLocks = UInt32(UF_IMMUTABLE | UF_APPEND)

    private static func makeRemovable(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        if info.st_flags & ownerLocks != 0 {
            _ = lchflags(path, info.st_flags & ~ownerLocks)
        }
        // A link's own entry is removed by its folder; nothing to follow.
        guard info.st_mode & S_IFMT == S_IFDIR else { return }
        // Read and search to see inside, write to remove what's there.
        if info.st_mode & S_IRWXU != S_IRWXU {
            _ = chmod(path, (info.st_mode & 0o7777) | S_IRWXU)
        }
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
        for child in children {
            makeRemovable(path + "/" + child)
        }
    }
}
