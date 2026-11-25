import Foundation

/// What an app's files can be named after: its bundle identifier, the
/// identifiers of the helpers, extensions and launchd jobs inside its
/// bundle, the app groups it and they are entitled to, and its names.
/// Read from the bundle by the app's `AppFootprintReader`, and kept in the
/// database so the files of an app removed later can still be told apart.
public struct AppFootprint: Sendable, Equatable, Codable {
    public var bundleID: String
    /// The name shown for the app.
    public var name: String
    public var path: String
    public var embeddedIDs: [String]
    public var groups: [String]
    /// Display, bundle and file name, and those of apps inside it, each once.
    public var names: [String]

    public init(bundleID: String, name: String, path: String, embeddedIDs: [String] = [], groups: [String] = [], names: [String] = []) {
        self.bundleID = bundleID
        self.name = name
        self.path = path
        var seen: Set<String> = [bundleID.lowercased()]
        self.embeddedIDs = embeddedIDs.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        var seenGroups: Set<String> = []
        self.groups = groups.filter { !$0.isEmpty && seenGroups.insert($0.lowercased()).inserted }
        var seenNames: Set<String> = []
        self.names = ([name] + names).filter { !$0.isEmpty && seenNames.insert($0.lowercased()).inserted }
    }

    public var identifiers: [String] { [bundleID] + embeddedIDs }
}

/// A launchd job's property list: what it is called and what it runs.
public struct LaunchJob: Sendable, Equatable {
    public var label: String
    /// `Program`, or the first of `ProgramArguments`.
    public var program: String?
    public var arguments: [String]
    /// The apps macOS shows the job under in Login Items
    /// (`AssociatedBundleIdentifiers`): its owners, in the job's own words.
    public var associatedBundleIDs: [String]

    public init(label: String, program: String?, arguments: [String] = [], associatedBundleIDs: [String] = []) {
        self.label = label
        self.program = program
        self.arguments = arguments
        self.associatedBundleIDs = associatedBundleIDs
    }

