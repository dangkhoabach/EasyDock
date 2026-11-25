import EasyDockCore
import Foundation
import Testing
@testable import EasyDock

/// The uninstaller reads an app's footprint from its bundle and finds what
/// it left, in a temporary folder that stands in for the Mac: its own
/// Library, `/Library` and the per-user cache folder.
@Suite struct AppUninstallerTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("uninstaller-\(UUID().uuidString)")
    private var app: URL { root.appendingPathComponent("Quillnote.app") }

    private func write(_ path: String, _ contents: Any? = nil) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let contents {
            let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
            try data.write(to: url)
        } else {
            try Data(repeating: 1, count: 5000).write(to: url)
        }
    }

    /// A bundle with an Electron-style helper, a nested app and a launchd
    /// helper tool, and what such an app leaves.
    private func makeMac() throws {
        try write("Quillnote.app/Contents/Info.plist", ["CFBundleIdentifier": "com.example.Quillnote", "CFBundleName": "Quillnote",
                                                        "CFBundleExecutable": "Quillnote"])
        try write("Quillnote.app/Contents/Frameworks/Quillnote Helper.app/Contents/Info.plist",
                  ["CFBundleIdentifier": "com.example.Quillnote.helper"])
        try write("Quillnote.app/Contents/MacOS/Quillnote Desktop.app/Contents/Info.plist",
                  ["CFBundleIdentifier": "com.example.desktop", "CFBundleName": "Quillnote Desktop"])
        try write("Quillnote.app/Contents/Library/LaunchServices/com.example.Quillnote.daemon")
        let paths = [
            "Library/Preferences/com.example.Quillnote.plist",
            "Library/Preferences/com.example.desktop.plist",
            "Library/Caches/com.example.Quillnote.ShipIt/update.zip",
            "Library/Caches/com.example.Quillnote.helper/cache.db",
            "Library/Application Support/QuillnoteData/data.json",
            "Library/Application Support/Quillnote Desktop/data.json",
            "Library/Application Support/Shared/data.json",
            "Library/Logs/DiagnosticReports/Quillnote-2026-11-26-101010.ips",
            "Library/Preferences/com.example.Quillnote.canary.plist",
            "Library/Caches/com.example.Other/cache.db",
            "C/com.example.Quillnote.helper/cache",
            "SystemLibrary/PrivilegedHelperTools/com.example.Quillnote.daemon",
            "SystemLibrary/Application Support/Unrelated/x",
        ]
        for path in paths { try write(path) }
        try write("Library/LaunchAgents/com.example.updater.plist",
                  ["Label": "com.example.updater", "ProgramArguments": [app.path + "/Contents/MacOS/Updater", "--wake"]])
        try write("SystemLibrary/LaunchDaemons/com.example.Quillnote.daemon.plist",
                  ["Label": "com.example.Quillnote.daemon", "Program": root.path + "/SystemLibrary/PrivilegedHelperTools/com.example.Quillnote.daemon"])
    }

    @Test func theFootprintHoldsWhatTheBundleHolds() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeMac()
        let footprint = try #require(AppFootprintReader.read(at: app.path))
        #expect(footprint.bundleID == "com.example.Quillnote")
        #expect(Set(footprint.embeddedIDs) == ["com.example.Quillnote.helper", "com.example.desktop", "com.example.Quillnote.daemon"])
        #expect(footprint.names.contains("Quillnote Desktop"))
        #expect(!footprint.names.contains("Quillnote Helper"))
    }

    @Test func everythingItLeftIsFoundWithHowToRemoveIt() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeMac()
        let footprint = try #require(AppFootprintReader.read(at: app.path))
        let other = AppFootprint(bundleID: "com.example.Shared", name: "Shared", path: "/Applications/Shared.app")
        let snapshot = AppUninstaller.snapshot(library: root.path + "/Library", systemLibrary: root.path + "/SystemLibrary",
                                               userCache: root.path + "/C")
        let items = AppUninstaller.leftovers(of: footprint, others: [other], in: snapshot)
        let byPath = Dictionary(uniqueKeysWithValues: items.map { (String($0.path.dropFirst(root.path.count + 1)), $0) })

        #expect(Set(byPath.keys) == [
            "Library/Preferences/com.example.Quillnote.plist",
            "Library/Preferences/com.example.desktop.plist",
            "Library/Caches/com.example.Quillnote.ShipIt",
            "Library/Caches/com.example.Quillnote.helper",
            "Library/Application Support/QuillnoteData",
            "Library/Application Support/Quillnote Desktop",
            "Library/Logs/DiagnosticReports/Quillnote-2026-11-26-101010.ips",
            "Library/LaunchAgents/com.example.updater.plist",
            "C/com.example.Quillnote.helper",
            "SystemLibrary/LaunchDaemons/com.example.Quillnote.daemon.plist",
            "SystemLibrary/PrivilegedHelperTools/com.example.Quillnote.daemon",
        ])
        #expect(items.allSatisfy { $0.isTicked })
        #expect(items.allSatisfy { $0.bytes > 0 })
        #expect(byPath["Library/LaunchAgents/com.example.updater.plist"]?.service == "gui/\(getuid())/com.example.updater")
        #expect(byPath["Library/LaunchAgents/com.example.updater.plist"]?.needsAdmin == false)
        let daemon = byPath["SystemLibrary/LaunchDaemons/com.example.Quillnote.daemon.plist"]
        #expect(daemon?.kind == .launchJob)
        #expect(daemon?.service == "system/com.example.Quillnote.daemon")
        #expect(daemon?.needsAdmin == true)
        #expect(byPath["SystemLibrary/PrivilegedHelperTools/com.example.Quillnote.daemon"]?.needsAdmin == true)
        #expect(byPath["Library/Application Support/QuillnoteData"]?.match == .name)
    }

    /// A folder named after two apps is offered unticked, naming the other.
    @Test func aFolderAnotherAppIsNamedAfterIsUnticked() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeMac()
        let footprint = try #require(AppFootprintReader.read(at: app.path))
        let twin = AppFootprint(bundleID: "com.example.QuillnotePro", name: "Quillnote Pro", path: "/Applications/Quillnote Pro.app",
                                names: ["QuillnoteData"])
        let snapshot = AppUninstaller.snapshot(library: root.path + "/Library", systemLibrary: nil, userCache: nil)
        let item = AppUninstaller.leftovers(of: footprint, others: [twin], in: snapshot).first { $0.path.hasSuffix("/QuillnoteData") }
        #expect(item?.isTicked == false)
        #expect(item?.sharedWith == "Quillnote Pro")
    }

    /// A folder the user can't change can't be moved out of its folder
    /// (as an app root installed), nor can anything in a folder that isn't
    /// theirs to change.
    @Test func whatOnlyAnAdministratorCanMoveIsToldApart() throws {
        let manager = FileManager.default
        try write("Free/file")
        try write("Locked.app/Contents/Info.plist")
        try write("Shut/file")
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path + "/Locked.app")
        try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path + "/Shut")
        defer {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path + "/Locked.app")
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path + "/Shut")
            try? manager.removeItem(at: root)
        }
        #expect(!AppUninstaller.needsAdministrator(toMove: root.path + "/Free/file"))
        #expect(!AppUninstaller.needsAdministrator(toMove: root.path + "/Free"))
        #expect(AppUninstaller.needsAdministrator(toMove: root.path + "/Locked.app"))
        #expect(AppUninstaller.needsAdministrator(toMove: root.path + "/Shut/file"))
        #expect(!AppUninstaller.needsAdministrator(toMove: root.path + "/Missing"))
    }

    /// An app in a folder of its own name goes with the folder; one that
    /// shares its folder with another app goes alone.
    @Test func anAppsOwnFolderGoesWithIt() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let apps = root.path + "/Applications"
        try write("Applications/Quillnote 2026/Quillnote 2026.app/Contents/Info.plist")
        try write("Applications/Quillnote 2026/Presets/brush")
        try write("Applications/Suite/Writer.app/Contents/Info.plist")
        try write("Applications/Suite/Sheets.app/Contents/Info.plist")
        try write("Applications/Tools/Other Name.app/Contents/Info.plist")
        #expect(AppUninstaller.removalPath(forApp: apps + "/Quillnote 2026/Quillnote 2026.app", roots: [apps]) == apps + "/Quillnote 2026")
        #expect(AppUninstaller.removalPath(forApp: apps + "/Suite/Writer.app", roots: [apps]) == apps + "/Suite/Writer.app")
        #expect(AppUninstaller.removalPath(forApp: apps + "/Tools/Other Name.app", roots: [apps]) == apps + "/Tools/Other Name.app")
        #expect(AppUninstaller.removalPath(forApp: app.path, roots: [apps]) == app.path)
    }

    /// An app that can't be moved keeps what it left; files found with no
    /// app still go.
    @Test func anAppThatStaysKeepsItsFiles() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Library/Preferences/com.example.Gone.plist")
        let missingApp = root.path + "/Gone.app"
        let items = [
            AppUninstaller.Item(path: missingApp, kind: .app),
            AppUninstaller.Item(path: root.path + "/Library/Preferences/com.example.Gone.plist", kind: .leftover, app: missingApp),
        ]
        let result = await AppUninstaller(database: nil).moveToTrash(items)
        #expect(result.failedPaths.count == 1)
        #expect(FileManager.default.fileExists(atPath: root.path + "/Library/Preferences/com.example.Gone.plist"))
    }

    @Test func theAppComesFirst() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try makeMac()
        let items = await AppUninstaller(database: nil).items(forAppAt: app, library: root.path + "/Library", systemLibrary: nil, userCache: nil)
        #expect(items.first?.isAppBundle == true)
        #expect(items.first?.path == app.path)
        #expect(items.dropFirst().allSatisfy { $0.app == app.path })
        #expect(items.contains { $0.path.hasSuffix("/com.example.Quillnote.plist") })
    }
}
