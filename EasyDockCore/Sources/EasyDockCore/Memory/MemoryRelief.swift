import Foundation

/// An app and the memory it takes with its helper processes.
public struct AppMemory: Equatable, Sendable {
    public var bundleID: String
    public var name: String
    public var bytes: UInt64

    public init(bundleID: String, name: String, bytes: UInt64) {
        self.bundleID = bundleID
        self.name = name
        self.bytes = bytes
    }
}

/// What to suggest quitting when macOS runs short of memory.
public enum MemoryRelief {
    /// Between two notifications, however often macOS warns.
    public static let quietPeriod: TimeInterval = 30 * 60
    /// Apps lighter than this aren't worth quitting for memory.
    public static let minimumBytes: UInt64 = 300 * 1_000_000

    /// The heaviest apps the user isn't using: never the one in front,
    /// Finder or EasyDock. Up to three, heaviest first.
    public static func suggestions(_ apps: [AppMemory], frontmost: String?, limit: Int = 3) -> [AppMemory] {
        let kept: Set<String> = ["com.apple.finder", "com.dangkhoabach.easydock"]
        return apps
            .filter { $0.bytes >= minimumBytes && $0.bundleID != frontmost && !kept.contains($0.bundleID) }
            .sorted { $0.bytes > $1.bytes }
            .prefix(limit)
            .map { $0 }
    }
}

/// The user's rules: quit an app once it has gone this long without being
/// used, that is without being the app in front.
public enum IdleQuit {
    public static let minuteChoices = [15, 30, 60, 120, 240]

    /// The apps to quit now. An app that was already asked to quit and is
    /// still open (it asked about unsaved work, say) isn't asked again
    /// until it has been used.
    public static func due(rules: [String: Int], lastUsed: [String: Date], running: Set<String>,
                           frontmost: String?, asked: Set<String>, now: Date) -> [String] {
        rules.keys.sorted().filter { id in
            guard running.contains(id), id != frontmost, !asked.contains(id),
                  let minutes = rules[id], let used = lastUsed[id] else { return false }
            return now.timeIntervalSince(used) >= TimeInterval(minutes * 60)
        }
    }

    /// When the next app falls due, for a single wait; nil when none can.
    public static func nextDeadline(rules: [String: Int], lastUsed: [String: Date], running: Set<String>,
                                    frontmost: String?, asked: Set<String>) -> Date? {
        rules.compactMap { id, minutes -> Date? in
            guard running.contains(id), id != frontmost, !asked.contains(id), let used = lastUsed[id] else { return nil }
            return used.addingTimeInterval(TimeInterval(minutes * 60))
        }.min()
    }

    /// "com.example.App=60" lines, as kept in `app_settings`.
    public static func encode(_ rules: [String: Int]) -> String {
        rules.keys.sorted().map { "\($0)=\(rules[$0]!)" }.joined(separator: "\n")
    }

    public static func decode(_ text: String) -> [String: Int] {
        var rules: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=")
            guard parts.count == 2, let minutes = Int(parts[1]), minutes > 0 else { continue }
            rules[String(parts[0])] = minutes
        }
        return rules
    }
}
