import Foundation

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
