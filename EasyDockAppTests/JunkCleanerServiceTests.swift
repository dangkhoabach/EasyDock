import Foundation
import GRDB
import Testing
@testable import EasyDockCore
@testable import EasyDock

@Suite struct JunkCleanerServiceTests {
    private let home = "/Users/example"

    private func target(
        name: String = "Cache", path: String, deletesPermanently: Bool
    ) -> JunkTarget {
        JunkTarget(
            name: name, detail: "", path: path,
            mode: .contents, deletesPermanently: deletesPermanently
        )
    }

    /// The Trash is the one place the app deletes outright, because it cannot
    /// be moved into itself.
    @Test func theTrashMaySkipTheTrash() {
        let trash = target(name: "Trash", path: home + "/.Trash", deletesPermanently: true)
        #expect(JunkCleanerService.maySkipTheTrash(trash, homeDirectory: home))
    }

    /// The regression this guards: permission to delete outright is pinned to
    /// the path, not to the flag. A future target copy-pasted with
    /// `deletesPermanently: true` still only reaches the Trash, so the
    /// mistake costs nothing instead of destroying a cache tree for good.
    @Test func aNonTrashTargetNeverSkipsTheTrashEvenWhenItClaimsTo() {
        let mislabelled = target(path: home + "/Library/Caches", deletesPermanently: true)
        #expect(!JunkCleanerService.maySkipTheTrash(mislabelled, homeDirectory: home))
    }

    @Test func anOrdinaryTargetDoesNotSkipTheTrash() {
        let ordinary = target(path: home + "/Library/Caches", deletesPermanently: false)
        #expect(!JunkCleanerService.maySkipTheTrash(ordinary, homeDirectory: home))
    }

    /// A relocated cache — moved to another volume and symlinked back — must
    /// be recognised, because `contentsOfDirectory` follows the link and would
    /// empty the destination instead of the folder the user selected.
    @Test func detectsASymlinkedTargetPath() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("JunkCleanerServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let real = root.appendingPathComponent("real-cache")
        let link = root.appendingPathComponent("linked-cache")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(JunkCleanerService.isRelocated(link.path))
        #expect(!JunkCleanerService.isRelocated(real.path))
    }

    /// Emptying the Trash takes what `removeItem` alone refused — a locked
    /// file, an app bundle's read-only folders — from every Trash folder,
    /// and counts iCloud Drive's as still there, for Finder to empty.
    /// Run on folders of its own, never the real Trash.
    @Test func emptyingTheTrashTakesLockedAndReadOnlyItemsFromEveryFolder() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("JunkCleanerServiceTests-\(UUID().uuidString)")
        defer { try? TrashFolders.removePermanently(root) }
        let home = root.appendingPathComponent("home-trash")
        let volume = root.appendingPathComponent("volume-trash")
        let iCloud = root.appendingPathComponent("icloud-trash")
        for folder in [home, volume, iCloud] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let bytes = Data(repeating: 1, count: 64 * 1024)

        let bundle = home.appendingPathComponent("Old.app/Contents")
        try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        try bytes.write(to: bundle.appendingPathComponent("Info.plist"))
        try fileManager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bundle.path)
        let locked = home.appendingPathComponent("locked.zip")
        try bytes.write(to: locked)
        try fileManager.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        try bytes.write(to: volume.appendingPathComponent("movie.mov"))
        try bytes.write(to: iCloud.appendingPathComponent("note.pages"))

        let result = JunkCleanerService.emptyTrash(local: [home.path, volume.path], iCloud: [iCloud.path])

        #expect(try fileManager.contentsOfDirectory(atPath: home.path).isEmpty)
        #expect(try fileManager.contentsOfDirectory(atPath: volume.path).isEmpty)
        #expect(result.freed >= 3 * 64 * 1024)
        #expect(result.iCloud >= 64 * 1024)
        #expect(result.left == result.iCloud)
        #expect(fileManager.fileExists(atPath: iCloud.appendingPathComponent("note.pages").path))
    }

    /// An open app's cache and a folder macOS won't list are left without
    /// counting as failures; the rest moves, measured as it goes, and is
    /// recorded where it went so it can be deleted for good later. A
    /// folder of its own stands in for the Trash.
    @Test func leavesOpenAppsAndProtectedFoldersAndRecordsTheRest() async throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("JunkCleanerServiceTests-\(UUID().uuidString)")
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("caches/Protected").path)
            try? TrashFolders.removePermanently(root)
        }
        let caches = root.appendingPathComponent("caches"), trash = root.appendingPathComponent("trash")
        for folder in ["com.example.Open", "com.example.Closed", "Protected"] {
            try fileManager.createDirectory(at: caches.appendingPathComponent(folder), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 64 * 1024).write(to: caches.appendingPathComponent(folder + "/cache.db"))
        }
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0], ofItemAtPath: caches.appendingPathComponent("Protected").path)
        let database = try AppDatabase(inMemory: DatabaseQueue())
        let ledger = TrashLedger(dbQueue: database.dbQueue)
        let target = JunkTarget(name: "Caches", detail: "", path: caches.path, mode: .contents, deletesPermanently: false)
        let service = JunkCleanerService(
            targets: [target],
            discard: { url in
                let moved = trash.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: moved)
                return moved
            },
            ledger: ledger,
            running: { [AppFootprint(bundleID: "com.example.Open", name: "Open", path: "/Applications/Open.app")] }
        )

        let result = await service.clean(paths: [caches.path])

        #expect(result.inUse == ["Open"])
        #expect(result.skipped.isEmpty)
        #expect(result.freedBytes >= 64 * 1024)
        #expect(try fileManager.contentsOfDirectory(atPath: trash.path) == ["com.example.Closed"])
        #expect(try ledger.entries().map(\.trashPath) == [trash.appendingPathComponent("com.example.Closed").path])
        #expect(try ledger.entries().first?.bytes == result.freedBytes)
    }
}
