import Foundation

/// What an app leaves behind after its bundle is gone: settings, caches,
/// saved state, its containers, its launchd jobs. Matching is by the
/// identifiers and app groups in its footprint, and by its names in the
/// folders where apps name their own folder after themselves.
public enum AppLeftovers {
    /// Folders under `~/Library` that are searched, one level deep.
    public static let folders = [
        "Application Support", "Application Scripts", "Caches", "Containers", "Cookies",
        "Group Containers", "HTTPStorages", "LaunchAgents", "Logs", "Logs/DiagnosticReports", "Preferences",
        "Preferences/ByHost", "Saved Application State", "WebKit",
    ]

    /// Folders under `/Library`, for apps installed for every user. Moving
    /// from them takes an administrator's password.
    public static let systemFolders = [
        "Application Support", "Caches", "LaunchAgents", "LaunchDaemons", "Logs", "Preferences", "PrivilegedHelperTools",
    ]

    private static let foldersNamedAfterTheApp: Set<String> = ["Application Support", "Caches", "Logs", "Logs/DiagnosticReports"]
    /// `.ShipIt` is the Squirrel updater's copy of the app, kept in Caches.
    private static let suffixes = ["", ".plist", ".savedstate", ".binarycookies", ".shipit"]

    public enum Match: Sendable, Comparable {
        /// Named after the app: likely its own, unless another app on the
        /// Mac has the same name.
        case name
        /// Named after one of the app's identifiers or app groups.
        case identifier
    }

    /// How `entry`, a file or folder directly inside `folder`, belongs to the
    /// app, or nil when it doesn't. A folder outside the lists above, such
    /// as macOS's per-user cache folder, matches by identifier only.
    ///
    /// A bare prefix is not enough: `com.google.Chrome` is a prefix of
    /// Chrome Canary's `com.google.Chrome.canary`. Only known suffixes match,
    /// and per-host settings only when what follows the identifier is a
    /// host identifier.
    public static func match(_ entry: String, in folder: String, app: AppFootprint) -> Match? {
        let lowered = entry.lowercased()
        for id in app.identifiers.map({ $0.lowercased() }) where !id.isEmpty {
            if suffixes.contains(where: { lowered == id + $0 }) { return .identifier }
            if folder == "Preferences/ByHost", lowered.hasPrefix(id + "."), lowered.hasSuffix(".plist") {
                let host = lowered.dropFirst(id.count + 1).dropLast(".plist".count)
                if isHostIdentifier(host) { return .identifier }
            }
            if folder == "Group Containers", lowered.hasSuffix("." + id) { return .identifier }
        }
        if folder == "Group Containers", app.groups.contains(where: { $0.lowercased() == lowered }) { return .identifier }
        if foldersNamedAfterTheApp.contains(folder), app.names.contains(where: { isNamed(entry, after: $0) }) { return .name }
        return nil
    }

    /// The entry is the name, or the name followed by a separator or a new
    /// word: "Docker Desktop", "docker-secrets-engine" and "ZaloData" are
    /// named after Docker and Zalo; "Zalorama" is not. Names under three
    /// characters say too little.
    public static func isNamed(_ entry: String, after name: String) -> Bool {
        guard name.count >= 3, entry.count >= name.count,
              entry.prefix(name.count).lowercased() == name.lowercased()
        else { return false }
        guard let next = entry.dropFirst(name.count).first else { return true }
        return " -_.".contains(next) || next.isUppercase
    }

    /// How the app owns `entry`, or nil when it doesn't or another app owns
    /// it more surely (by identifier where this app has only the name).
    /// `sharedWith` names another app with an equal claim; such an entry
    /// is offered unticked.
    public static func ownership(_ entry: String, in folder: String, app: AppFootprint,
                                 others: [AppFootprint]) -> (match: Match, sharedWith: String?)? {
        guard let match = match(entry, in: folder, app: app) else { return nil }
        var sharedWith: String?
        for other in others where other.bundleID.lowercased() != app.bundleID.lowercased() {
            guard let theirs = self.match(entry, in: folder, app: other) else { continue }
            if theirs > match { return nil }
            if theirs == match { sharedWith = sharedWith ?? other.name }
        }
        return (match, sharedWith)
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

/// What apps that are no longer on the Mac left behind.
public enum OrphanLeftovers {
    /// Folders under `~/Library` that are searched. Launch agents are
    /// judged by their program instead (`LaunchJob.isOrphan`).
    public static let folders = [
        "Application Support", "Caches", "Containers", "Group Containers", "HTTPStorages", "Logs", "Preferences",
        "Saved Application State", "WebKit",
    ]

    private static let suffixes = [".plist", ".savedState", ".binarycookies"]

    public enum Verdict: Sendable, Equatable {
        /// Matches an app EasyDock saw installed that is gone now: certain.
        case removedApp(bundleID: String)
        /// Named after an identifier no app on the Mac has.
        case unownedIdentifier(String)
        /// A Chromium or Electron app's data folder no app on the Mac is
        /// named after: an app's, but which one is unknown.
        case unknownAppData
    }

    /// Whose leftover `entry` is, if nobody's on the Mac. `installed` are
    /// the apps on the Mac, macOS's own among them; `removed` the apps
    /// EasyDock saw that are gone. `looksLikeAppData` says the entry holds a
    /// Chromium or Electron profile (`ChromiumCaches.isProfile`).
    public static func verdict(_ entry: String, in folder: String, installed: [AppFootprint], removed: [AppFootprint],
                               isInstalled: (String) -> Bool, looksLikeAppData: Bool) -> Verdict? {
        if installed.contains(where: { AppLeftovers.match(entry, in: folder, app: $0) != nil }) { return nil }
        if let app = removed.first(where: { AppLeftovers.match(entry, in: folder, app: $0) != nil }) {
            return .removedApp(bundleID: app.bundleID)
        }
        let name = folder == "Group Containers" ? groupCore(entry) : entry
        if let id = bundleID(fromEntry: name) {
            return isOrphan(id, isInstalled: isInstalled) ? .unownedIdentifier(id) : nil
        }
        return folder == "Application Support" && looksLikeAppData ? .unknownAppData : nil
    }

    /// An app group without its `group.` or team prefix:
    /// "group.net.example.App.shared" and "ABCDE12345.net.example.App" are
    /// named after "net.example.App…".
    static func groupCore(_ entry: String) -> String {
        if entry.hasPrefix("group.") { return String(entry.dropFirst("group.".count)) }
        let parts = entry.split(separator: ".", maxSplits: 1)
        if parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) {
            return String(parts[1])
        }
        return entry
    }

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
