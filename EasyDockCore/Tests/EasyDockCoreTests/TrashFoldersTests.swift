import Foundation
import Testing
@testable import EasyDockCore

@Suite struct TrashFoldersTests {
    @Test func theHomeTrashComesFirstThenEveryVolumesForThisUser() {
        let folders = TrashFolders.local(homeDirectory: "/Users/test", volumes: ["/Volumes/Backup", "/Volumes/USB/"], userID: 501)
        #expect(folders == ["/Users/test/.Trash", "/Volumes/Backup/.Trashes/501", "/Volumes/USB/.Trashes/501"])
    }

    @Test func iCloudDrivesTrashIsLookedForInBothPlaces() {
        #expect(TrashFolders.iCloud(homeDirectory: "/Users/test") == [
            "/Users/test/Library/Mobile Documents/.Trash",
            "/Users/test/Library/Mobile Documents/com~apple~CloudDocs/.Trash",
        ])
    }

    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TrashFoldersTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Leaves nothing behind even when a test fails halfway.
    private func cleanUp(_ root: URL) {
        _ = try? TrashFolders.removePermanently(root)
    }

    private func write(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func setMode(_ url: URL, _ mode: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// An app bundle or a package cache in the Trash: folders that can't be
    /// written to, which `removeItem` alone refused.
    @Test func deletesFoldersThatCannotBeWrittenTo() throws {
        let root = try makeRoot()
        defer { cleanUp(root) }
        let item = root.appendingPathComponent("Some.app")
        try write(item.appendingPathComponent("Contents/MacOS/Some"))
        try setMode(item.appendingPathComponent("Contents/MacOS"), 0o555)
        try setMode(item.appendingPathComponent("Contents"), 0o555)
        try setMode(item, 0o500)
        #expect(throws: (any Error).self) { try FileManager.default.removeItem(at: item) }

        try TrashFolders.removePermanently(item)
        #expect(!FileManager.default.fileExists(atPath: item.path))
    }

    /// Finder's Locked checkbox, on a file and on a folder.
    @Test func deletesLockedItems() throws {
        let root = try makeRoot()
        defer { cleanUp(root) }
        let folder = root.appendingPathComponent("Locked folder")
        let file = folder.appendingPathComponent("locked.txt")
        try write(file)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: folder.path)

        try TrashFolders.removePermanently(folder)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// A folder nobody may even look into, owner included.
    @Test func deletesAFolderWithNoPermissionsAtAll() throws {
        let root = try makeRoot()
        defer { cleanUp(root) }
        let folder = root.appendingPathComponent("closed")
        try write(folder.appendingPathComponent("inner/file"))
        try setMode(folder.appendingPathComponent("inner"), 0)
        try setMode(folder, 0)

        try TrashFolders.removePermanently(folder)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    /// A link in the Trash goes; what it leads to keeps its lock and its
    /// permissions.
    @Test func neverChangesWhatALinkLeadsTo() throws {
        let root = try makeRoot()
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: root.appendingPathComponent("outside/kept.txt").path)
            cleanUp(root)
        }
        let outside = root.appendingPathComponent("outside")
        let kept = outside.appendingPathComponent("kept.txt")
        try write(kept)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: kept.path)
        try setMode(outside, 0o555)

        let item = root.appendingPathComponent("trashed")
        try write(item.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(at: item.appendingPathComponent("link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: item.appendingPathComponent("file link"), withDestinationURL: kept)
        try setMode(item, 0o555)

        try TrashFolders.removePermanently(item)
        #expect(!FileManager.default.fileExists(atPath: item.path))
        #expect(FileManager.default.fileExists(atPath: kept.path))
        let folderMode = try FileManager.default.attributesOfItem(atPath: outside.path)[.posixPermissions] as? Int
        #expect(folderMode == 0o555)
        let locked = try FileManager.default.attributesOfItem(atPath: kept.path)[.immutable] as? Bool
        #expect(locked == true)
        try setMode(outside, 0o755)
    }

    @Test func anOrdinaryItemIsSimplyDeleted() throws {
        let root = try makeRoot()
        defer { cleanUp(root) }
        let file = root.appendingPathComponent("plain.txt")
        try write(file)
        try TrashFolders.removePermanently(file)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
