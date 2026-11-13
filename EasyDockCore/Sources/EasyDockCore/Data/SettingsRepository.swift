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
    /// Windows from every desktop, or only from the desktops on screen.
    public var switcherScope: SwitcherScope
    /// Window pictures in the switcher; they need Screen Recording.
    public var switcherThumbnails: Bool
    /// The clipboard history records what is copied.
    public var clipboardEnabled: Bool
    public var clipboardMaxItems: Int
    /// Unpinned items older than this many days go; 0 keeps them.
    public var clipboardMaxDays: Int
    /// Bundle identifiers whose copies are never recorded.
    public var clipboardExcludedApps: [String]
    /// Choosing an item pastes it into the app in front; off, it is only copied.
    public var clipboardPasteDirectly: Bool
    /// How long a Keep Awake session started from the menu bar or the
    /// shortcut lasts, in minutes; 0 is until turned off.
    public var keepAwakeMinutes: Int
    /// Keep only the Mac awake and let the display sleep.
    public var keepAwakeAllowDisplaySleep: Bool
    /// Unplugged at or below this percentage, nothing keeps the Mac awake. 0 turns it off.
    public var keepAwakeBatteryMinimumPercent: Int
    /// Bundle identifiers that keep the Mac awake while they run.
    public var keepAwakeApps: [String]
    /// How a picked color is copied; the others are a right-click away.
    public var colorPickerFormat: ColorFormat
    /// A notification when an app is removed and leaves files in `~/Library`.
    public var removedAppAlerts: Bool
    /// Shaking the pointer while dragging a file opens the Drop Zone.
    public var dropZoneShake: Bool
    /// Dragging a file onto the notch, or the middle of a screen's top edge, opens the Drop Zone.
    public var dropZoneTopEdge: Bool
    /// Quick Convert's last choices, offered again next time.
    public var convertImageFormat: ImageFormat
    /// Longest side in pixels; 0 keeps the size.
    public var convertMaxDimension: Int
    /// 1…100, for every format but PNG.
    public var convertQuality: Int
    /// Camera, location and other details travel with the picture.
    public var convertKeepMetadata: Bool
    public var convertVideoPreset: VideoPreset
    /// A notification naming the heaviest unused apps when macOS runs short of memory.
    public var memoryPressureAlerts: Bool
    /// Bundle identifier to minutes unused before the app is quit.
    public var quitIdleApps: [String: Int]
    /// An archive, every part of it, goes to the Trash once extracted.
    public var extractTrashArchives: Bool
    /// Compress's last choices, offered again next time. Never the password.
    public var compressFormat: CompressFormat
    public var compressLevel: CompressLevel
    /// Bytes in each part; 0 doesn't split.
    public var compressPartSize: Int
    /// Several items make one archive each instead of one together.
    public var compressEachItem: Bool
    /// Window Snapping's shortcuts. On by default, like the Dock click: they
    /// do nothing until Accessibility is allowed.
    public var snapEnabled: Bool
    /// Dropping a window at a screen's edge snaps it. Off by default: macOS
    /// does the same out of the box, and with both on a window is placed twice.
    public var snapDragEnabled: Bool
    /// A snapped window dragged away gets its earlier size back.
    public var snapRestoreOnDrag: Bool
    /// Pressing a half or a quarter again makes it two thirds, then one third.
    public var snapCycleSizes: Bool
    /// Points between snapped windows and from the screen's edges.
    public var snapGap: Int
    /// What each edge zone does; a zone missing here does nothing.
    public var snapZones: [SnapZone: SnapTarget]
    /// Bundle identifiers whose windows are never snapped.
    public var snapExcludedApps: [String]

    /// Password managers and Apple's own password apps.
    public static let defaultClipboardExcludedApps = [
        "com.dangkhoabach.dkb-secret",      // KeyCellar
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
    ]

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
        switcherScope: .allDesktops,
        switcherThumbnails: true,
        clipboardEnabled: true,
        clipboardMaxItems: 500,
        clipboardMaxDays: 30,
        clipboardExcludedApps: AppSettings.defaultClipboardExcludedApps,
        clipboardPasteDirectly: true,
        keepAwakeMinutes: 0,
        keepAwakeAllowDisplaySleep: false,
        keepAwakeBatteryMinimumPercent: 20,
        keepAwakeApps: [],
        colorPickerFormat: .hex,
        removedAppAlerts: true,
        dropZoneShake: true,
        dropZoneTopEdge: true,
        convertImageFormat: .webp,
        convertMaxDimension: 0,
        convertQuality: 85,
        convertKeepMetadata: false,
        convertVideoPreset: .mp4Copy,
        memoryPressureAlerts: true,
        quitIdleApps: [:],
        extractTrashArchives: false,
        compressFormat: .zip,
        compressLevel: .balanced,
        compressPartSize: 0,
        compressEachItem: false,
        snapEnabled: true,
        snapDragEnabled: false,
        snapRestoreOnDrag: true,
        snapCycleSizes: true,
        snapGap: 0,
        snapZones: SnapZones.defaults,
        snapExcludedApps: []
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
                switcherScope: SwitcherScope(rawValue: try AppSettingsStore.get(db, key: "switcher_scope", default: d.switcherScope.rawValue)) ?? d.switcherScope,
                switcherThumbnails: try AppSettingsStore.get(db, key: "switcher_thumbnails", default: "1") == "1",
                clipboardEnabled: try AppSettingsStore.get(db, key: "clipboard_enabled", default: "1") == "1",
                clipboardMaxItems: try int("clipboard_max_items", d.clipboardMaxItems),
                clipboardMaxDays: try int("clipboard_max_days", d.clipboardMaxDays),
                clipboardExcludedApps: try AppSettingsStore.get(db, key: "clipboard_excluded_apps", default: d.clipboardExcludedApps.joined(separator: "\n"))
                    .split(separator: "\n").map(String.init),
                clipboardPasteDirectly: try AppSettingsStore.get(db, key: "clipboard_paste_directly", default: "1") == "1",
                keepAwakeMinutes: try int("keep_awake_minutes", d.keepAwakeMinutes),
                keepAwakeAllowDisplaySleep: try AppSettingsStore.get(db, key: "keep_awake_allow_display_sleep", default: "0") == "1",
                keepAwakeBatteryMinimumPercent: try int("keep_awake_battery_minimum_percent", d.keepAwakeBatteryMinimumPercent),
                keepAwakeApps: try AppSettingsStore.get(db, key: "keep_awake_apps", default: "")
                    .split(separator: "\n").map(String.init),
                colorPickerFormat: ColorFormat(rawValue: try AppSettingsStore.get(db, key: "color_picker_format", default: d.colorPickerFormat.rawValue)) ?? d.colorPickerFormat,
                removedAppAlerts: try AppSettingsStore.get(db, key: "removed_app_alerts", default: "1") == "1",
                dropZoneShake: try AppSettingsStore.get(db, key: "drop_zone_shake", default: "1") == "1",
                dropZoneTopEdge: try AppSettingsStore.get(db, key: "drop_zone_top_edge", default: "1") == "1",
                convertImageFormat: ImageFormat(rawValue: try AppSettingsStore.get(db, key: "convert_image_format", default: d.convertImageFormat.rawValue)) ?? d.convertImageFormat,
                convertMaxDimension: try int("convert_max_dimension", d.convertMaxDimension),
                convertQuality: try int("convert_quality", d.convertQuality),
                convertKeepMetadata: try AppSettingsStore.get(db, key: "convert_keep_metadata", default: "0") == "1",
                convertVideoPreset: VideoPreset(rawValue: try AppSettingsStore.get(db, key: "convert_video_preset", default: d.convertVideoPreset.rawValue)) ?? d.convertVideoPreset,
                memoryPressureAlerts: try AppSettingsStore.get(db, key: "memory_pressure_alerts", default: "1") == "1",
                quitIdleApps: IdleQuit.decode(try AppSettingsStore.get(db, key: "quit_idle_apps", default: "")),
                extractTrashArchives: try AppSettingsStore.get(db, key: "extract_trash_archives", default: "0") == "1",
                compressFormat: CompressFormat(rawValue: try AppSettingsStore.get(db, key: "compress_format", default: d.compressFormat.rawValue)) ?? d.compressFormat,
                compressLevel: CompressLevel(rawValue: try AppSettingsStore.get(db, key: "compress_level", default: d.compressLevel.rawValue)) ?? d.compressLevel,
                compressPartSize: try int("compress_part_size", d.compressPartSize),
                compressEachItem: try AppSettingsStore.get(db, key: "compress_each_item", default: "0") == "1",
                snapEnabled: try AppSettingsStore.get(db, key: "snap_enabled", default: "1") == "1",
                snapDragEnabled: try AppSettingsStore.get(db, key: "snap_drag_enabled", default: "0") == "1",
                snapRestoreOnDrag: try AppSettingsStore.get(db, key: "snap_restore_on_drag", default: "1") == "1",
                snapCycleSizes: try AppSettingsStore.get(db, key: "snap_cycle_sizes", default: "1") == "1",
                snapGap: min(max(try int("snap_gap", d.snapGap), 0), 30),
                snapZones: SnapZones.decode(try AppSettingsStore.get(db, key: "snap_zones", default: "")),
                snapExcludedApps: try AppSettingsStore.get(db, key: "snap_excluded_apps", default: "")
                    .split(separator: "\n").map(String.init)
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
            try AppSettingsStore.set(db, key: "switcher_scope", value: settings.switcherScope.rawValue)
            try AppSettingsStore.set(db, key: "switcher_thumbnails", value: settings.switcherThumbnails ? "1" : "0")
            try AppSettingsStore.set(db, key: "clipboard_enabled", value: settings.clipboardEnabled ? "1" : "0")
            try AppSettingsStore.set(db, key: "clipboard_max_items", value: String(settings.clipboardMaxItems))
            try AppSettingsStore.set(db, key: "clipboard_max_days", value: String(settings.clipboardMaxDays))
            try AppSettingsStore.set(db, key: "clipboard_excluded_apps", value: settings.clipboardExcludedApps.joined(separator: "\n"))
            try AppSettingsStore.set(db, key: "clipboard_paste_directly", value: settings.clipboardPasteDirectly ? "1" : "0")
            try AppSettingsStore.set(db, key: "keep_awake_minutes", value: String(settings.keepAwakeMinutes))
            try AppSettingsStore.set(db, key: "keep_awake_allow_display_sleep", value: settings.keepAwakeAllowDisplaySleep ? "1" : "0")
            try AppSettingsStore.set(db, key: "keep_awake_battery_minimum_percent", value: String(settings.keepAwakeBatteryMinimumPercent))
            try AppSettingsStore.set(db, key: "keep_awake_apps", value: settings.keepAwakeApps.joined(separator: "\n"))
            try AppSettingsStore.set(db, key: "color_picker_format", value: settings.colorPickerFormat.rawValue)
            try AppSettingsStore.set(db, key: "removed_app_alerts", value: settings.removedAppAlerts ? "1" : "0")
            try AppSettingsStore.set(db, key: "drop_zone_shake", value: settings.dropZoneShake ? "1" : "0")
            try AppSettingsStore.set(db, key: "drop_zone_top_edge", value: settings.dropZoneTopEdge ? "1" : "0")
            try AppSettingsStore.set(db, key: "convert_image_format", value: settings.convertImageFormat.rawValue)
            try AppSettingsStore.set(db, key: "convert_max_dimension", value: String(settings.convertMaxDimension))
            try AppSettingsStore.set(db, key: "convert_quality", value: String(settings.convertQuality))
            try AppSettingsStore.set(db, key: "convert_keep_metadata", value: settings.convertKeepMetadata ? "1" : "0")
            try AppSettingsStore.set(db, key: "convert_video_preset", value: settings.convertVideoPreset.rawValue)
            try AppSettingsStore.set(db, key: "memory_pressure_alerts", value: settings.memoryPressureAlerts ? "1" : "0")
            try AppSettingsStore.set(db, key: "quit_idle_apps", value: IdleQuit.encode(settings.quitIdleApps))
            try AppSettingsStore.set(db, key: "extract_trash_archives", value: settings.extractTrashArchives ? "1" : "0")
            try AppSettingsStore.set(db, key: "compress_format", value: settings.compressFormat.rawValue)
            try AppSettingsStore.set(db, key: "compress_level", value: settings.compressLevel.rawValue)
            try AppSettingsStore.set(db, key: "compress_part_size", value: String(settings.compressPartSize))
            try AppSettingsStore.set(db, key: "compress_each_item", value: settings.compressEachItem ? "1" : "0")
            try AppSettingsStore.set(db, key: "snap_enabled", value: settings.snapEnabled ? "1" : "0")
            try AppSettingsStore.set(db, key: "snap_drag_enabled", value: settings.snapDragEnabled ? "1" : "0")
            try AppSettingsStore.set(db, key: "snap_restore_on_drag", value: settings.snapRestoreOnDrag ? "1" : "0")
            try AppSettingsStore.set(db, key: "snap_cycle_sizes", value: settings.snapCycleSizes ? "1" : "0")
            try AppSettingsStore.set(db, key: "snap_gap", value: String(settings.snapGap))
            try AppSettingsStore.set(db, key: "snap_zones", value: SnapZones.encode(settings.snapZones))
            try AppSettingsStore.set(db, key: "snap_excluded_apps", value: settings.snapExcludedApps.joined(separator: "\n"))
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

/// Which windows the switcher lists.
public enum SwitcherScope: String, Sendable, CaseIterable {
    case allDesktops
    /// The desktop on each display, plus full-screen apps; see `SwitcherSpaces`.
    case currentDesktop
}
