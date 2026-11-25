import AppKit
import EasyDockCore
import Foundation

/// Finds an app's bundle and what it left behind — in `~/Library`, in
/// macOS's per-user cache folder, and, for apps installed for every user,
/// in `/Library` with their launchd jobs and installer receipts — and moves
/// the ones the user keeps ticked to the Trash. Nothing is deleted outright
/// but installer receipts, which macOS keeps as records, not files.
actor AppUninstaller {
    struct Item: Identifiable, Sendable {
        enum Kind: Sendable {
            case app, leftover
            /// A launchd job's property list; the job is stopped before it goes.
            case launchJob
            /// An installer package's record, forgotten with `pkgutil`.
            case receipt
        }

        var id: String { path }
        let path: String
        var bytes: Int64 = 0
        let kind: Kind
        var match: AppLeftovers.Match = .identifier
        /// Another app this also matches, which may still use it: offered unticked.
        var sharedWith: String?
        /// Outside the user's own folders: moved with an administrator's password.
        var needsAdmin = false
        /// The launchctl target of a launch job, such as `system/com.example.helper`.
        var service: String?
        /// The package a receipt belongs to.
        var package: String?
        /// The app item this was found with. It goes only if the app does:
        /// an app that stays keeps its files.
        var app: String?

        var isAppBundle: Bool { kind == .app }
        var isTicked: Bool { sharedWith == nil }
        var displayPath: String {
            if let package { return package }
            return path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
    }

    struct TrashResult: Sendable {
        var movedBytes: Int64
        var failedPaths: [String]
    }

    private let ledger: TrashLedger?
    private let knownApps: KnownAppStore?

    init(database: AppDatabase? = AppDatabase.shared) {
        ledger = database.map { TrashLedger(dbQueue: $0.dbQueue) }
        knownApps = database.map { KnownAppStore(dbQueue: $0.dbQueue) }
    }

    // MARK: - Footprints

    /// Footprints read so far, by bundle path, with the bundle's date: an
    /// app updated in place is read again.
    private var footprintCache: [String: (modified: Date?, footprint: AppFootprint)] = [:]
    private var savedIDs: Set<String> = []

    nonisolated static let systemRoots = ["/System/Applications", "/System/Applications/Utilities"]

    func footprint(at path: String) -> AppFootprint? {
        let modified = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let cached = footprintCache[path], cached.modified == modified { return cached.footprint }
        guard let footprint = AppFootprintReader.read(at: path) else { return nil }
        footprintCache[path] = (modified, footprint)
        return footprint
    }

    /// Every app that can own a file: those in the Applications folders,
    /// macOS's own among them. The removable ones are remembered, so their
    /// files can be told apart once they are gone.
    func installedFootprints() -> [AppFootprint] {
        let paths = (AppRemovalWatcher.roots + Self.systemRoots).flatMap(AppRemovalWatcher.appPaths)
        let footprints = paths.compactMap(footprint(at:))
        let removable = footprints.filter { !AppLeftovers.isProtected(bundleID: $0.bundleID, path: $0.path) }
        let ids = Set(removable.map { $0.bundleID.lowercased() })
        if ids != savedIDs, (try? knownApps?.save(removable)) != nil {
            savedIDs = ids
        }
        return footprints
    }

    /// Remembers an app that has just been installed.
    func remember(appAt path: String) {
        guard let footprint = footprint(at: path), !AppLeftovers.isProtected(bundleID: footprint.bundleID, path: path) else { return }
        try? knownApps?.save([footprint])
    }

    /// Apps EasyDock saw installed that are gone now, with whether their
    /// removal was already told.
    func removedApps(installed: [AppFootprint]) -> [KnownAppStore.Record] {
        let installedIDs = Set(installed.map { $0.bundleID.lowercased() })
        return ((try? knownApps?.all()) ?? []).filter { record in
            !installedIDs.contains(record.footprint.bundleID.lowercased()) && !Self.hasLiveCopy(record.footprint.bundleID)
        }
    }

    /// The footprint EasyDock kept for an app, installed or not.
    func knownFootprint(_ bundleID: String) -> AppFootprint? {
        ((try? knownApps?.all()) ?? []).first { $0.footprint.bundleID.lowercased() == bundleID.lowercased() }?.footprint
    }

    func markRemovalNoticed(_ bundleID: String) {
        try? knownApps?.markRemovalNoticed(bundleID)
    }

    nonisolated static func hasLiveCopy(_ bundleID: String) -> Bool {
        let paths = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID).map(\.path)
        return !AppRemoval.liveCopies(paths, exists: FileManager.default.fileExists(atPath:)).isEmpty
    }

    // MARK: - Where leftovers are

    /// The entries of every searched folder and the launchd jobs, listed
    /// once and matched against as many apps as needed.
    struct Snapshot: Sendable {
        struct Entry: Sendable {
            let folderPath: String
            /// The folder's name as `AppLeftovers` knows it; "" for macOS's
            /// per-user cache folder.
            let folder: String
            let name: String
            let isSystem: Bool
            var path: String { folderPath + "/" + name }
        }

        struct Job: Sendable {
            let job: LaunchJob
            /// `system`, or `gui/<uid>` for agents.
            let domain: String
            let isSystem: Bool
        }

        var entries: [Entry] = []
        /// By property list path.
        var jobs: [String: Job] = [:]
        var systemLibrary: String?
    }

    /// macOS's per-user cache folder in `/private/var/folders`.
    nonisolated static var userCacheDirectory: String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    nonisolated static func snapshot(library: String = NSHomeDirectory() + "/Library", folders: [String] = AppLeftovers.folders,
                                     systemLibrary: String? = "/Library", userCache: String? = userCacheDirectory) -> Snapshot {
        var snapshot = Snapshot(systemLibrary: systemLibrary)
        let fileManager = FileManager.default
        var places = folders.map { (library + "/" + $0, $0, false) }
        if let systemLibrary { places += AppLeftovers.systemFolders.map { (systemLibrary + "/" + $0, $0, true) } }
        if let userCache { places.append((userCache, "", false)) }
        let agentDomain = "gui/\(getuid())"
        for (folderPath, folder, isSystem) in places {
            // Unreadable folders are skipped: a missing leftover is better
            // than a failed search.
            for name in (try? fileManager.contentsOfDirectory(atPath: folderPath)) ?? [] where !name.hasPrefix(".") {
                snapshot.entries.append(.init(folderPath: folderPath, folder: folder, name: name, isSystem: isSystem))
                guard folder == "LaunchAgents" || folder == "LaunchDaemons", name.hasSuffix(".plist"),
                      let plist = NSDictionary(contentsOfFile: folderPath + "/" + name) as? [String: Any],
                      let job = LaunchJob(plist: plist)
                else { continue }
                snapshot.jobs[folderPath + "/" + name] = .init(job: job, domain: folder == "LaunchDaemons" ? "system" : agentDomain,
                                                               isSystem: isSystem)
            }
        }
        return snapshot
    }

    /// What `app` left: entries it owns by identifier, group or name;
    /// launchd jobs that run something inside it; and the helper tools
    /// those jobs run. `others` are the other apps on the Mac.
    nonisolated static func leftovers(of app: AppFootprint, others: [AppFootprint], in snapshot: Snapshot,
                                      measure: Bool = true) -> [Item] {
        var items: [Item] = []
        var paths: Set<String> = []
        func add(_ item: Item) {
            guard paths.insert(item.path).inserted else { return }
            items.append(item)
        }
        func jobItem(_ path: String, _ job: Snapshot.Job, sharedWith: String? = nil, match: AppLeftovers.Match = .identifier) -> Item {
            Item(path: path, kind: .launchJob, match: match, sharedWith: sharedWith, needsAdmin: job.isSystem,
                 service: job.domain + "/" + job.job.label)
        }
        for entry in snapshot.entries {
            guard let owned = AppLeftovers.ownership(entry.name, in: entry.folder, app: app, others: others) else { continue }
            if let job = snapshot.jobs[entry.path] {
                add(jobItem(entry.path, job, sharedWith: owned.sharedWith, match: owned.match))
            } else {
                add(Item(path: entry.path, kind: .leftover, match: owned.match, sharedWith: owned.sharedWith, needsAdmin: entry.isSystem))
            }
        }
        for (path, job) in snapshot.jobs where job.job.belongs(to: app) {
            let other = others.first { $0.path != app.path && job.job.belongs(to: $0) }
            add(jobItem(path, job, sharedWith: other?.name))
        }
        if let systemLibrary = snapshot.systemLibrary {
            let tools = systemLibrary + "/PrivilegedHelperTools/"
            for item in items where item.kind == .launchJob {
                guard let program = snapshot.jobs[item.path]?.job.program, program.hasPrefix(tools),
                      FileManager.default.fileExists(atPath: program)
                else { continue }
                add(Item(path: program, kind: .leftover, sharedWith: item.sharedWith, needsAdmin: true))
            }
        }
        guard measure else { return items }
        return items.map { item in
            var item = item
            item.bytes = size(of: item.path)
            return item
        }
    }

    /// What the installer package the app came from put in `/Library`, and
    /// its receipt when the app is the only one it installed. Only the
    /// vendor's packages are opened.
    nonisolated static func packageItems(forApp app: AppFootprint, in snapshot: Snapshot) -> [Item] {
        guard let systemLibrary = snapshot.systemLibrary else { return [] }
        var items: [Item] = []
        let packages = PackageReceipt.candidates(fromPackageList: run("/usr/sbin/pkgutil", ["--pkgs"]), bundleID: app.bundleID)
        for package in packages {
            let location = PackageReceipt.location(fromPkgInfo: run("/usr/sbin/pkgutil", ["--pkg-info", package]))
            let files = run("/usr/sbin/pkgutil", ["--files", package]).split(separator: "\n").map(String.init)
            let contents = PackageReceipt.contents(files: files, location: location, appPath: app.path)
            guard contents.installedTheApp else { continue }
            for file in contents.systemItems where file.hasPrefix(systemLibrary + "/") && FileManager.default.fileExists(atPath: file) {
                if let job = snapshot.jobs[file] {
                    items.append(Item(path: file, bytes: size(of: file), kind: .launchJob, needsAdmin: true,
                                      service: job.domain + "/" + job.job.label))
                } else {
                    items.append(Item(path: file, bytes: size(of: file), kind: .leftover, needsAdmin: true))
                }
            }
            if contents.onlyThisApp {
                items.append(Item(path: "/var/db/receipts/\(package).plist", kind: .receipt, needsAdmin: true, package: package))
            }
        }
        return items
    }

    // MARK: - One app

    /// The app, then everything it left, ticked or not.
    func items(forAppAt appURL: URL, library: String = NSHomeDirectory() + "/Library", systemLibrary: String? = "/Library",
               userCache: String? = userCacheDirectory, roots: [String] = AppRemovalWatcher.roots) -> [Item] {
        let path = appURL.path
        let removal = Self.removalPath(forApp: path, roots: roots)
        let appItem = Item(path: removal, bytes: Self.size(of: removal), kind: .app,
                           needsAdmin: Self.needsAdministrator(toMove: removal))
        guard let app = footprint(at: path) else { return [appItem] }
        let others = installedFootprints().filter { $0.path != path }
        let snapshot = Self.snapshot(library: library, systemLibrary: systemLibrary, userCache: userCache)
        var items = [appItem]
        var seen: Set<String> = [removal]
        for var item in Self.leftovers(of: app, others: others, in: snapshot)
            + (systemLibrary == nil ? [] : Self.packageItems(forApp: app, in: snapshot))
        where seen.insert(item.path).inserted {
            item.app = removal
            items.append(item)
        }
        return items
    }

    /// What goes for the app: its bundle, or the folder in Applications its
    /// vendor put it in, named after it and holding no other app, with the
    /// plug-ins and presets beside it ("Adobe Photoshop 2026/").
    nonisolated static func removalPath(forApp path: String, roots: [String] = AppRemovalWatcher.roots) -> String {
        let bundle = path as NSString
        let folder = bundle.deletingLastPathComponent
        guard roots.contains((folder as NSString).deletingLastPathComponent),
              (folder as NSString).lastPathComponent.caseInsensitiveCompare((bundle.lastPathComponent as NSString).deletingPathExtension) == .orderedSame,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: folder),
              entries.filter({ $0.hasSuffix(".app") }) == [bundle.lastPathComponent]
        else { return path }
        return folder
    }

    /// Whether macOS keeps the user from moving `path` out of its folder:
    /// the folder isn't the user's to change; or `path` is a folder the user
    /// can't change (moving it rewrites its link to its parent), as for an
    /// app installed by root; or the folder is sticky and neither is theirs.
    nonisolated static func needsAdministrator(toMove path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        var item = stat(), folder = stat()
        guard lstat(path, &item) == 0, stat(parent, &folder) == 0 else { return false }
        if access(parent, W_OK) != 0 { return true }
        if item.st_mode & S_IFMT == S_IFDIR && access(path, W_OK) != 0 { return true }
        return folder.st_mode & S_ISVTX != 0 && item.st_uid != getuid() && folder.st_uid != getuid()
    }

    /// What an app that is gone left, from the footprint EasyDock kept.
    func leftovers(ofRemoved app: AppFootprint) -> [Item] {
        Self.leftovers(of: app, others: installedFootprints(), in: Self.snapshot())
    }

    // MARK: - Moving

    /// Apps first: the ones the user can move, then, with one
    /// administrator's password, the ones root owns and whatever else is
    /// outside the user's reach, stopping their launchd jobs. An app that
    /// can't be moved keeps everything it left. Then the user's launch
    /// agents are stopped, so nothing writes the files back, and the rest
    /// is moved. What went is recorded, so it can be deleted for good later.
    func moveToTrash(_ items: [Item]) async -> TrashResult {
        var result = TrashResult(movedBytes: 0, failedPaths: [])
        var moved: [TrashLedger.Entry] = []
        func record(_ item: Item, at trashPath: String?) {
            result.movedBytes += item.bytes
            if let trashPath, let identity = TrashLedger.identity(of: trashPath) {
                moved.append(.init(trashPath: trashPath, bytes: item.bytes, movedAt: Date(), identity: identity))
            }
        }
        // Checked now: what the list said may have changed since.
        var items = items.map { item in
            var item = item
            if !item.needsAdmin && item.kind != .receipt { item.needsAdmin = Self.needsAdministrator(toMove: item.path) }
            return item
        }
        var stayed: Set<String> = []
        func dropWhatStayed() {
            items.removeAll { item in item.app.map(stayed.contains) ?? false }
        }

        for app in items where app.isAppBundle && !app.needsAdmin {
            let url = URL(fileURLWithPath: app.path)
            do {
                let trashURL = try await NSWorkspace.shared.recycle([url])[url]
                record(app, at: trashURL?.path)
            } catch {
                stayed.insert(app.path)
                result.failedPaths.append(app.displayPath)
            }
        }
        dropWhatStayed()

        let admin = items.filter(\.needsAdmin)
        if !admin.isEmpty {
            let outcome = await Self.moveAsAdministrator(admin)
            for (item, trashPath) in outcome.moved { record(item, at: trashPath) }
            result.failedPaths += outcome.failed.map(\.displayPath)
            let went = Set(outcome.moved.map(\.0.path))
            stayed.formUnion(admin.filter { $0.isAppBundle && !went.contains($0.path) }.map(\.path))
            dropWhatStayed()
        }

        let rest = items.filter { !$0.needsAdmin && !$0.isAppBundle }
        for service in rest.compactMap(\.service) { _ = Self.run("/bin/launchctl", ["bootout", service]) }
        for item in rest {
            var trashURL: NSURL?
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: &trashURL)
                record(item, at: (trashURL as URL?)?.path)
            } catch {
                result.failedPaths.append(item.displayPath)
            }
        }
        try? ledger?.record(moved)
        return result
    }

    /// One `do shell script … with administrator privileges`, so macOS asks
    /// for the password once. Cancelling it moves nothing. An app's files
    /// and jobs wait for the app; those of an app that stays are not
    /// reported as failures, the app is.
    private static func moveAsAdministrator(_ items: [Item]) async -> (moved: [(Item, String)], failed: [Item]) {
        let trash = NSHomeDirectory() + "/.Trash"
        var reserved: Set<String> = []
        let files = items.filter { $0.kind != .receipt }
        let receipts = items.filter { $0.kind == .receipt }
        let appIndex = Dictionary(files.enumerated().filter { $0.element.isAppBundle }.map { ($0.element.path, $0.offset) },
                                  uniquingKeysWith: { first, _ in first })
        func after(_ item: Item) -> Int? { item.app.flatMap { appIndex[$0] } }
        let moves = files.map { item in
            AdminCommands.Move(from: item.path, to: uniqueTrashPath(for: item.path, in: trash, reserved: &reserved), after: after(item))
        }
        let script = AdminCommands.script(stopping: files.compactMap { item in item.service.map { .init($0, after: after(item)) } },
                                          moving: moves,
                                          forgetting: receipts.compactMap { item in item.package.map { .init($0, after: after(item)) } },
                                          owner: getuid())
        let prompt = String(localized: "EasyDock needs an administrator to move these apps and files to the Trash.", bundle: AppLocale.bundle)
        let output = await Task.detached(priority: .userInitiated) {
            run("/usr/bin/osascript", [
                "-e", "on run argv", "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
                "-e", "end run", script, prompt,
            ])
        }.value
        let results = AdminCommands.results(fromOutput: output)
        func waitedInVain(_ item: Item) -> Bool { after(item).map { !results.moved.contains($0) } ?? false }
        var moved: [(Item, String)] = []
        var failed: [Item] = []
        for (index, item) in files.enumerated() {
            if results.moved.contains(index) {
                moved.append((item, moves[index].to))
            } else if !waitedInVain(item) {
                failed.append(item)
            }
        }
        for (index, item) in receipts.enumerated() where !results.forgotten.contains(index) && !waitedInVain(item) {
            failed.append(item)
        }
        return (moved, failed)
    }

    /// `name`, or "name 2", "name 3"… before the extension, whichever is free
    /// in the Trash. Checking one name works without Full Disk Access.
    private static func uniqueTrashPath(for path: String, in trash: String, reserved: inout Set<String>) -> String {
        let name = (path as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = trash + "/" + name
        var number = 2
        while reserved.contains(candidate) || FileManager.default.fileExists(atPath: candidate) {
            candidate = trash + "/" + base + " \(number)" + (ext.isEmpty ? "" : "." + ext)
            number += 1
        }
        reserved.insert(candidate)
        return candidate
    }

    // MARK: - Files left by removed apps

    struct OrphanGroup: Identifiable, Sendable {
        enum Kind: Sendable {
            /// An app EasyDock saw installed.
            case removedApp
            /// Named after an identifier no app on the Mac has.
            case identifier
            /// A Chromium or Electron app's data, owner unknown.
            case unknownApp
            /// A launchd job whose program is gone.
            case launchJob
        }

        let id: String
        let title: String
        let kind: Kind
        /// An installed app from the same vendor, which may still use these files.
        let vendorApp: String?
        var items: [Item]
        var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
        /// Ticked at first: certain to belong to nothing on the Mac.
        var isCertain: Bool { kind == .removedApp || kind == .launchJob }
    }

    /// What apps no longer on the Mac left, one group per app, identifier
    /// or job, largest first.
    func orphans(library: String = NSHomeDirectory() + "/Library") -> [OrphanGroup] {
        let installed = installedFootprints()
        let removed = removedApps(installed: installed).map(\.footprint)
        let vendors = AppRemovalWatcher.vendors(AppRemovalWatcher.index(AppRemovalWatcher.roots))
        var known: [String: Bool] = [:]
        let installedIDs = Set(installed.flatMap(\.identifiers).map { $0.lowercased() })
        func isInstalled(_ id: String) -> Bool {
            let key = id.lowercased()
            if installedIDs.contains(key) { return true }
            if let found = known[key] { return found }
            let found = Self.hasLiveCopy(id)
            known[key] = found
            return found
        }
        let snapshot = Self.snapshot(library: library, folders: OrphanLeftovers.folders + ["LaunchAgents"])
        var groups: [String: OrphanGroup] = [:]
        func add(_ item: Item, to key: String, title: String, kind: OrphanGroup.Kind, vendorApp: String? = nil) {
            groups[key, default: OrphanGroup(id: key, title: title, kind: kind, vendorApp: vendorApp, items: [])].items.append(item)
        }

        for entry in snapshot.entries where !entry.isSystem && entry.folder != "LaunchAgents" {
            let looksLikeAppData = entry.folder == "Application Support" && OrphanLeftovers.bundleID(fromEntry: entry.name) == nil
                && Self.holdsChromiumProfile(entry.path)
            guard let verdict = OrphanLeftovers.verdict(entry.name, in: entry.folder, installed: installed, removed: removed,
                                                        isInstalled: isInstalled, looksLikeAppData: looksLikeAppData)
            else { continue }
            let item = Item(path: entry.path, bytes: Self.size(of: entry.path), kind: .leftover)
            switch verdict {
            case .removedApp(let bundleID):
                let name = removed.first { $0.bundleID == bundleID }?.name ?? bundleID
                add(item, to: "app:" + bundleID.lowercased(), title: name, kind: .removedApp)
            case .unownedIdentifier(let id):
                let vendor = id.split(separator: ".").prefix(2).joined(separator: ".").lowercased()
                add(item, to: id.lowercased(), title: id, kind: .identifier, vendorApp: vendors[vendor])
            case .unknownAppData:
                add(item, to: "unknown:" + entry.name, title: entry.name, kind: .unknownApp)
            }
        }

        let tools = (snapshot.systemLibrary ?? "/Library") + "/PrivilegedHelperTools/"
        for (path, job) in snapshot.jobs where job.job.isOrphan(exists: FileManager.default.fileExists(atPath:), isInstalled: isInstalled) {
            let key = "job:" + path
            add(Item(path: path, bytes: Self.size(of: path), kind: .launchJob, needsAdmin: job.isSystem,
                     service: job.domain + "/" + job.job.label), to: key, title: job.job.label, kind: .launchJob)
            if let program = job.job.program, program.hasPrefix(tools), FileManager.default.fileExists(atPath: program) {
                add(Item(path: program, bytes: Self.size(of: program), kind: .leftover, needsAdmin: true), to: key,
                    title: job.job.label, kind: .launchJob)
            }
        }
        return groups.values.sorted { $0.bytes > $1.bytes }
    }

    /// A Chromium or Electron profile in the folder or one level down
    /// ("Inkpad/Default").
    private nonisolated static func holdsChromiumProfile(_ path: String) -> Bool {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else { return false }
        if ChromiumCaches.isProfile(entries) { return true }
        return entries.contains { entry in
            ChromiumCaches.isProfile((try? fileManager.contentsOfDirectory(atPath: path + "/" + entry)) ?? [])
        }
    }

    // MARK: - Installed apps

    /// An installed app as the Uninstall tab lists it. The sizes arrive
    /// later than the rest: measuring a large app takes a while.
    struct InstalledApp: Identifiable, Sendable {
        var id: String { path }
        let path: String
        let bundleID: String
        let name: String
        let version: String?
        /// When it was last opened, as Spotlight recorded it.
        let lastUsed: Date?
        var appBytes: Int64?
        /// What it left that would go with it: everything ticked.
        var leftoverBytes: Int64?

        var totalBytes: Int64? { appBytes.map { $0 + (leftoverBytes ?? 0) } }
    }

    /// Every app in the Applications folders that can be removed here, from
    /// their Info.plist alone: quick, so the list shows at once.
    func installedApps() -> [InstalledApp] {
        AppRemovalWatcher.index(AppRemovalWatcher.roots).map { path, app in
            let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
            let lastUsed = NSMetadataItem(url: URL(fileURLWithPath: path))?.value(forAttribute: "kMDItemLastUsedDate") as? Date
            return InstalledApp(path: path, bundleID: app.bundleID, name: app.name,
                                version: info?["CFBundleShortVersionString"] as? String, lastUsed: lastUsed)
        }
    }

    /// The size of each app and of what it left, a few apps at a time,
    /// handed over as each one is measured. The folders are listed once
    /// for all of them.
    func measure(_ apps: [InstalledApp], onEach: @escaping @Sendable (String, Int64, Int64) async -> Void) async {
        let installed = installedFootprints()
        let snapshot = Self.snapshot()
        let byPath = Dictionary(installed.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        await withTaskGroup(of: Void.self) { group in
            var pending = apps.makeIterator()
            func add(_ app: InstalledApp) {
                let footprint = byPath[app.path] ?? AppFootprint(bundleID: app.bundleID, name: app.name, path: app.path)
                let others = installed.filter { $0.path != app.path }
                group.addTask {
                    let appBytes = Self.size(of: app.path)
                    let leftoverBytes = Self.leftovers(of: footprint, others: others, in: snapshot)
                        .filter(\.isTicked).reduce(0) { $0 + $1.bytes }
                    await onEach(app.path, appBytes, leftoverBytes)
                }
            }
            for _ in 0..<4 { if let app = pending.next() { add(app) } }
            while await group.next() != nil {
                if let app = pending.next() { add(app) }
            }
        }
    }

    // MARK: - Helpers

    nonisolated static func size(of path: String) -> Int64 {
        JunkCleanerService.itemSize(at: path)
    }

    /// A tool's standard output; empty when it couldn't run.
    @discardableResult
    nonisolated static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
