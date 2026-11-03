import Foundation
import GRDB

/// Opens (or creates) the app's SQLite database and keeps it migrated.
public struct AppDatabase: Sendable {
    public let dbQueue: DatabaseQueue

    public init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
    }

    /// In-memory database for tests and previews.
    public init(inMemory: DatabaseQueue) throws {
        dbQueue = inMemory
        try Self.migrator.migrate(dbQueue)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_appSettings") { db in
            try db.execute(sql: """
                CREATE TABLE app_settings (
                    key TEXT PRIMARY KEY NOT NULL,
                    value TEXT NOT NULL
                )
                """)
        }
        migrator.registerMigration("v2_clipboardItems") { db in
            try db.execute(sql: """
                CREATE TABLE clipboard_items (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    last_used REAL NOT NULL,
                    source_app TEXT,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    byte_count INTEGER NOT NULL,
                    identity TEXT NOT NULL UNIQUE,
                    preview BLOB NOT NULL,
                    content BLOB NOT NULL
                );
                CREATE INDEX clipboard_items_order ON clipboard_items (pinned, last_used);
                """)
        }
        migrator.registerMigration("v3_systemSamples") { db in
            try db.execute(sql: """
                CREATE TABLE system_samples (
                    time REAL PRIMARY KEY NOT NULL,
                    cpu REAL NOT NULL,
                    memory REAL NOT NULL,
                    temperature REAL
                )
                """)
        }
        return migrator
    }
}
