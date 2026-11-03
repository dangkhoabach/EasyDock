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
        return migrator
    }
}
