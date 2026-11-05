import AppKit
import CoreServices
import EasyDockCore
import os
import UserNotifications

/// Notices an app removed from /Applications or ~/Applications that left
/// files in `~/Library`, and says so in a notification that opens the
/// Uninstall tab with those files.
///
/// FSEvents reports the watched folders, not every file: installing a large
/// app writes thousands of files inside its bundle, and those changes are
/// ignored. A changed folder is listed again and compared with the apps
/// already known, so only a new app's Info.plist is ever read. An app that
/// is gone is checked again after `AppRemoval.confirmationDelay`, so an
/// update that replaces the bundle, or a move to another folder, isn't taken
/// for a removal.
@MainActor
final class AppRemovalWatcher {
    static let shared = AppRemovalWatcher()

    struct App: Sendable {
        let bundleID: String
        let name: String
    }

    /// Kept for the notification's click, by bundle identifier, until EasyDock quits.
    private(set) var removed: [String: (app: App, path: String)] = [:]
    private var apps: [String: App] = [:]
    private var pending: Set<String> = []
    private var stream: FSEventStreamRef?
    private let uninstaller = AppUninstaller()
    private let log = Logger(subsystem: "com.dangkhoabach.easydock", category: "app-removal")

    nonisolated static let roots = ["/Applications", NSHomeDirectory() + "/Applications"]

    private init() {}

    func start() {
        guard stream == nil else { return }
        Task.detached(priority: .utility) {
            let index = Self.index(Self.roots)
            await MainActor.run { AppRemovalWatcher.shared.apps.merge(index) { known, _ in known } }
        }
        let callback: FSEventStreamCallback = { _, _, count, paths, _, _ in
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let changed = Set(list.prefix(count).compactMap { AppRemoval.root(forChangeAt: $0, roots: AppRemovalWatcher.roots) })
            // The stream delivers on the main queue.
            MainActor.assumeIsolated { changed.forEach(AppRemovalWatcher.shared.rescan) }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, nil, Self.roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// The first two parts of each installed app's identifier ("com.example")
    /// with that app's name.
    nonisolated static func vendors(_ apps: [String: App]) -> [String: String] {
        var vendors: [String: String] = [:]
        for app in apps.values {
            let vendor = app.bundleID.split(separator: ".").prefix(2).joined(separator: ".").lowercased()
            vendors[vendor] = vendors[vendor] ?? app.name
        }
        return vendors
    }

    /// The apps in these folders and in the folders of apps directly inside them.
    nonisolated static func index(_ roots: [String]) -> [String: App] {
        var apps: [String: App] = [:]
        for path in roots.flatMap(appPaths) {
            if let app = app(at: path) { apps[path] = app }
        }
        return apps
    }

    private nonisolated static func appPaths(in root: String) -> [String] {
        let fileManager = FileManager.default
        var paths: [String] = []
        for name in (try? fileManager.contentsOfDirectory(atPath: root)) ?? [] where !name.hasPrefix(".") {
            let path = root + "/" + name
            if name.hasSuffix(".app") {
                paths.append(path)
                continue
            }
            var isFolder: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else { continue }
            for inner in (try? fileManager.contentsOfDirectory(atPath: path)) ?? [] where inner.hasSuffix(".app") {
                paths.append(path + "/" + inner)
            }
        }
        return paths
    }

    /// Read from Info.plist directly: `Bundle(path:)` caches what it read
    /// for the life of the process. macOS's own apps and EasyDock are left out.
    private nonisolated static func app(at path: String) -> App? {
        guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist"),
              let bundleID = info["CFBundleIdentifier"] as? String,
              !AppLeftovers.isProtected(bundleID: bundleID, path: path)
        else { return nil }
        let name = (info["CFBundleName"] as? String) ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return App(bundleID: bundleID, name: name)
    }

    private func rescan(_ root: String) {
        let found = Set(Self.appPaths(in: root))
        for path in found where apps[path] == nil {
            if let app = Self.app(at: path) { apps[path] = app }
        }
        let gone = apps.keys.filter { $0.hasPrefix(root + "/") && !found.contains($0) && !pending.contains($0) }
        for path in gone {
            pending.insert(path)
            Task {
                try? await Task.sleep(for: AppRemoval.confirmationDelay)
                await confirmRemoval(at: path)
            }
        }
    }

    private func confirmRemoval(at path: String) async {
        pending.remove(path)
        guard let app = apps[path], !FileManager.default.fileExists(atPath: path) else { return }
        apps[path] = nil
        let copies = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: app.bundleID).map(\.path)
        guard AppRemoval.liveCopies(copies, exists: FileManager.default.fileExists(atPath:)).isEmpty else {
            log.info("an app moved or was replaced, not removed")
            return
        }
        let leftovers = await uninstaller.leftovers(bundleID: app.bundleID, name: app.name)
        let bytes = leftovers.filter { !$0.matchedByName }.reduce(0) { $0 + $1.bytes }
        log.info("an app was removed, leaving \(bytes, privacy: .public) bytes")
        guard bytes >= AppRemoval.minimumLeftoverBytes else { return }
        removed[app.bundleID] = (app, path)
        await notify(app, bytes: bytes)
    }

    /// macOS asks for permission the first time, right after the user
    /// removed an app, so the prompt comes with its reason.
    private func notify(_ app: App, bytes: Int64) async {
        let settings = AppDatabase.shared.flatMap { try? SettingsRepository(dbQueue: $0.dbQueue).load() } ?? .defaults
        guard settings.removedAppAlerts else { return }
        if await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined {
            guard await NotificationManager.shared.requestAuthorization() else { return }
        }
        let size = CleanupViewModel.formatBytes(bytes)
        // English is the source language and has no table of its own.
        let english = AppLocale.selected == .en
        let title = english ? "\(app.name) was removed" : String(localized: "\(app.name) was removed", bundle: AppLocale.bundle)
        let body = english
            ? "It left \(size) in your Library. Click to review the files and move them to the Trash."
            : String(localized: "It left \(size) in your Library. Click to review the files and move them to the Trash.", bundle: AppLocale.bundle)
        await NotificationManager.shared.notify(title: title, body: body, route: "/cleanup/uninstall/" + app.bundleID)
    }
}
