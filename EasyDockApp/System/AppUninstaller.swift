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
        /// Found by the app's name, not its identifier; offered unticked.
        var matchedByName = false

        var displayPath: String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
    }

    struct TrashResult: Sendable {
        var movedBytes: Int64
        var failedPaths: [String]
    }

    func items(forAppAt appURL: URL, bundleID: String, name: String, library: String = NSHomeDirectory() + "/Library") -> [Item] {
        [Item(path: appURL.path, bytes: Self.size(of: appURL.path), isAppBundle: true)]
            + leftovers(bundleID: bundleID, name: name, library: library)
    }

    /// What the app left in `~/Library`, with or without the app itself.
    func leftovers(bundleID: String, name: String, library: String = NSHomeDirectory() + "/Library") -> [Item] {
        let fileManager = FileManager.default
        var items: [Item] = []
        for folder in AppLeftovers.folders {
            let folderPath = library + "/" + folder
            // Unreadable folders are skipped: a missing leftover is better
            // than a failed search.
            guard let entries = try? fileManager.contentsOfDirectory(atPath: folderPath) else { continue }
            for entry in entries {
                guard let match = AppLeftovers.match(entry, in: folder, bundleID: bundleID, appName: name) else { continue }
                let path = folderPath + "/" + entry
                items.append(Item(path: path, bytes: Self.size(of: path), isAppBundle: false, matchedByName: match == .name))
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

    /// Files named after apps no longer on the Mac, one group per bundle
    /// identifier, largest first, each with an installed app from the same
    /// vendor when there is one.
    func orphans(library: String = NSHomeDirectory() + "/Library") -> [OrphanGroup] {
        let vendors = AppRemovalWatcher.vendors(AppRemovalWatcher.index(AppRemovalWatcher.roots))
        var installed: [String: Bool] = [:]
        func isInstalled(_ id: String) -> Bool {
            if let known = installed[id.lowercased()] { return known }
            let paths = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: id).map(\.path)
            let found = !AppRemoval.liveCopies(paths, exists: FileManager.default.fileExists(atPath:)).isEmpty
            installed[id.lowercased()] = found
            return found
        }
        var groups: [String: OrphanGroup] = [:]
        for folder in OrphanLeftovers.folders {
            let folderPath = library + "/" + folder
            for entry in (try? FileManager.default.contentsOfDirectory(atPath: folderPath)) ?? [] {
                guard let id = OrphanLeftovers.bundleID(fromEntry: entry), OrphanLeftovers.isOrphan(id, isInstalled: isInstalled) else { continue }
                let path = folderPath + "/" + entry
                let key = id.lowercased()
                let vendor = id.split(separator: ".").prefix(2).joined(separator: ".").lowercased()
                groups[key, default: OrphanGroup(bundleID: id, vendorApp: vendors[vendor], items: [])]
                    .items.append(Item(path: path, bytes: Self.size(of: path), isAppBundle: false))
            }
        }
        return groups.values.sorted { $0.bytes > $1.bytes }
    }

    struct OrphanGroup: Identifiable, Sendable {
        var id: String { bundleID.lowercased() }
        let bundleID: String
        /// An installed app from the same vendor, which may still use these files.
        let vendorApp: String?
        var items: [Item]
        var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    }

    private static func size(of path: String) -> Int64 {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey])
        guard values?.isDirectory == true else { return Int64(values?.totalFileAllocatedSize ?? 0) }
        return JunkCleanerService.directorySize(at: path)
    }
}
