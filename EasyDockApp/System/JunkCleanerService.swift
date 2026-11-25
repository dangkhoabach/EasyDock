import AppKit
import EasyDockCore
import Foundation

/// Measures and clears the `JunkTarget` locations.
///
/// Everything is moved to the Trash rather than deleted, with the single
/// exception of the Trash itself — so a wrong guess about what was safe to
/// remove stays recoverable. Deletion is never initiated here; the view asks
/// for confirmation first.
///
/// An `actor`, like `ProcessListService`: measuring walks tens of thousands
/// of files across a dozen directories, which must never run on the main
/// actor, and the concurrent `measure` calls need the results serialised.
actor JunkCleanerService {
    /// Directory size in bytes, keyed by target path.
    struct Measurement: Sendable {
        var path: String
        var bytes: Int64
    }

    /// Resolved on first access rather than in `init`.
    ///
    /// The filter below stats sixteen paths, and `init` runs wherever the
    /// owner is created — for the shared view model, that was the main actor
    /// during view setup. `lazy` inside an actor moves the work to the first
    /// `await` on this property, which every caller already does.
    lazy var targets: [JunkTarget] = {
        if let overrideTargets { return overrideTargets }
        // Filtered to what exists: listing "Gradle cache — 0 bytes" on a Mac
        // with no Gradle is noise, and the list is long enough already.
        let fileManager = FileManager.default
        return JunkTarget.defaults(homeDirectory: NSHomeDirectory(), userCacheDirectory: AppUninstaller.userCacheDirectory)
            .filter { fileManager.fileExists(atPath: $0.path) }
    }()

    /// Set only by tests, which point the cleaner at a temporary directory
    /// instead of the real caches under `~`.
    private let overrideTargets: [JunkTarget]?
    /// How a cleaned item goes: to the Trash, returning where it is now.
    /// Tests delete their own temporary files instead, so a test run leaves
    /// nothing in the user's Trash.
    private let discard: @Sendable (URL) throws -> URL?
    /// Where what went to the Trash is recorded, to be deleted for good later.
    private let ledger: TrashLedger?
    /// The apps open now, whose caches are left: they would only write
    /// them again, into the Trash.
    private let running: @Sendable () -> [AppFootprint]

    init(targets: [JunkTarget]? = nil,
         discard: @escaping @Sendable (URL) throws -> URL? = JunkCleanerService.moveToTrash,
         ledger: TrashLedger? = AppDatabase.shared.map { TrashLedger(dbQueue: $0.dbQueue) },
         running: @escaping @Sendable () -> [AppFootprint] = JunkCleanerService.runningApps) {
        self.overrideTargets = targets
        self.discard = discard
        self.ledger = ledger
        self.running = running
    }

    @Sendable nonisolated static func moveToTrash(_ url: URL) throws -> URL? {
        var trashURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashURL)
        return trashURL as URL?
    }

    /// Every running app with a bundle, background agents too: their
    /// identifier, their name and their file and executable names.
    @Sendable nonisolated static func runningApps() -> [AppFootprint] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, let url = app.bundleURL else { return nil }
            let fileName = url.deletingPathExtension().lastPathComponent
            return AppFootprint(bundleID: id, name: app.localizedName ?? fileName, path: url.path,
                                names: [fileName, app.executableURL?.lastPathComponent].compactMap { $0 })
        }
    }

    /// macOS lets only apps with Full Disk Access list `~/.Trash`; without
    /// it a walk sees nothing and would report the Trash as empty.
    nonisolated static func trashIsReadable(homeDirectory: String = NSHomeDirectory()) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: homeDirectory + "/.Trash")) != nil
    }

    /// The Trash folders EasyDock empties itself, those that exist: the
    /// home one and one on every other mounted volume.
    nonisolated static func localTrashFolders(homeDirectory: String = NSHomeDirectory()) -> [String] {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsRootFileSystemKey], options: [.skipHiddenVolumes]
        ) ?? []
        let others = volumes.filter { (try? $0.resourceValues(forKeys: [.volumeIsRootFileSystemKey]))?.volumeIsRootFileSystem != true }
        let folders = TrashFolders.local(homeDirectory: homeDirectory, volumes: others.map(\.path), userID: getuid())
        // The home one always: unreadable, it's still there.
        return [folders[0]] + folders.dropFirst().filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// iCloud Drive's Trash folders that exist; Finder empties them.
    nonisolated static func iCloudTrashFolders(homeDirectory: String = NSHomeDirectory()) -> [String] {
        TrashFolders.iCloud(homeDirectory: homeDirectory).filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Everything Finder shows in the Trash: the home Trash, every other
    /// volume's, and iCloud Drive's. Counting `~/.Trash` alone showed less
    /// than Finder, and emptying it left the rest.
    nonisolated static func trashSize(homeDirectory: String = NSHomeDirectory()) -> Int64 {
        (localTrashFolders(homeDirectory: homeDirectory) + iCloudTrashFolders(homeDirectory: homeDirectory))
            .reduce(0) { $0 + directorySize(at: $1) }
    }

    /// Measures every target concurrently. Yields each result as it lands so
    /// the UI can fill in progressively — a cold `~/Library/Caches` walk can
    /// take several seconds on its own, and waiting for the slowest target
    /// before showing any number at all felt broken.
    func measureAll() -> AsyncStream<Measurement> {
        let paths = targets.map(\.path)
        let modes = Dictionary(targets.map { ($0.path, $0.mode) }, uniquingKeysWith: { first, _ in first })
        let trash = targets.first { Self.maySkipTheTrash($0) }?.path
        return AsyncStream { continuation in
            Task.detached(priority: .utility) {
                await withTaskGroup(of: Measurement.self) { group in
                    for path in paths {
                        group.addTask {
                            Measurement(path: path, bytes: path == trash ? Self.trashSize() : Self.size(of: path, mode: modes[path] ?? .contents))
                        }
                    }
                    for await measurement in group {
                        continuation.yield(measurement)
                    }
                }
                continuation.finish()
            }
        }
    }

    /// What cleaning a target would move: the folder's contents, or for
    /// Application Support only its Chromium and Electron cache folders.
    nonisolated static func size(of path: String, mode: JunkTarget.Mode) -> Int64 {
        guard mode == .chromiumCaches else { return directorySize(at: path) }
        return chromiumCacheFolders(in: path).reduce(0) { $0 + directorySize(at: $1) }
    }

    nonisolated static func chromiumCacheFolders(in path: String) -> [String] {
        ChromiumCaches.folders(under: path) { folder in
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ) else { return nil }
            return urls.map { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return (url.lastPathComponent, values?.isDirectory == true && values?.isSymbolicLink != true)
            }
        }
    }

    /// A file's size, or a folder's contents'. A link counts as itself.
    nonisolated static func itemSize(at path: String) -> Int64 {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else { return Int64(values?.totalFileAllocatedSize ?? 0) }
        return directorySize(at: path)
    }

    /// Recursive allocated size of a directory. Symlinks are skipped so a
    /// link into another target isn't counted twice; unreadable subtrees are
    /// stepped over rather than aborting the walk.
    nonisolated static func directorySize(at path: String) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    enum CleanError: Error {
        /// The target path is a symlink pointing somewhere this service never
        /// measured — cleaning it would delete files the user never saw listed.
        case relocatedTarget
    }

    struct CleanResult: Sendable {
        var freedBytes: Int64
        /// Targets that couldn't be fully cleared, by name — almost always a
        /// permissions issue (a cache owned by a sandboxed app).
        var skipped: [String]
        /// Open apps whose caches were left, by name.
        var inUse: [String] = []
        /// What is still in the Trash after EasyDock emptied it: iCloud
        /// Drive's, which only Finder should empty, and items EasyDock
        /// couldn't delete. Zero when the Trash wasn't selected.
        var trashLeft: Int64 = 0
    }

    /// Clears the selected targets. Each item is measured as it goes, so the
    /// figure is what moved, not what the last measurement saw.
    ///
    /// The Trash goes last. Emptied first, it filled straight back up with
    /// the caches cleaned after it: the window said the space was freed
    /// while Finder showed gigabytes in the Trash. Last, it takes them too,
    /// so its figure is everything that left the disk.
    func clean(paths: Set<String>) -> CleanResult {
        var moved: Int64 = 0
        var skipped: [String] = []
        var inUse: Set<String> = []
        var entries: [TrashLedger.Entry] = []
        let running = running()

        // Emptying `~/Library/Caches` already removes the Homebrew and pip
        // caches nested inside it, so cleaning those again would only fail on
        // directories that are already gone.
        let selected = JunkTarget.withoutNested(targets.filter { paths.contains($0.path) })
        let trash = selected.first { Self.maySkipTheTrash($0) }

        for target in selected where target != trash {
            do {
                let outcome = try remove(target, running: running)
                moved += outcome.freedBytes
                inUse.formUnion(outcome.inUse)
                entries += outcome.entries
                if outcome.failures > 0 { skipped.append(target.name) }
            } catch {
                skipped.append(target.name)
            }
        }
        guard let trash else {
            try? ledger?.record(entries)
            return CleanResult(freedBytes: moved, skipped: skipped, inUse: inUse.sorted())
        }
        guard !Self.isRelocated(trash.path) else {
            try? ledger?.record(entries)
            return CleanResult(freedBytes: 0, skipped: skipped + [trash.name], inUse: inUse.sorted())
        }
        let emptied = Self.emptyTrash(local: Self.localTrashFolders(), iCloud: Self.iCloudTrashFolders())
        if emptied.left > 0 && emptied.iCloud < emptied.left { skipped.append(trash.name) }
        return CleanResult(freedBytes: emptied.freed, skipped: skipped, inUse: inUse.sorted(), trashLeft: emptied.left)
    }

    /// Deletes everything in the `local` Trash folders for good. `freed` is
    /// what left them; `left` what is still in the Trash, what is in the
    /// `iCloud` ones (`iCloud`) included.
    nonisolated static func emptyTrash(local: [String], iCloud: [String]) -> (freed: Int64, left: Int64, iCloud: Int64) {
        var freed: Int64 = 0
        var left: Int64 = 0
        for folder in local {
            let before = directorySize(at: folder)
            var failures = 0
            do {
                for child in try FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil
                ) {
                    do { try TrashFolders.removePermanently(child) } catch { failures += 1 }
                }
            } catch {
                failures += 1
            }
            let after = failures > 0 ? directorySize(at: folder) : 0
            freed += max(0, before - after)
            left += after
        }
        let iCloudBytes = iCloud.reduce(Int64(0)) { $0 + directorySize(at: $1) }
        return (freed, left + iCloudBytes, iCloudBytes)
    }

    private struct RemovalOutcome {
        var freedBytes: Int64 = 0
        /// Items that couldn't move — a locked file, or one owned by another
        /// app. The rest still went.
        var failures = 0
        /// Open apps whose items were left.
        var inUse: Set<String> = []
        var entries: [TrashLedger.Entry] = []
    }

    /// The only path allowed to bypass the Trash.
    ///
    /// `deletesPermanently` is set on exactly one target, but nothing stopped
    /// a future one from being copy-pasted with the flag still `true` — which
    /// would `removeItem` a real cache tree outright while the confirmation
    /// dialog still promised the Trash. Pinning the permission to the path
    /// rather than the flag makes that mistake impossible to make silently.
    nonisolated static func maySkipTheTrash(_ target: JunkTarget, homeDirectory: String = NSHomeDirectory()) -> Bool {
        target.deletesPermanently && target.path == homeDirectory + "/.Trash"
    }

    /// True when the target path is itself a symlink.
    ///
    /// People really do move `~/Library/Caches` or `~/.npm` onto another
    /// volume and link it back. `contentsOfDirectory` follows the link, so
    /// cleaning would empty whatever it points at — somewhere this service
    /// never audited and the user never picked. Children don't need this:
    /// `trashItem` on a symlink takes the link, not its destination.
    nonisolated static func isRelocated(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }

    /// Moves a target's items to the Trash; the Trash itself is emptied by
    /// `emptyTrash`, the only place that deletes for good.
    ///
    /// Two kinds of item are left without counting as a failure: a folder
    /// macOS keeps EasyDock from reading (Safari's, CloudKit's caches),
    /// which no move can take, and an open app's, which it would write
    /// again straight away — into the Trash, where it would keep growing.
    private func remove(_ target: JunkTarget, running: [AppFootprint]) throws -> RemovalOutcome {
        guard !Self.isRelocated(target.path) else { throw CleanError.relocatedTarget }
        let items: [URL]
        switch target.mode {
        case .item:
            items = [URL(fileURLWithPath: target.path)]
        case .contents:
            items = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: target.path), includingPropertiesForKeys: nil)
        case .chromiumCaches:
            items = Self.chromiumCacheFolders(in: target.path).map { URL(fileURLWithPath: $0) }
        }
        var outcome = RemovalOutcome()
        // Keeps going after a failure instead of stopping at the first
        // locked file: one undeletable cache entry shouldn't leave the
        // other 4 GB in place.
        for item in items {
            // An app's folder in Application Support is the first part
            // below it; elsewhere the item itself is named after its app.
            let owner = target.mode == .chromiumCaches
                ? String(item.path.dropFirst(target.path.count + 1).prefix { $0 != "/" })
                : item.lastPathComponent
            if let app = JunkInUse.owner(of: owner, running: running) {
                outcome.inUse.insert(app)
                continue
            }
            guard !Self.isUnreadableFolder(item) else { continue }
            let bytes = Self.itemSize(at: item.path)
            do {
                let trashURL = try discard(item)
                outcome.freedBytes += bytes
                if let trashURL, let identity = TrashLedger.identity(of: trashURL.path) {
                    outcome.entries.append(.init(trashPath: trashURL.path, bytes: bytes, movedAt: Date(), identity: identity))
                }
            } catch {
                outcome.failures += 1
            }
        }
        return outcome
    }

    /// A folder whose contents macOS won't list to EasyDock.
    nonisolated static func isUnreadableFolder(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue else { return false }
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path)) == nil
    }
}
