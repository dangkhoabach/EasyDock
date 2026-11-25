import Foundation
import GRDB
import Testing
@testable import EasyDockCore

/// The footprints below are what EasyDock read from these apps on a Mac in
/// November 2026, cut to what each test needs; the entries are the files
/// the old matching missed there.
@Suite struct AppFootprintTests {
    private let zalo = AppFootprint(bundleID: "com.vng.zalo", name: "Zalo", path: "/Applications/Zalo.app",
                                    embeddedIDs: ["com.vng.zalo.helper"], names: ["Zalo"])
    private let docker = AppFootprint(bundleID: "com.docker.docker", name: "Docker", path: "/Applications/Docker.app",
                                      embeddedIDs: ["com.electron.dockerdesktop", "com.docker.vmnetd"],
                                      groups: ["group.com.docker"], names: ["Docker", "Docker Desktop"])
    private let whatsApp = AppFootprint(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", path: "/Applications/WhatsApp.app",
                                        embeddedIDs: ["net.whatsapp.WhatsApp.Intents", "net.whatsapp.WhatsApp.ServiceExtension"],
                                        groups: ["group.net.whatsapp.WhatsApp.shared", "57T9237FN3.net.whatsapp.WhatsApp.shared",
                                                 "group.net.whatsapp.family"])
    private let edge = AppFootprint(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", path: "/Applications/Microsoft Edge.app",
                                    embeddedIDs: ["com.microsoft.edgemac.helper"],
                                    groups: ["UBF8T346G9.com.microsoft.edgemac.widgets", "UBF8T346G9.com.microsoft.oneauth"])

    @Test func identifiersOfWhatTheBundleHoldsAndItsGroupsMatch() {
        #expect(AppLeftovers.match("com.vng.zalo.ShipIt", in: "Caches", app: zalo) == .identifier)
        #expect(AppLeftovers.match("com.electron.dockerdesktop.plist", in: "Preferences", app: docker) == .identifier)
        #expect(AppLeftovers.match("com.docker.vmnetd", in: "PrivilegedHelperTools", app: docker) == .identifier)
        #expect(AppLeftovers.match("com.docker.vmnetd.plist", in: "LaunchDaemons", app: docker) == .identifier)
        #expect(AppLeftovers.match("group.com.docker", in: "Group Containers", app: docker) == .identifier)
        #expect(AppLeftovers.match("net.whatsapp.WhatsApp.Intents", in: "Containers", app: whatsApp) == .identifier)
        #expect(AppLeftovers.match("57T9237FN3.net.whatsapp.WhatsApp.shared", in: "Group Containers", app: whatsApp) == .identifier)
        #expect(AppLeftovers.match("UBF8T346G9.com.microsoft.edgemac.widgets", in: "Group Containers", app: edge) == .identifier)
        #expect(AppLeftovers.match("com.microsoft.edgemac.helper", in: "", app: edge) == .identifier)
    }

    @Test func foldersNamedAfterTheAppMatchByName() {
        #expect(AppLeftovers.match("ZaloData", in: "Application Support", app: zalo) == .name)
        #expect(AppLeftovers.match("Docker Desktop", in: "Application Support", app: docker) == .name)
        #expect(AppLeftovers.match("docker-secrets-engine", in: "Caches", app: docker) == .name)
        #expect(AppLeftovers.match("Microsoft Edge-headless", in: "Caches", app: edge) == .name)
        #expect(AppLeftovers.match("Zalo-2026-11-01-101010.ips", in: "Logs/DiagnosticReports", app: zalo) == .name)
        // Names never match outside the folders apps name after themselves,
        // and a folder in macOS's per-user cache matches by identifier only.
        #expect(AppLeftovers.match("ZaloData", in: "Preferences", app: zalo) == nil)
        #expect(AppLeftovers.match("Zalo", in: "", app: zalo) == nil)
    }

    @Test func aLongerWordIsNotTheName() {
        #expect(!AppLeftovers.isNamed("Zalorama", after: "Zalo"))
        #expect(!AppLeftovers.isNamed("Dockerfile", after: "Docker"))
        #expect(AppLeftovers.isNamed("zalo", after: "Zalo"))
        #expect(AppLeftovers.isNamed("Zalo.log", after: "Zalo"))
        #expect(!AppLeftovers.isNamed("Go Data", after: "Go"))
        #expect(!AppLeftovers.isNamed("Za", after: "Zalo"))
    }

