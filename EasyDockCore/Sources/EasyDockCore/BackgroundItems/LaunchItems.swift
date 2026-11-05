import Foundation

/// A launchd job from a property list: what runs, from where, and who it
/// belongs to.
public struct LaunchItem: Identifiable, Hashable, Sendable {
    public enum Scope: String, Sendable {
        /// `~/Library/LaunchAgents`: the user's own, which EasyDock can turn off.
        case userAgent
        /// `/Library/LaunchAgents`, for every user.
        case globalAgent
        /// `/Library/LaunchDaemons`, run as root.
        case globalDaemon
        /// Inside an app, registered by the app itself (`SMAppService`).
        case appAgent
        case appDaemon

        /// Daemons live in launchd's system domain, agents in the user's.
        public var isDaemon: Bool { self == .globalDaemon || self == .appDaemon }
    }

    public var id: String { plistPath }
    public let label: String
    public let plistPath: String
    public let scope: Scope
    /// The program's absolute path, when the property list names one.
    public let programPath: String?
    public let associatedBundleIDs: [String]

    /// Nil for a property list without a label, which launchd ignores too.
    public init?(plist: [String: Any], path: String, scope: Scope) {
        guard let label = plist["Label"] as? String, !label.isEmpty else { return nil }
        self.label = label
        plistPath = path
        self.scope = scope
        associatedBundleIDs = plist["AssociatedBundleIdentifiers"] as? [String]
            ?? (plist["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
        if let program = plist["Program"] as? String {
            programPath = program
        } else if let bundleProgram = plist["BundleProgram"] as? String, let app = LaunchItems.appBundle(containing: path) {
            programPath = app + "/" + bundleProgram
        } else {
            programPath = (plist["ProgramArguments"] as? [String])?.first
        }
    }
}

public enum LaunchItems {
    /// What a label must look like before it goes into a `launchctl` command.
    public static func isValidLabel(_ label: String) -> Bool {
        !label.isEmpty && label.count <= 255 && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
    }

    /// The outermost app bundle a path is inside, or nil.
    public static func appBundle(containing path: String) -> String? {
        guard let range = path.range(of: ".app/") ?? (path.hasSuffix(".app") ? path.range(of: ".app", options: .backwards) : nil) else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// macOS's own jobs are left out of the list.
    public static func isApple(_ label: String) -> Bool {
        label.hasPrefix("com.apple.")
    }

    /// The program is gone: the app that installed the job was removed and
    /// left it behind. A job whose program is a command (no absolute path)
    /// is never taken for one.
    public static func isOrphan(_ item: LaunchItem, exists: (String) -> Bool) -> Bool {
        guard let program = item.programPath, program.hasPrefix("/") else { return false }
        return !exists(program)
    }

    /// The jobs loaded in `launchctl print <domain>`'s `services` block:
    /// label to process ID, 0 for a job loaded but not running.
    public static func loadedServices(fromPrint output: String) -> [String: Int] {
        var loaded: [String: Int] = [:]
        var inServices = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "services = {" { inServices = true; continue }
            guard inServices else { continue }
            if trimmed == "}" { break }
            let fields = trimmed.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, let pid = Int(fields[0]) else { continue }
            loaded[String(fields[2])] = pid
        }
        return loaded
    }

    /// `launchctl print-disabled <domain>`: label to whether it is turned off.
    /// Older systems print `true`/`false` instead of `disabled`/`enabled`.
    public static func disabledServices(fromPrintDisabled output: String) -> [String: Bool] {
        var disabled: [String: Bool] = [:]
        var inServices = false
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("disabled services = {") { inServices = true; continue }
            guard inServices else { continue }
            if trimmed == "}" { break }
            let parts = trimmed.components(separatedBy: " => ")
            guard parts.count == 2, parts[0].hasPrefix("\""), parts[0].hasSuffix("\"") else { continue }
            disabled[String(parts[0].dropFirst().dropLast())] = parts[1] == "disabled" || parts[1] == "true"
        }
        return disabled
    }
}
