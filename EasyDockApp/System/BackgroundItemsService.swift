import AppKit
import Darwin
import EasyDockCore
import Foundation

/// The launch agents and daemons apps installed, with who they belong to and
/// whether they run. Read on demand: the property lists in four places and
/// four `launchctl` listings, a few milliseconds in all.
actor BackgroundItemsService {
    struct Row: Identifiable, Sendable {
        let item: LaunchItem
        var id: String { item.id }
        /// The app the job belongs to, when it can be told.
        let ownerName: String?
        let ownerPath: String?
        let pid: Int?
        /// The process's memory, when macOS lets EasyDock read it (not for
        /// processes running as root).
        let memoryBytes: Int64?
        let isDisabled: Bool
        let isOrphan: Bool

        /// Only a user's own agent is turned off here and stays off:
        /// one an app registered turns itself back on when the app opens, and
        /// one for every user needs an administrator.
        var canToggle: Bool { item.scope == .userAgent && !isOrphan }
    }

    private static let uid = getuid()

    func load() -> [Row] {
        let fileManager = FileManager.default
        let home = NSHomeDirectory()
        var items: [LaunchItem] = []
        for (folder, scope) in [(home + "/Library/LaunchAgents", LaunchItem.Scope.userAgent),
                                ("/Library/LaunchAgents", .globalAgent), ("/Library/LaunchDaemons", .globalDaemon)] {
            items += Self.items(in: folder, scope: scope)
        }
        // Jobs inside apps count only once their app registered them.
        var embedded: [LaunchItem] = []
        for apps in ["/Applications", home + "/Applications"] {
            for app in (try? fileManager.contentsOfDirectory(atPath: apps)) ?? [] where app.hasSuffix(".app") {
                let library = apps + "/" + app + "/Contents/Library"
                embedded += Self.items(in: library + "/LaunchAgents", scope: .appAgent)
                embedded += Self.items(in: library + "/LaunchDaemons", scope: .appDaemon)
            }
        }

        let userLoaded = LaunchItems.loadedServices(fromPrint: Self.launchctl(["print", "gui/\(Self.uid)"]).output)
        let systemLoaded = LaunchItems.loadedServices(fromPrint: Self.launchctl(["print", "system"]).output)
        let userDisabled = LaunchItems.disabledServices(fromPrintDisabled: Self.launchctl(["print-disabled", "gui/\(Self.uid)"]).output)
        let systemDisabled = LaunchItems.disabledServices(fromPrintDisabled: Self.launchctl(["print-disabled", "system"]).output)
        items += embedded.filter { ($0.scope.isDaemon ? systemLoaded : userLoaded)[$0.label] != nil }

        return items.filter { !LaunchItems.isApple($0.label) }.map { item in
            let pid = (item.scope.isDaemon ? systemLoaded : userLoaded)[item.label].flatMap { $0 > 0 ? $0 : nil }
            let owner = Self.owner(of: item)
            return Row(
                item: item,
                ownerName: owner.map { fileManager.displayName(atPath: $0) },
                ownerPath: owner,
                pid: pid,
                memoryBytes: pid.flatMap(Self.footprint),
                isDisabled: (item.scope.isDaemon ? systemDisabled : userDisabled)[item.label] ?? false,
                isOrphan: LaunchItems.isOrphan(item, exists: fileManager.fileExists(atPath:))
            )
        }
    }

    /// Turns a user agent off (and stops it) or back on (and starts it).
    /// launchd keeps the choice across restarts.
    func setEnabled(_ enabled: Bool, _ item: LaunchItem) -> Bool {
        guard item.scope == .userAgent, LaunchItems.isValidLabel(item.label) else { return false }
        let target = "gui/\(Self.uid)/\(item.label)"
        if enabled {
            guard Self.launchctl(["enable", target]).status == 0 else { return false }
            // Fails harmlessly when it's already loaded.
            _ = Self.launchctl(["bootstrap", "gui/\(Self.uid)", item.plistPath])
        } else {
            guard Self.launchctl(["disable", target]).status == 0 else { return false }
            _ = Self.launchctl(["bootout", target])
        }
        return true
    }

    /// Unloads a job before its property list goes to the Trash. Only the
    /// user's own domain can be told so without an administrator.
    func unload(_ item: LaunchItem) {
        guard !item.scope.isDaemon, LaunchItems.isValidLabel(item.label) else { return }
        _ = Self.launchctl(["bootout", "gui/\(Self.uid)/\(item.label)"])
    }

    private static func items(in folder: String, scope: LaunchItem.Scope) -> [LaunchItem] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return names.filter { $0.hasSuffix(".plist") }.compactMap { name in
            let path = folder + "/" + name
            guard let data = FileManager.default.contents(atPath: path),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }
            return LaunchItem(plist: plist, path: path, scope: scope)
        }
    }

    /// The app named by the job, else the app its program or property list is in.
    private static func owner(of item: LaunchItem) -> String? {
        for id in item.associatedBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url.path }
        }
        for path in [item.programPath, item.plistPath].compactMap({ $0 }) {
            if let app = LaunchItems.appBundle(containing: path), FileManager.default.fileExists(atPath: app) { return app }
        }
        return nil
    }

    private static func footprint(_ pid: Int) -> Int64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid_t(pid), RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Int64(info.ri_phys_footprint) : nil
    }

    /// Arguments go straight to the tool, never through a shell.
    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