    /// Another app with the same name shares the folder; one that owns it
    /// by identifier takes it.
    @Test func ownershipIsSharedOrLostToAStrongerClaim() {
        let notes = AppFootprint(bundleID: "com.example.Notes", name: "Notes", path: "/Applications/Notes.app")
        let notesBeta = AppFootprint(bundleID: "com.example.Notes.beta", name: "Notes", path: "/Applications/Notes Beta.app")
        let owner = AppFootprint(bundleID: "com.example.Owner", name: "Owner", path: "/Applications/Owner.app",
                                 embeddedIDs: ["Notes"])
        let shared = AppLeftovers.ownership("Notes", in: "Application Support", app: notes, others: [notesBeta])
        #expect(shared?.match == .name)
        #expect(shared?.sharedWith == "Notes")
        #expect(AppLeftovers.ownership("Notes", in: "Application Support", app: notes, others: [owner]) == nil)
        let own = AppLeftovers.ownership("com.example.Notes.plist", in: "Preferences", app: notes, others: [notesBeta])
        #expect(own?.match == .identifier)
        #expect(own?.sharedWith == nil)
        // The app itself is not another app; another copy of it is.
        #expect(AppLeftovers.ownership("Notes", in: "Application Support", app: notes, others: [notes])?.sharedWith == nil)
        let olderCopy = AppFootprint(bundleID: "com.example.Notes", name: "Notes 2026", path: "/Applications/Notes 2026/Notes 2026.app")
        #expect(AppLeftovers.ownership("com.example.Notes.plist", in: "Preferences", app: notes, others: [olderCopy])?.sharedWith == "Notes 2026")
    }

    @Test func footprintsKeepEachIdentifierGroupAndNameOnce() {
        let app = AppFootprint(bundleID: "com.example.App", name: "App One", path: "/Applications/App One.app",
                               embeddedIDs: ["com.example.app", "com.example.App.helper", "com.example.App.helper", ""],
                               groups: ["group.x", "GROUP.X"], names: ["app one", "AppOne"])
        #expect(app.embeddedIDs == ["com.example.App.helper"])
        #expect(app.groups == ["group.x"])
        #expect(app.names == ["App One", "AppOne"])
        #expect(app.identifiers == ["com.example.App", "com.example.App.helper"])
    }
}

@Suite struct LaunchJobTests {
    @Test func readsTheLabelAndProgram() {
        let job = LaunchJob(plist: ["Label": "com.teamviewer.Helper", "Program": "/Library/PrivilegedHelperTools/com.teamviewer.Helper"])
        #expect(job?.program == "/Library/PrivilegedHelperTools/com.teamviewer.Helper")
        let withArguments = LaunchJob(plist: ["Label": "a", "ProgramArguments": ["/usr/bin/open", "-a", "/Applications/Steam.app"]])
        #expect(withArguments?.program == "/usr/bin/open")
        #expect(LaunchJob(plist: ["Program": "/bin/true"]) == nil)
    }

    @Test func belongsToTheAppItRunsFrom() {
        let job = LaunchJob(label: "com.teamviewer.service", program: "/Applications/TeamViewer.app/Contents/MacOS/TeamViewer_Service")
        #expect(job.runs(inside: ["/Applications/TeamViewer.app"]))
        #expect(!job.runs(inside: ["/Applications/TeamViewer"]))
        let opener = LaunchJob(label: "x", program: "/usr/bin/open", arguments: ["/usr/bin/open", "/Applications/Steam.app"])
        #expect(opener.runs(inside: ["/Applications/Steam.app"]))
    }

