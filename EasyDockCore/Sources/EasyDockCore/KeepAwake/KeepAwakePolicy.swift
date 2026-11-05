import Foundation
import GRDB

/// A session the user started from the menu bar, Settings or the shortcut.
public struct KeepAwakeSession: Equatable, Sendable {
    /// Nil until it is turned off.
    public var endsAt: Date?

    public init(endsAt: Date?) {
        self.endsAt = endsAt
    }

    /// `minutes` 0 is until turned off.
    public static func starting(minutes: Int, at now: Date) -> KeepAwakeSession {
        KeepAwakeSession(endsAt: minutes > 0 ? now.addingTimeInterval(TimeInterval(minutes * 60)) : nil)
    }

    public func remaining(at now: Date) -> TimeInterval? {
        endsAt.map { max(0, $0.timeIntervalSince(now)) }
    }
}

/// The internal battery, when the Mac has one.
public struct BatteryLevel: Equatable, Sendable {
    public var percent: Double
    /// Unplugged; charging and full-on-power both count as plugged in.
    public var onBattery: Bool

    public init(percent: Double, onBattery: Bool) {
        self.percent = percent
        self.onBattery = onBattery
    }
}

/// Why the Mac is kept awake.
public enum KeepAwakeReason: Equatable, Sendable {
    case session
    /// The first running app of the user's list, by bundle identifier.
    case app(String)
}

public enum KeepAwakePolicy {
    /// The durations offered, in minutes; 0 is until turned off.
    public static let durations = [0, 15, 30, 60, 120, 240]

    /// Unplugged at or below the user's limit; a limit of 0 never stops it.
    public static func batteryIsLow(_ battery: BatteryLevel?, minimumPercent: Int) -> Bool {
        guard minimumPercent > 0, let battery, battery.onBattery else { return false }
        return battery.percent <= Double(minimumPercent)
    }

    /// Over, or stopped by a low battery. A stopped session stays off once the
    /// Mac is plugged in again, as a timer that ran out does.
    public static func sessionShouldEnd(_ session: KeepAwakeSession, at now: Date, battery: BatteryLevel?, minimumPercent: Int) -> Bool {
        if let endsAt = session.endsAt, endsAt <= now { return true }
        return batteryIsLow(battery, minimumPercent: minimumPercent)
    }

    /// Nil lets the Mac sleep. A running app from the list keeps it awake
    /// only while the battery is above the limit, and again once it is
    /// plugged in.
    public static func reason(
        session: KeepAwakeSession?, runningApps: Set<String>, triggerApps: [String],
        battery: BatteryLevel?, minimumPercent: Int
    ) -> KeepAwakeReason? {
        guard !batteryIsLow(battery, minimumPercent: minimumPercent) else { return nil }
        if session != nil { return .session }
        return triggerApps.first(where: runningApps.contains).map(KeepAwakeReason.app)
    }
}

/// A running session written down, so that EasyDock starting again in the
/// same boot (after an update, a crash, or a quit it didn't choose) carries
/// it on. A restart of the Mac starts with no session, as it always did.
public enum KeepAwakeSessionRecord {
    /// "<boot time>|<end in seconds since 1970>", or "-" for until turned off.
    public static func encode(_ session: KeepAwakeSession, bootTime: Int) -> String {
        "\(bootTime)|" + (session.endsAt.map { String(Int($0.timeIntervalSince1970.rounded(.up))) } ?? "-")
    }

    /// The session, if it was written in this boot and hasn't run out.
    public static func decode(_ record: String, bootTime: Int, now: Date) -> KeepAwakeSession? {
        let parts = record.split(separator: "|")
        guard parts.count == 2, Int(parts[0]) == bootTime else { return nil }
        if parts[1] == "-" { return KeepAwakeSession(endsAt: nil) }
        guard let seconds = TimeInterval(parts[1]) else { return nil }
        let endsAt = Date(timeIntervalSince1970: seconds)
        return endsAt > now ? KeepAwakeSession(endsAt: endsAt) : nil
    }
}

/// The record in `app_settings`; empty when no session runs.
public struct KeepAwakeSessionStore: Sendable {
    private static let key = "keep_awake_session"
    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func load() throws -> String {
        try dbQueue.read { db in try AppSettingsStore.get(db, key: Self.key, default: "") }
    }

    public func save(_ record: String) throws {
        try dbQueue.write { db in try AppSettingsStore.set(db, key: Self.key, value: record) }
    }
}
