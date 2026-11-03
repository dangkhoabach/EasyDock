import Foundation
import GRDB

/// The settings the scheduler acts on. Same `app_settings` keys and defaults
/// as SignalBar, so values imported from it read back unchanged.
public struct AppSettings: Equatable, Sendable {
    /// Runs the Cleanup tab's selected targets on a schedule instead of only
    /// on a click. Off by default — this deletes files, so it is never
    /// something the user gets without asking.
    public var cleanupScheduleEnabled: Bool
    /// "daily" | "weekly" | "monthly".
    public var cleanupFrequency: String
    public var cleanupDayOfWeek: Int
    public var cleanupDayOfMonth: Int
    /// The selected targets' paths, newline-separated. Stored as paths rather
    /// than indexes so reordering or adding a target in a later build cannot
    /// silently repoint a saved selection at something else.
    public var cleanupTargetPaths: String
    /// CPU/SoC temperature (°C) that triggers a "running hot" alert. 0 disables it.
    public var systemTempAlertThresholdCelsius: Int
    /// Battery percentage (while unplugged) that triggers a "battery low" alert. 0 disables it.
    public var batteryLowAlertThresholdPercent: Int

    public static let defaults = AppSettings(
        cleanupScheduleEnabled: false,
        cleanupFrequency: "weekly",
        cleanupDayOfWeek: 0,
        cleanupDayOfMonth: 1,
        cleanupTargetPaths: "",
        systemTempAlertThresholdCelsius: 0,
        batteryLowAlertThresholdPercent: 0
    )
}

public struct SettingsRepository: Sendable {
    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func load() throws -> AppSettings {
        try dbQueue.read { db in
            let d = AppSettings.defaults
            func int(_ key: String, _ fallback: Int) throws -> Int {
                Int(try AppSettingsStore.get(db, key: key, default: String(fallback))) ?? fallback
            }
            return AppSettings(
                cleanupScheduleEnabled: try AppSettingsStore.get(db, key: "cleanup_schedule_enabled", default: "0") == "1",
                cleanupFrequency: try AppSettingsStore.get(db, key: "cleanup_frequency", default: d.cleanupFrequency),
                cleanupDayOfWeek: try int("cleanup_day_of_week", d.cleanupDayOfWeek),
                cleanupDayOfMonth: try int("cleanup_day_of_month", d.cleanupDayOfMonth),
                cleanupTargetPaths: try AppSettingsStore.get(db, key: "cleanup_target_paths", default: d.cleanupTargetPaths),
                systemTempAlertThresholdCelsius: try int("system_temp_alert_threshold_celsius", d.systemTempAlertThresholdCelsius),
                batteryLowAlertThresholdPercent: try int("battery_low_alert_threshold_percent", d.batteryLowAlertThresholdPercent)
            )
        }
    }

    public func update(_ settings: AppSettings) throws {
        try dbQueue.write { db in
            try AppSettingsStore.set(db, key: "cleanup_schedule_enabled", value: settings.cleanupScheduleEnabled ? "1" : "0")
            try AppSettingsStore.set(db, key: "cleanup_frequency", value: settings.cleanupFrequency)
            try AppSettingsStore.set(db, key: "cleanup_day_of_week", value: String(settings.cleanupDayOfWeek))
            try AppSettingsStore.set(db, key: "cleanup_day_of_month", value: String(settings.cleanupDayOfMonth))
            try AppSettingsStore.set(db, key: "cleanup_target_paths", value: settings.cleanupTargetPaths)
            try AppSettingsStore.set(db, key: "system_temp_alert_threshold_celsius", value: String(settings.systemTempAlertThresholdCelsius))
            try AppSettingsStore.set(db, key: "battery_low_alert_threshold_percent", value: String(settings.batteryLowAlertThresholdPercent))
        }
    }
}
