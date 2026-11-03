import AppKit
import EasyDockCore
import Foundation

/// Finds an app's bundle and what it left in `~/Library`, and moves the ones
/// the user keeps ticked to the Trash. Nothing is deleted outright.
actor AppUninstaller {
    struct Item: Identifiable, Sendable {
        var id: String { path }
        let path: String
        let bytes: Int64
        let isAppBundle: Bool

        var displayPath: String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
    }

    struct TrashResult: Sendable {
        var movedBytes: Int64
        var failedPaths: [String]
    }

    func items(forAppAt appURL: URL, bundleID: String, name: String, library: String = NSHomeDirectory() + "/Library") -> [Item] {
        let fileManager = FileManager.default
        var items = [Item(path: appURL.path, bytes: Self.size(of: appURL.path), isAppBundle: true)]
        for folder in AppLeftovers.folders {
            let folderPath = library + "/" + folder
            // Unreadable folders are skipped: a missing leftover is better
            // than a failed search.
            guard let entries = try? fileManager.contentsOfDirectory(atPath: folderPath) else { continue }
            for entry in entries where AppLeftovers.matches(entry, in: folder, bundleID: bundleID, appName: name) {
                let path = folderPath + "/" + entry
                items.append(Item(path: path, bytes: Self.size(of: path), isAppBundle: false))
            }
        }
        return items
    }

    /// The app bundle goes through the Finder, which asks for an
    /// administrator's password when the bundle belongs to root, as App
    /// Store apps do; the leftovers are the user's own and are moved directly.
    func moveToTrash(_ items: [Item]) async -> TrashResult {
        var result = TrashResult(movedBytes: 0, failedPaths: [])
        for item in items {
            let url = URL(fileURLWithPath: item.path)
            do {
                if item.isAppBundle {
                    try await NSWorkspace.shared.recycle([url])
                } else {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
                result.movedBytes += item.bytes
            } catch {
                result.failedPaths.append(item.displayPath)
            }
        }
        return result
    }

    private static func size(of path: String) -> Int64 {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey])
        guard values?.isDirectory == true else { return Int64(values?.totalFileAllocatedSize ?? 0) }
        return JunkCleanerService.directorySize(at: path)
    }
}
