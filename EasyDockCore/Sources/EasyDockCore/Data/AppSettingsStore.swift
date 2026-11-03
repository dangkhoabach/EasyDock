import Foundation
import GRDB

/// Key/value access to `app_settings`, the same shape SignalBar uses, so the
/// settings it hands over arrive under the same keys.
public enum AppSettingsStore {
    public static func get(_ db: Database, key: String, default defaultValue: String) throws -> String {
        try String.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = ?", arguments: [key]) ?? defaultValue
    }

    public static func set(_ db: Database, key: String, value: String) throws {
        try db.execute(
            sql: """
                INSERT INTO app_settings (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            arguments: [key, value]
        )
    }
}