    @Test func aJobWhoseProgramOrAppIsGoneIsAnOrphan() {
        let exists: (String) -> Bool = { ["/usr/bin/open", "/bin/sh", "/Library/PrivilegedHelperTools/com.teamviewer.Helper"].contains($0) }
        let isInstalled: (String) -> Bool = { $0 == "com.example.Here" }
        func orphan(_ job: LaunchJob) -> Bool { job.isOrphan(exists: exists, isInstalled: isInstalled) }
        #expect(orphan(LaunchJob(label: "a", program: "/Applications/Gone.app/Contents/MacOS/Gone")))
        #expect(orphan(LaunchJob(label: "b", program: "/usr/bin/open", arguments: ["/usr/bin/open", "-a", "/Applications/Gone.app"])))
        #expect(!orphan(LaunchJob(label: "c", program: "/bin/sh", arguments: ["/bin/sh", "-c", "echo"])))
        #expect(!orphan(LaunchJob(label: "d", program: "brew")))
        #expect(!orphan(LaunchJob(label: "e", program: nil)))
        // TeamViewer's helper is still there, but the app it serves is gone.
        let helper = LaunchJob(plist: ["Label": "com.teamviewer.Helper", "Program": "/Library/PrivilegedHelperTools/com.teamviewer.Helper",
                                       "AssociatedBundleIdentifiers": ["com.teamviewer.TeamViewer"]])!
        #expect(orphan(helper))
        #expect(!orphan(LaunchJob(label: "f", program: "/bin/sh", associatedBundleIDs: ["com.example.Here", "com.example.Gone"])))
        // Edge's updater names itself, which LaunchServices may not know,
        // but runs from an app that is there.
        let updater = "/Users/me/Library/Application Support/Microsoft/EdgeUpdater/Current/EdgeUpdater.app"
        let wake = LaunchJob(label: "com.microsoft.EdgeUpdater.wake", program: updater + "/Contents/MacOS/EdgeUpdater",
                             associatedBundleIDs: ["com.microsoft.EdgeUpdater"])
        #expect(!wake.isOrphan(exists: { $0.hasPrefix(updater) }, isInstalled: { _ in false }))
        // The same job left pointing into another user's old home is dead.
        #expect(wake.isOrphan(exists: { _ in false }, isInstalled: { _ in false }))
    }

    /// macOS 13 and later name a job's app in its property list.
    @Test func aJobNamingTheAppAsItsOwnerIsTheApps() {
        let teamViewer = AppFootprint(bundleID: "com.teamviewer.TeamViewer", name: "TeamViewer", path: "/Applications/TeamViewer.app")
        let job = LaunchJob(plist: ["Label": "com.teamviewer.UninstallerWatcher", "Program": "/Library/PrivilegedHelperTools/x",
                                    "AssociatedBundleIdentifiers": "com.teamviewer.teamviewer"])!
        #expect(job.belongs(to: teamViewer))
        #expect(!LaunchJob(label: "x", program: "/bin/sh").belongs(to: teamViewer))
    }
}

@Suite struct PackageReceiptTests {
    @Test func readsWhatPkgutilPrints() {
        let packages = "com.apple.pkg.Core\ncom.teamviewer.teamviewer\ncom.teamviewer.AuthorizationPlugin\ncom.teamviewerx.other\n"
        #expect(PackageReceipt.candidates(fromPackageList: packages, bundleID: "com.teamviewer.TeamViewer")
            == ["com.teamviewer.teamviewer", "com.teamviewer.AuthorizationPlugin"])
        #expect(PackageReceipt.candidates(fromPackageList: packages, bundleID: "com.apple.Safari").isEmpty)
        #expect(PackageReceipt.location(fromPkgInfo: "package-id: x\nlocation: \nvolume: /") == "/")
        #expect(PackageReceipt.location(fromPkgInfo: "location: Applications/") == "/Applications")
    }

    @Test func findsTheSystemItemsAndWhetherTheAppIsTheOnlyOne() {
        let files = [
            "Applications", "Applications/TeamViewer.app", "Applications/TeamViewer.app/Contents/Info.plist",
            "Library", "Library/LaunchDaemons", "Library/LaunchDaemons/com.teamviewer.Helper.plist",
            "Library/PrivilegedHelperTools/com.teamviewer.Helper", "Library/Application Support/TeamViewer/x",
        ]
        let contents = PackageReceipt.contents(files: files, location: "/", appPath: "/Applications/TeamViewer.app")
        #expect(contents.installedTheApp)
        #expect(!PackageReceipt.contents(files: files, location: "/", appPath: "/Applications/Other.app").installedTheApp)
        #expect(contents.systemItems == ["/Library/LaunchDaemons/com.teamviewer.Helper.plist",
                                         "/Library/PrivilegedHelperTools/com.teamviewer.Helper"])
        #expect(contents.onlyThisApp)
        let two = PackageReceipt.contents(files: files + ["Applications/TeamViewer QuickSupport.app"], location: "/",
                                          appPath: "/Applications/TeamViewer.app")
        #expect(!two.onlyThisApp)
    }
}

