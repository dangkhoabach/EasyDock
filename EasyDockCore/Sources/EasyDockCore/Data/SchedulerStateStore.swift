import Foundation
import GRDB

/// Scheduler bookkeeping kept in `app_settings`: the scheduled-cleanup period
/// guard, the last run's outcome, and the system-wide (temp/battery) alert
/// active-flags. Same keys as SignalBar, so the state it hands over keeps
/// its meaning here.
public struct SchedulerStateStore: Sendable {
    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// True the first time a system-wide condition (temp/battery) crosses its
    /// threshold; stays true until `setAlertFlag` clears it — "alert on
    /// transition only".
    public func alertFlag(_ key: String) throws -> Bool {
        try dbQueue.read { db in try AppSettingsStore.get(db, key: key, default: "0") == "1" }
    }

    public func setAlertFlag(_ key: String, _ active: Bool) throws {
        try dbQueue.write { db in try AppSettingsStore.set(db, key: key, value: active ? "1" : "0") }
    }

    // MARK: - Schedule period

    public struct SchedulePeriod: Sendable, Equatable {
        public let isDueToday: Bool
        /// Doubles as the dedupe key — its format changes with frequency, so
        /// switching frequency naturally invalidates any stale guard left
        /// over from a different cadence instead of needing separate keys.
        public let periodIdentifier: String
    }

    /// Exact ISO-week numbering isn't load-bearing here — `periodIdentifier`
    /// only needs to change once per period and stay stable within it, which
    /// `Calendar`'s week components already guarantee. The identifiers match
    /// SignalBar's, so an imported `last_cleanup_period` still guards the
    /// period it was written in.
    public static func schedulePeriod(frequency: String, dayOfWeek: Int, dayOfMonth: Int, now: Date = Date()) -> SchedulePeriod {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        switch frequency {
        case "daily":
            return SchedulePeriod(isDueToday: true, periodIdentifier: dayFormatter.string(from: now))
        case "weekly":
            // Monday = 0 ... Sunday = 6.
            let weekday = calendar.component(.weekday, from: now) // Sunday = 1 ... Saturday = 7
            let daysFromMonday = (weekday + 5) % 7
            let week = calendar.component(.weekOfYear, from: now)
            let year = calendar.component(.yearForWeekOfYear, from: now)
            return SchedulePeriod(
                isDueToday: daysFromMonday == dayOfWeek,
                periodIdentifier: String(format: "%04d-W%02d", year, week)
            )
        default:
            let day = calendar.component(.day, from: now)
            return SchedulePeriod(
                isDueToday: day == dayOfMonth,
                periodIdentifier: monthFormatter.string(from: now)
            )
        }
    }

    // MARK: - Scheduled cleanup

    /// Uses `schedulePeriod`'s identifier vocabulary, so "already ran this
    /// week" has exactly one meaning in the scheduler.
    public func lastCleanupPeriod() throws -> String {
        try dbQueue.read { db in try AppSettingsStore.get(db, key: "last_cleanup_period", default: "") }
    }

    public func markCleanupRun(period: String) throws {
        try dbQueue.write { db in try AppSettingsStore.set(db, key: "last_cleanup_period", value: period) }
    }

    // MARK: - Last outcome, for the Settings page

    /// What the last scheduled cleanup did. Kept so the Settings page can say
    /// so even with notifications off: an unattended job that moves the
    /// user's files must leave a trace they can find without one.
    public struct CleanupRun: Sendable, Equatable {
        public let at: Date
        public let bytes: Int64
        public let locations: Int
        public let skipped: [String]

        public init(at: Date, bytes: Int64, locations: Int, skipped: [String]) {
            self.at = at
            self.bytes = bytes
            self.locations = locations
            self.skipped = skipped
        }
    }

    public func lastCleanupRun() throws -> CleanupRun? {
        try dbQueue.read { db in
            guard let seconds = Double(try AppSettingsStore.get(db, key: "last_cleanup_run_at", default: "")) else { return nil }
            let skipped = try AppSettingsStore.get(db, key: "last_cleanup_run_skipped", default: "")
            return CleanupRun(
                at: Date(timeIntervalSince1970: seconds),
                bytes: Int64(try AppSettingsStore.get(db, key: "last_cleanup_run_bytes", default: "0")) ?? 0,
                locations: Int(try AppSettingsStore.get(db, key: "last_cleanup_run_locations", default: "0")) ?? 0,
                skipped: skipped.isEmpty ? [] : skipped.components(separatedBy: "\n")
            )
        }
    }

    public func recordCleanupRun(_ run: CleanupRun) throws {
        try dbQueue.write { db in
            try AppSettingsStore.set(db, key: "last_cleanup_run_at", value: String(run.at.timeIntervalSince1970))
            try AppSettingsStore.set(db, key: "last_cleanup_run_bytes", value: String(run.bytes))
            try AppSettingsStore.set(db, key: "last_cleanup_run_locations", value: String(run.locations))
            try AppSettingsStore.set(db, key: "last_cleanup_run_skipped", value: run.skipped.joined(separator: "\n"))
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}
