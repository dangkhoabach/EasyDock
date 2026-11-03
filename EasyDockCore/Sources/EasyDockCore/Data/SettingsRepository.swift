import Foundation
import GRDB

/// EasyDock's settings in `app_settings`. The cleanup and alert keys are the
/// same as SignalBar's, with its defaults, so values imported from it read
/// back unchanged.
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
    /// A click on the Dock icon of the app in front minimizes it. On by
    /// default: it is the feature the app is named for, and it does nothing
    /// until Accessibility is allowed.
    public var dockClickEnabled: Bool
    public var dockClickAction: DockClickPreference
    /// Bundle identifiers whose Dock icon keeps the macOS behaviour.
    public var dockClickExcludedApps: [String]
    /// Every window on the switcher's shortcut instead of one icon per app.
    public var switcherEnabled: Bool
    public var switcherShortcut: SwitcherShortcut
    /// Window pictures in the switcher; they need Screen Recording.
    public var switcherThumbnails: Bool

    public static let defaults = AppSettings(
        cleanupScheduleEnabled: false,
        cleanupFrequency: "weekly",
        cleanupDayOfWeek: 0,
        cleanupDayOfMonth: 1,
        cleanupTargetPaths: "",
        systemTempAlertThresholdCelsius: 0,
        batteryLowAlertThresholdPercent: 0,
        dockClickEnabled: true,
        dockClickAction: .minimize,
        dockClickExcludedApps: [],
        switcherEnabled: true,
        switcherShortcut: .commandTab,
        switcherThumbnails: true
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
                batteryLowAlertThresholdPercent: try int("battery_low_alert_threshold_percent", d.batteryLowAlertThresholdPercent),
                dockClickEnabled: try AppSettingsStore.get(db, key: "dock_click_enabled", default: "1") == "1",
                dockClickAction: DockClickPreference(rawValue: try AppSettingsStore.get(db, key: "dock_click_action", default: d.dockClickAction.rawValue)) ?? d.dockClickAction,
                dockClickExcludedApps: try AppSettingsStore.get(db, key: "dock_click_excluded_apps", default: "")
                    .split(separator: "\n").map(String.init),
                switcherEnabled: try AppSettingsStore.get(db, key: "switcher_enabled", default: "1") == "1",
                switcherShortcut: SwitcherShortcut(rawValue: try AppSettingsStore.get(db, key: "switcher_shortcut", default: d.switcherShortcut.rawValue)) ?? d.switcherShortcut,
                switcherThumbnails: try AppSettingsStore.get(db, key: "switcher_thumbnails", default: "1") == "1"
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
            try AppSettingsStore.set(db, key: "dock_click_enabled", value: settings.dockClickEnabled ? "1" : "0")
            try AppSettingsStore.set(db, key: "dock_click_action", value: settings.dockClickAction.rawValue)
            try AppSettingsStore.set(db, key: "dock_click_excluded_apps", value: settings.dockClickExcludedApps.joined(separator: "\n"))
            try AppSettingsStore.set(db, key: "switcher_enabled", value: settings.switcherEnabled ? "1" : "0")
            try AppSettingsStore.set(db, key: "switcher_shortcut", value: settings.switcherShortcut.rawValue)
            try AppSettingsStore.set(db, key: "switcher_thumbnails", value: settings.switcherThumbnails ? "1" : "0")
        }
    }
}

/// The key that opens the window switcher while ⌘ or ⌥ is held.
public enum SwitcherShortcut: String, Sendable, CaseIterable {
    /// Replaces the system's app switcher.
    case commandTab
    /// Leaves ⌘Tab to the system.
    case optionTab
}