    public init?(plist: [String: Any]) {
        guard let label = plist["Label"] as? String, !label.isEmpty else { return nil }
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        // One identifier or a list.
        let associated = plist["AssociatedBundleIdentifiers"] as? [String]
            ?? (plist["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
        self.init(label: label, program: plist["Program"] as? String ?? arguments.first, arguments: arguments,
                  associatedBundleIDs: associated)
    }

    /// The job is the app's: it names the app as its owner, or runs
    /// something inside its bundle.
    public func belongs(to app: AppFootprint) -> Bool {
        let ids = Set(app.identifiers.map { $0.lowercased() })
        return associatedBundleIDs.contains { ids.contains($0.lowercased()) } || runs(inside: [app.path])
    }

    /// Runs something inside one of `paths` (an app bundle, a helper tool),
    /// as its program or as an argument to it.
    public func runs(inside paths: [String]) -> Bool {
        let referenced = ([program].compactMap { $0 } + arguments)
        return paths.contains { path in
            referenced.contains { $0 == path || $0.hasPrefix(path + "/") }
        }
    }

    /// The job can never run again, or serves nothing: its program, or an
    /// app it opens, is gone; or it runs from outside any app and none of
    /// the apps it names as owners is on the Mac. A job that runs from an
    /// app that is there is that app's, whatever it names.
    public func isOrphan(exists: (String) -> Bool, isInstalled: (String) -> Bool) -> Bool {
        let paths = ([program].compactMap { $0 } + arguments).filter { $0.hasPrefix("/") }
        if let program, program.hasPrefix("/"), !exists(program) { return true }
        if paths.contains(where: { Self.bundle(of: $0).map { !exists($0) } ?? false }) { return true }
        if let program, let bundle = Self.bundle(of: program), exists(bundle) { return false }
        return !associatedBundleIDs.isEmpty && !associatedBundleIDs.contains(where: isInstalled)
    }

    /// The app bundle a path is in or is: "/Applications/X.app/Contents/MacOS/X" → "/Applications/X.app".
    static func bundle(of path: String) -> String? {
        guard let range = path.range(of: ".app") else { return nil }
        let rest = path[range.upperBound...]
        return rest.isEmpty || rest.hasPrefix("/") ? String(path[..<range.upperBound]) : nil
    }
}

/// What `pkgutil` says about the installer package an app came from.
public enum PackageReceipt {
    /// The packages in `pkgutil --pkgs` from the app's vendor: identifiers
    /// starting with the first two parts of its bundle identifier. Which of
    /// them installed the app, `contents` tells from their files.
    public static func candidates(fromPackageList output: String, bundleID: String) -> [String] {
        let parts = bundleID.lowercased().split(separator: ".")
        guard parts.count >= 2, bundleID.lowercased().hasPrefix("com.apple.") == false else { return [] }
        let vendor = parts.prefix(2).joined(separator: ".") + "."
        return output.split(whereSeparator: \.isNewline).map(String.init).filter { $0.lowercased().hasPrefix(vendor) }
    }

    /// The `location:` line of `pkgutil --pkg-info`, as an absolute folder.
    public static func location(fromPkgInfo output: String) -> String {
        let line = output.split(separator: "\n").first { $0.hasPrefix("location: ") }
        let location = line.map { String($0.dropFirst("location: ".count)).trimmingCharacters(in: .whitespaces) } ?? ""
        return "/" + location.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// From `pkgutil --files`: whether the package installed `appPath`; the
    /// launchd jobs and helper tools it put in `/Library`; and whether
    /// `appPath` is the only app it installed, which is when its receipt can
    /// be forgotten with the app.
    public static func contents(files: [String], location: String,
                                appPath: String) -> (installedTheApp: Bool, systemItems: [String], onlyThisApp: Bool) {
        let base = location == "/" ? "" : location
        let paths = files.map { base + "/" + $0 }
        let folders = ["/Library/LaunchDaemons/", "/Library/LaunchAgents/", "/Library/PrivilegedHelperTools/"]
        let systemItems = paths.filter { path in
            folders.contains { path.hasPrefix($0) && !path.dropFirst($0.count).contains("/") }
        }
        let apps = Set(paths.filter { $0.hasSuffix(".app") && !$0.dropLast(4).contains(".app/") })
        return (apps.contains(appPath), systemItems, apps == [appPath])
    }
}

/// The shell script run once, with an administrator's password, to remove
/// what an app installed for every user: stop its launchd jobs, move its
/// files to the user's Trash and give them to the user, so EasyDock can
/// empty them later, and forget its installer receipts. What an app left
/// goes only if the app itself did: an app that stays keeps its files.
public enum AdminCommands {
    public struct Move: Sendable, Equatable {
        public var from: String
        public var to: String
        /// The index of the move (an app) this one waits for.
        public var after: Int?

        public init(from: String, to: String, after: Int? = nil) {
            self.from = from
            self.to = to
            self.after = after
        }
    }

    /// A launchctl target such as `system/com.example.helper`, or a package
    /// identifier, with the index of the move (an app) it waits for.
    public struct Step: Sendable, Equatable {
        public var target: String
        public var after: Int?

        public init(_ target: String, after: Int? = nil) {
            self.target = target
            self.after = after
        }
    }

    /// The moves others wait for run first, then the jobs are stopped, then
    /// the other moves and the receipts. Each move that happened prints
    /// `moved <index>`, each receipt forgotten `forgot <index>`; the script
    /// always ends successfully, so one failure doesn't hide what went.
    public static func script(stopping services: [Step], moving moves: [Move], forgetting packages: [Step], owner: UInt32) -> String {
        func when(_ after: Int?, _ line: String) -> String {
            after.map { "[ -n \"$moved\($0)\" ] && " + line } ?? line
        }
        func moveLine(_ index: Int) -> String {
            let from = quote(moves[index].from), to = quote(moves[index].to)
            return when(moves[index].after, "[ ! -e \(to) ] && mv \(from) \(to) && { chown -R \(owner) \(to); moved\(index)=1; echo moved \(index); }")
        }
        let first = Set(moves.compactMap(\.after)).filter(moves.indices.contains)
        var lines = first.sorted().map(moveLine)
        lines += services.map { when($0.after, "launchctl bootout \(quote($0.target)) >/dev/null 2>&1") }
        lines += moves.indices.filter { !first.contains($0) }.map(moveLine)
        for (index, package) in packages.enumerated() {
            lines.append(when(package.after, "pkgutil --forget \(quote(package.target)) >/dev/null 2>&1 && echo forgot \(index)"))
        }
        lines.append("exit 0")
        return lines.joined(separator: "\n")
    }

    public static func results(fromOutput output: String) -> (moved: Set<Int>, forgotten: Set<Int>) {
        var moved: Set<Int> = [], forgotten: Set<Int> = []
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let index = Int(parts[1]) else { continue }
            if parts[0] == "moved" { moved.insert(index) }
            if parts[0] == "forgot" { forgotten.insert(index) }
        }
        return (moved, forgotten)
    }

    /// One argument for `sh`: in single quotes, which keep everything
    /// literal, with each single quote closed, escaped and reopened.
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
