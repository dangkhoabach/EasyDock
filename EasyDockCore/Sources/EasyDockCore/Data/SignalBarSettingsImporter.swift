import Foundation
import GRDB

/// Brings the cleanup schedule and the system-alert thresholds over from
/// SignalBar, which had these features before EasyDock did, so someone
/// switching apps does not have to set them up again.
///
/// Runs once per install, whether or not SignalBar's database is there:
/// importing later would overwrite whatever the user has since chosen here.
/// SignalBar's file is opened read-only and never written to.
public enum SignalBarSettingsImporter {
    /// Every key `SettingsRepository` reads, plus the period guard of the
    /// last scheduled cleanup — without it, a cleanup SignalBar already ran
    /// this week would run again on EasyDock's first tick.
    static let importedKeys: Set<String> = [
        "cleanup_schedule_enabled", "cleanup_frequency", "cleanup_day_of_week", "cleanup_day_of_month",
        "cleanup_target_paths", "system_temp_alert_threshold_celsius", "battery_low_alert_threshold_percent",
        "last_cleanup_period",
    ]
    static let doneKey = "signalbar_import_done"
    static let importedAtKey = "signalbar_import_at"

    /// Where SignalBar keeps its database (it still uses its original
    /// bundle identifier).
    public static func defaultSourcePath() -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("com.dangkhoabach.dkb-monitor/dkb-monitor.db").path
    }

    /// Copies every imported key SignalBar has into `dbQueue`'s
    /// `app_settings`, and returns how many there were. Does nothing once
    /// an earlier call has finished. A source that exists but can't be read
    /// throws, and is tried again on the next launch.
    @discardableResult
    public static func importIfNeeded(from sourcePath: String, into dbQueue: DatabaseQueue, now: Date = Date()) throws -> Int {
        let done = try dbQueue.read { db in try AppSettingsStore.get(db, key: doneKey, default: "0") == "1" }
        guard !done else { return 0 }

        var values: [String: String] = [:]
        if FileManager.default.fileExists(atPath: sourcePath) {
            var configuration = Configuration()
            configuration.readonly = true
            let source = try DatabaseQueue(path: sourcePath, configuration: configuration)
            values = try source.read { db in
                guard try db.tableExists("app_settings") else { return [:] }
                var found: [String: String] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT key, value FROM app_settings") {
                    let key: String = row["key"]
                    if importedKeys.contains(key) { found[key] = row["value"] }
                }
                return found
            }
            try source.close()
        }

        try dbQueue.write { db in
            for (key, value) in values {
                try AppSettingsStore.set(db, key: key, value: value)
            }
            if !values.isEmpty {
                try AppSettingsStore.set(db, key: importedAtKey, value: String(now.timeIntervalSince1970))
            }
            try AppSettingsStore.set(db, key: doneKey, value: "1")
        }
        return values.count
    }

    /// When settings were imported, for the Settings page; `nil` when
    /// nothing was.
    public static func importDate(in dbQueue: DatabaseQueue) throws -> Date? {
        let raw = try dbQueue.read { db in try AppSettingsStore.get(db, key: importedAtKey, default: "") }
        return Double(raw).map(Date.init(timeIntervalSince1970:))
    }
}
