import Foundation
import GRDB
import Testing
@testable import EasyDockCore

@Suite struct SignalBarSettingsImporterTests {
    /// A stand-in for SignalBar's database: only the `app_settings` table,
    /// which is all the importer reads.
    private func makeSource(_ values: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("signalbar-\(UUID().uuidString).db")
        let source = try DatabaseQueue(path: url.path)
        try source.write { db in
            try db.execute(sql: "CREATE TABLE app_settings (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL)")
            for (key, value) in values {
                try db.execute(sql: "INSERT INTO app_settings (key, value) VALUES (?, ?)", arguments: [key, value])
            }
        }
        try source.close()
        return url
    }

    private func makeTarget() throws -> AppDatabase {
        try AppDatabase(inMemory: DatabaseQueue())
    }

    @Test func importsTheKeysThatArePresentAndNothingElse() throws {
        let source = try makeSource([
            "cleanup_schedule_enabled": "1",
            "cleanup_frequency": "monthly",
            "cleanup_target_paths": "/Users/example/Library/Caches\n/Users/example/Library/Logs",
            "system_temp_alert_threshold_celsius": "85",
            "last_cleanup_period": "2026-11",
            // SignalBar-only settings stay behind.
            "smtp_recipient_email": "ops@example.com",
            "webhook_enabled": "1",
        ])
        defer { try? FileManager.default.removeItem(at: source) }
        let target = try makeTarget()
        let importedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let count = try SignalBarSettingsImporter.importIfNeeded(from: source.path, into: target.dbQueue, now: importedAt)

        #expect(count == 5)
        let settings = try SettingsRepository(dbQueue: target.dbQueue).load()
        #expect(settings.cleanupScheduleEnabled)
        #expect(settings.cleanupFrequency == "monthly")
        #expect(settings.cleanupTargetPaths == "/Users/example/Library/Caches\n/Users/example/Library/Logs")
        #expect(settings.systemTempAlertThresholdCelsius == 85)
        // Absent in the source, so still EasyDock's default.
        #expect(settings.cleanupDayOfMonth == AppSettings.defaults.cleanupDayOfMonth)
        #expect(settings.batteryLowAlertThresholdPercent == 0)
        #expect(try SchedulerStateStore(dbQueue: target.dbQueue).lastCleanupPeriod() == "2026-11")
        #expect(try SignalBarSettingsImporter.importDate(in: target.dbQueue) == importedAt)
        let leaked = try target.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT key FROM app_settings WHERE key IN ('smtp_recipient_email', 'webhook_enabled')")
        }
        #expect(leaked.isEmpty)
    }

    @Test func aMissingSourceImportsNothingAndIsNotTriedAgain() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).db")
        let target = try makeTarget()

        #expect(try SignalBarSettingsImporter.importIfNeeded(from: missing.path, into: target.dbQueue) == 0)
        #expect(try SignalBarSettingsImporter.importDate(in: target.dbQueue) == nil)
        #expect(try SettingsRepository(dbQueue: target.dbQueue).load() == AppSettings.defaults)
        #expect(!FileManager.default.fileExists(atPath: missing.path))

        // SignalBar showing up later must not overwrite what was chosen here.
        let source = try makeSource(["cleanup_schedule_enabled": "1"])
        defer { try? FileManager.default.removeItem(at: source) }
        #expect(try SignalBarSettingsImporter.importIfNeeded(from: source.path, into: target.dbQueue) == 0)
        #expect(try SettingsRepository(dbQueue: target.dbQueue).load().cleanupScheduleEnabled == false)
    }

    @Test func runsOnlyOnce() throws {
        let source = try makeSource(["battery_low_alert_threshold_percent": "20"])
        defer { try? FileManager.default.removeItem(at: source) }
        let target = try makeTarget()
        let repo = SettingsRepository(dbQueue: target.dbQueue)

        #expect(try SignalBarSettingsImporter.importIfNeeded(from: source.path, into: target.dbQueue) == 1)
        var changed = try repo.load()
        changed.batteryLowAlertThresholdPercent = 35
        try repo.update(changed)

        #expect(try SignalBarSettingsImporter.importIfNeeded(from: source.path, into: target.dbQueue) == 0)
        #expect(try repo.load().batteryLowAlertThresholdPercent == 35)
    }

    @Test func neverModifiesTheSourceFile() throws {
        let source = try makeSource([
            "cleanup_schedule_enabled": "1",
            "cleanup_frequency": "daily",
            "last_cleanup_period": "2026-11-03",
        ])
        defer { try? FileManager.default.removeItem(at: source) }
        let before = try Data(contentsOf: source)
        let modifiedBefore = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date

        try SignalBarSettingsImporter.importIfNeeded(from: source.path, into: try makeTarget().dbQueue)

        #expect(try Data(contentsOf: source) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date == modifiedBefore)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(source.lastPathComponent + "-") }
        #expect(siblings.isEmpty, "a journal or WAL file was left next to the source")
    }
}