@Suite struct AdminCommandsTests {
    @Test func everyPathIsOneLiteralArgument() {
        let script = AdminCommands.script(
            stopping: [.init("system/com.example.helper")],
            moving: [.init(from: "/Library/Application Support/It's $(rm -rf ~)", to: "/Users/me/.Trash/It's")],
            forgetting: [.init("com.example.pkg")], owner: 501
        )
        #expect(script == """
            launchctl bootout 'system/com.example.helper' >/dev/null 2>&1
            [ ! -e '/Users/me/.Trash/It'\\''s' ] && mv '/Library/Application Support/It'\\''s $(rm -rf ~)' '/Users/me/.Trash/It'\\''s' && { chown -R 501 '/Users/me/.Trash/It'\\''s'; moved0=1; echo moved 0; }
            pkgutil --forget 'com.example.pkg' >/dev/null 2>&1 && echo forgot 0
            exit 0
            """)
    }

    /// The app moves before anything waits for it, and what it left goes
    /// only if it went: run with `sh` in a temporary folder, as the user.
    @Test func whatAnAppLeftGoesOnlyIfTheAppWent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("admin-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        for folder in ["Apps/Gone.app", "Apps/Stays.app", "Library/Gone", "Library/Stays", "Trash"] {
            try FileManager.default.createDirectory(atPath: root + "/" + folder, withIntermediateDirectories: true)
        }
        // A file already in the Trash under the name keeps Stays.app where it is.
        FileManager.default.createFile(atPath: root + "/Trash/Stays.app", contents: Data())
        let moves: [AdminCommands.Move] = [
            .init(from: root + "/Library/Gone", to: root + "/Trash/Gone", after: 1),
            .init(from: root + "/Apps/Gone.app", to: root + "/Trash/Gone.app"),
            .init(from: root + "/Library/Stays", to: root + "/Trash/Stays", after: 3),
            .init(from: root + "/Apps/Stays.app", to: root + "/Trash/Stays.app"),
        ]
        let script = AdminCommands.script(stopping: [], moving: moves, forgetting: [], owner: getuid())
        #expect(script.components(separatedBy: "\n").first?.contains("Gone.app") == true)

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let results = AdminCommands.results(fromOutput: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        #expect(process.terminationStatus == 0)
        #expect(results.moved == [0, 1])
        #expect(FileManager.default.fileExists(atPath: root + "/Library/Stays"))
        #expect(FileManager.default.fileExists(atPath: root + "/Apps/Stays.app"))
        #expect(!FileManager.default.fileExists(atPath: root + "/Library/Gone"))
    }

    @Test func readsWhatWent() {
        let results = AdminCommands.results(fromOutput: "moved 0\nmoved 2\nforgot 0\nnoise here\n")
        #expect(results.moved == [0, 2])
        #expect(results.forgotten == [0])
    }
}

@Suite struct OrphanVerdictTests {
    private let installed = [
        AppFootprint(bundleID: "com.apple.shortcuts", name: "Shortcuts", path: "/System/Applications/Shortcuts.app",
                     groups: ["group.is.workflow.my.app"]),
        AppFootprint(bundleID: "net.whatsapp.WhatsApp", name: "WhatsApp", path: "/Applications/WhatsApp.app"),
        AppFootprint(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code", path: "/Applications/Visual Studio Code.app",
                     names: ["Code"]),
    ]
    private let removed = [
        AppFootprint(bundleID: "com.example.Driftwood", name: "Driftwood", path: "/Applications/Driftwood.app",
                     names: ["Driftwood Studio"]),
    ]

    private func verdict(_ entry: String, _ folder: String, appData: Bool = false) -> OrphanLeftovers.Verdict? {
        OrphanLeftovers.verdict(entry, in: folder, installed: installed, removed: removed,
                                isInstalled: { installed.map(\.bundleID).contains($0) }, looksLikeAppData: appData)
    }

    @Test func whatAnInstalledAppClaimsIsNoOrphan() {
        #expect(verdict("group.is.workflow.my.app", "Group Containers") == nil)
        #expect(verdict("group.net.whatsapp.WhatsApp.shared", "Group Containers") == nil)
        #expect(verdict("Code", "Application Support", appData: true) == nil)
    }

    @Test func aRemovedAppsFilesAreItsOwn() {
        #expect(verdict("Driftwood Studio", "Application Support", appData: true) == .removedApp(bundleID: "com.example.Driftwood"))
        #expect(verdict("com.example.Driftwood.plist", "Preferences") == .removedApp(bundleID: "com.example.Driftwood"))
    }

    @Test func otherwiseByIdentifierOrAsAnUnknownAppsData() {
        #expect(verdict("ABCDE12345.com.example.Gone", "Group Containers") == .unownedIdentifier("com.example.Gone"))
        #expect(verdict("com.example.Gone.savedState", "Saved Application State") == .unownedIdentifier("com.example.Gone"))
        #expect(verdict("Inkpad", "Application Support", appData: true) == .unknownAppData)
        #expect(verdict("Inkpad", "Application Support") == nil)
        #expect(verdict("Inkpad", "Caches", appData: true) == nil)
        #expect(verdict("group.com.apple.notes", "Group Containers") == nil)
    }
}

@Suite struct JunkRulesTests {
    /// The folders of a Mac's Application Support, as `children` lists them.
    private let tree: [String: [(name: String, isFolder: Bool)]] = [
        "/AS": [("Code", true), ("MobileSync", true), ("ZaloData", true), ("Google", true)],
        "/AS/Code": [("Cache", true), ("Code Cache", true), ("GPUCache", true), ("CachedData", true), ("User", true),
                     ("Partitions", true), ("WebStorage", true), ("Local State", false)],
        "/AS/Code/Partitions": [("vscode-browser", true)],
        "/AS/Code/Partitions/vscode-browser": [("Cache", true), ("GPUCache", true)],
        "/AS/Code/WebStorage": [("1", true)],
        "/AS/Code/WebStorage/1": [("CacheStorage", true)],
        "/AS/MobileSync": [("Backup", true)],
        "/AS/MobileSync/Backup": [("Cache", true)],
        "/AS/ZaloData": [("GPUCache", true), ("GPUPersistentCache", true), ("Data", true)],
        "/AS/Google": [("Chrome", true)],
        "/AS/Google/Chrome": [("Default", true)],
        "/AS/Google/Chrome/Default": [("GPUCache", true), ("Code Cache", true), ("History", false)],
    ]

    @Test func cacheFoldersOfChromiumProfilesOnly() {
        let found = ChromiumCaches.folders(under: "/AS") { tree[$0] }
        #expect(Set(found) == [
            "/AS/Code/Cache", "/AS/Code/Code Cache", "/AS/Code/GPUCache", "/AS/Code/CachedData",
            "/AS/Code/Partitions/vscode-browser/Cache", "/AS/Code/Partitions/vscode-browser/GPUCache",
            "/AS/ZaloData/GPUCache", "/AS/ZaloData/GPUPersistentCache",
            "/AS/Google/Chrome/Default/GPUCache", "/AS/Google/Chrome/Default/Code Cache",
        ])
    }

    @Test func anOpenAppsCachesAreItsOwn() {
        let running = [
            AppFootprint(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", path: "/Applications/Microsoft Edge.app"),
            AppFootprint(bundleID: "com.google.Chrome", name: "Google Chrome", path: "/Applications/Google Chrome.app"),
        ]
        #expect(JunkInUse.owner(of: "com.microsoft.edgemac", running: running) == "Microsoft Edge")
        #expect(JunkInUse.owner(of: "com.microsoft.edgemac.ShipIt", running: running) == "Microsoft Edge")
        #expect(JunkInUse.owner(of: "Microsoft Edge", running: running) == "Microsoft Edge")
        #expect(JunkInUse.owner(of: "Google", running: running) == "Google Chrome")
        #expect(JunkInUse.owner(of: "com.microsoft.edgemacbeta", running: running) == nil)
        #expect(JunkInUse.owner(of: "Homebrew", running: running) == nil)
    }

    @Test func newLocationsAreListedAndTheCompilerCacheOnlyWhenKnown() {
        let targets = JunkTarget.defaults(homeDirectory: "/Users/me", userCacheDirectory: "/var/folders/ab/cd/C/")
        #expect(targets.contains { $0.path == "/Users/me/Library/Application Support" && $0.mode == .chromiumCaches })
        #expect(targets.contains { $0.path == "/Users/me/Library/iTunes/iPhone Software Updates" })
        #expect(targets.contains { $0.path == "/var/folders/ab/cd/C/clang" })
        #expect(!JunkTarget.defaults(homeDirectory: "/Users/me").contains { $0.path.hasSuffix("/clang") })
    }
}

@Suite struct CleanupStoresTests {
    private func makeDatabase() throws -> DatabaseQueue {
        try AppDatabase(inMemory: DatabaseQueue()).dbQueue
    }

    @Test func theLedgerKeepsAndForgetsEntries() throws {
        let ledger = TrashLedger(dbQueue: try makeDatabase())
        let old = TrashLedger.Entry(trashPath: "/t/a", bytes: 10, movedAt: Date(timeIntervalSince1970: 100),
                                    identity: .init(device: 1, inode: 2))
        let new = TrashLedger.Entry(trashPath: "/t/b", bytes: 20, movedAt: Date(timeIntervalSince1970: 200),
                                    identity: .init(device: 1, inode: 3))
        try ledger.record([old, new])
        #expect(try ledger.entries() == [old, new])
        #expect(try ledger.entries(movedBefore: Date(timeIntervalSince1970: 150)) == [old])
        try ledger.remove(["/t/a"])
        #expect(try ledger.entries() == [new])
    }

    /// Only the item EasyDock moved is deleted: one put back or replaced
    /// by another of the same name is left, and its entry dropped.
    @Test func purgingDeletesOnlyWhatWasMoved() {
        let entries = [
            TrashLedger.Entry(trashPath: "/t/same", bytes: 10, movedAt: .now, identity: .init(device: 1, inode: 1)),
            TrashLedger.Entry(trashPath: "/t/replaced", bytes: 20, movedAt: .now, identity: .init(device: 1, inode: 2)),
            TrashLedger.Entry(trashPath: "/t/gone", bytes: 30, movedAt: .now, identity: .init(device: 1, inode: 3)),
            TrashLedger.Entry(trashPath: "/t/locked", bytes: 40, movedAt: .now, identity: .init(device: 1, inode: 4)),
        ]
        let identities: [String: TrashLedger.Identity] = [
            "/t/same": .init(device: 1, inode: 1), "/t/replaced": .init(device: 1, inode: 99), "/t/locked": .init(device: 1, inode: 4),
        ]
        var deleted: [String] = []
        let result = TrashLedger.purge(entries, identity: { identities[$0] }) { url in
            if url.path == "/t/locked" { throw CocoaError(.fileWriteNoPermission) }
            deleted.append(url.path)
        }
        #expect(deleted == ["/t/same"])
        #expect(result.freed == 10)
        #expect(result.settled == ["/t/same", "/t/replaced", "/t/gone"])
        #expect(TrashLedger.present(entries, identity: { identities[$0] }).map(\.trashPath) == ["/t/same", "/t/locked"])
    }

    @Test func knownAppsAreSavedAndTheirRemovalNoticedOnce() throws {
        let store = KnownAppStore(dbQueue: try makeDatabase())
        let app = AppFootprint(bundleID: "com.example.App", name: "App", path: "/Applications/App.app",
                               embeddedIDs: ["com.example.App.helper"], groups: ["group.com.example"])
        try store.save([app])
        try store.markRemovalNoticed("com.example.app")
        #expect(try store.all() == [.init(footprint: app, removalNoticed: true)])
        // Installed again: a later removal is news again.
        try store.save([app])
        #expect(try store.all().first?.removalNoticed == false)
    }
}
