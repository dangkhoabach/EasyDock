import Foundation

/// What an app leaves in `~/Library` after its bundle is gone: settings,
/// caches, saved state, its container. Matching is by bundle identifier, and
/// by the app's name only in the three folders where apps name their own
/// folder after themselves.
public enum AppLeftovers {
    /// Folders under `~/Library` that are searched, one level deep.
    public static let folders = [
        "Application Support", "Application Scripts", "Caches", "Containers", "Cookies",
        "Group Containers", "HTTPStorages", "LaunchAgents", "Logs", "Preferences",
        "Preferences/ByHost", "Saved Application State", "WebKit",
    ]

    private static let foldersNamedAfterTheApp: Set<String> = ["Application Support", "Caches", "Logs"]
    private static let suffixes = ["", ".plist", ".savedState", ".binarycookies"]

    public enum Match: Sendable {
        /// Named after the bundle identifier: the app's own.
        case identifier
        /// Named after the app: likely its own, but another edition of the
        /// app can share the folder, so it is offered unticked.
        case name
    }

    /// How `entry`, a file or folder directly inside `folder`, belongs to the
    /// app, or nil when it doesn't.
    ///
    /// A bare prefix is not enough: `com.google.Chrome` is a prefix of
    /// Chrome Canary's `com.google.Chrome.canary`. Only known suffixes match,
    /// and per-host settings only when what follows the identifier is a
    /// host identifier.
    public static func match(_ entry: String, in folder: String, bundleID: String, appName: String) -> Match? {
        let entry = entry.lowercased()
        let id = bundleID.lowercased()
        guard !id.isEmpty else { return nil }
        if suffixes.contains(where: { entry == id + $0.lowercased() }) { return .identifier }
        if folder == "Preferences/ByHost", entry.hasPrefix(id + "."), entry.hasSuffix(".plist") {
            let host = entry.dropFirst(id.count + 1).dropLast(".plist".count)
            return isHostIdentifier(host) ? .identifier : nil
        }
        if folder == "Group Containers", entry.hasSuffix("." + id) { return .identifier }
        if foldersNamedAfterTheApp.contains(folder), appName.count >= 3, entry == appName.lowercased() { return .name }
        return nil
    }

    /// A hardware UUID or the 12 hex digits older macOS versions used.
    private static func isHostIdentifier(_ text: Substring) -> Bool {
        let hex = text.filter { $0 != "-" }
        guard hex.allSatisfy(\.isHexDigit) else { return false }
        return (text.count == 36 && hex.count == 32) || (text.count == 12 && hex.count == 12)
    }

    /// Apps EasyDock never offers to remove: macOS's own, which it would put
    /// back or which the system needs, and EasyDock itself.
    public static func isProtected(bundleID: String?, path: String) -> Bool {
        guard let bundleID else { return true }
        return bundleID.hasPrefix("com.apple.") || path.hasPrefix("/System/") || bundleID == "com.dangkhoabach.easydock"
    }
}

/// What apps that are no longer on the Mac left in `~/Library`, found by
/// the bundle identifier their files are named after.
public enum OrphanLeftovers {
    /// Folders where an app's own files are named after its bundle
    /// identifier alone. Group Containers are left out (a group is shared
    /// and rarely named after one app), and so are launch agents, which the
    /// Background Items page handles.
    public static let folders = [
        "Application Support", "Caches", "Containers", "HTTPStorages", "Logs", "Preferences",
        "Saved Application State", "WebKit",
    ]

    private static let suffixes = [".plist", ".savedState", ".binarycookies"]

    /// The bundle identifier an entry is named after ("com.example.App.plist"
    /// → "com.example.App"), or nil when its name isn't one: at least three
    /// parts, the first a plain domain such as `com` or `io`.
    public static func bundleID(fromEntry entry: String) -> String? {
        var name = entry
        if let suffix = suffixes.first(where: { name.lowercased().hasSuffix($0.lowercased()) }) {
            name = String(name.dropLast(suffix.count))
        }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              let domain = parts.first, (2...6).contains(domain.count), domain.allSatisfy({ $0.isASCII && $0.isLetter }),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") } })
        else { return nil }
        return name
    }

    /// Whether nothing on the Mac owns this identifier: no app has it, and
    /// no app has one it extends (`com.example.App.helper` belongs to
    /// `com.example.App`). macOS's own are never orphans.
    public static func isOrphan(_ bundleID: String, isInstalled: (String) -> Bool) -> Bool {
        let parts = bundleID.split(separator: ".")
        guard bundleID.lowercased().hasPrefix("com.apple.") == false else { return false }
        for count in stride(from: parts.count, through: 3, by: -1) {
            if isInstalled(parts.prefix(count).joined(separator: ".")) { return false }
        }
        return true
    }
}

/// Telling an app that was removed from one that was updated or moved.
public enum AppRemoval {
    /// Long enough for an update that removes the old copy before the new
    /// one is in place, even a large one.
    public static let confirmationDelay: Duration = .seconds(30)
    /// Leftovers smaller than this aren't worth a notification.
    public static let minimumLeftoverBytes: Int64 = 1_000_000

    /// The watched folder to look at again after a change at `path`: the
    /// folder itself, or a folder of apps directly inside it ("/Applications/
    /// Adobe Photoshop 2026"). Changes inside an app bundle, such as an app
    /// writing to itself or being installed file by file, are ignored.
    public static func root(forChangeAt path: String, roots: [String]) -> String? {
        let path = path.hasSuffix("/") ? String(path.dropLast()) : path
        if roots.contains(path) { return path }
        let parent = (path as NSString).deletingLastPathComponent
        return roots.contains(parent) && !path.hasSuffix(".app") ? parent : nil
    }

    /// Where an app's own copy can still be: an existing path outside the
    /// Trash. LaunchServices still knows copies that are in the Trash.
    public static func liveCopies(_ paths: [String], exists: (String) -> Bool) -> [String] {
        paths.filter { !$0.contains("/.Trash/") && exists($0) }
    }
}

/// Reading the output of the two developer tools the Cleanup tab can run.
public enum DeveloperCleanup {
    /// Devices in `xcrun simctl list devices unavailable --json`: simulators
    /// whose runtime is no longer installed, so they can never boot again.
    public static func unavailableSimulatorCount(fromJSON data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = object["devices"] as? [String: [Any]]
        else { return nil }
        return devices.values.reduce(0) { $0 + $1.count }
    }

    /// The size from the last line of `brew cleanup --dry-run`, such as
    /// "1.2GB". Nil when Homebrew has nothing to remove and says nothing.
    public static func brewReclaimable(fromDryRun output: String) -> String? {
        let marker = "would free approximately "
        guard let line = output.split(separator: "\n").last(where: { $0.contains(marker) }),
              let range = line.range(of: marker)
        else { return nil }
        let size = line[range.upperBound...].split(separator: " ").first.map(String.init)
        return size?.isEmpty == false ? size : nil
    }
}

/// Files in Downloads that have sat there unopened for a while. Only ever
/// found and moved when the user asks: never on a schedule.
public enum OldDownloads {
    public static let ageChoices = [7, 30, 90, 180]

    public static func isOld(addedAt: Date, olderThanDays days: Int, now: Date = Date()) -> Bool {
        now.timeIntervalSince(addedAt) > TimeInterval(days) * 86_400
    }
}
