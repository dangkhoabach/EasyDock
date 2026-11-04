import Foundation
import GRDB
import Testing
@testable import EasyDockCore

@Suite struct SettingsRepositoryTests {
    private func makeRepo() throws -> SettingsRepository {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        return SettingsRepository(dbQueue: app.dbQueue)
    }

    /// Every field must survive a write followed by a read.
    ///
    /// `load` and `update` each spell out the same `app_settings` keys by
    /// hand, in two separate lists. One typo on either side is invisible —
    /// the write lands under a key nothing reads, and the setting silently
    /// reverts to its default the next time the app starts. Round-tripping
    /// values that are all distinct from the defaults is what makes such a
    /// mismatch fail here.
    @Test func everySettingSurvivesARoundTrip() throws {
        let repo = try makeRepo()
        let settings = AppSettings(
            cleanupScheduleEnabled: true,
            cleanupFrequency: "monthly",
            cleanupDayOfWeek: 4,
            cleanupDayOfMonth: 17,
            cleanupTargetPaths: "/tmp/a\n/tmp/b",
            systemTempAlertThresholdCelsius: 85,
            batteryLowAlertThresholdPercent: 15,
            dockClickEnabled: false,
            dockClickAction: .hide,
            dockClickExcludedApps: ["com.example.one", "com.example.two"],
            switcherEnabled: false,
            switcherShortcut: .optionTab,
            switcherScope: .currentDesktop,
            switcherThumbnails: false,
            clipboardEnabled: false,
            clipboardMaxItems: 123,
            clipboardMaxDays: 7,
            clipboardExcludedApps: ["com.example.vault"],
            clipboardPasteDirectly: false,
            keepAwakeMinutes: 60,
            keepAwakeAllowDisplaySleep: true,
            keepAwakeBatteryMinimumPercent: 35,
            keepAwakeApps: ["com.example.render", "com.example.slides"],
            colorPickerFormat: .swiftUI
        )
        try repo.update(settings)
        #expect(try repo.load() == settings)
    }

    @Test func aFreshDatabaseLoadsTheDefaults() throws {
        #expect(try makeRepo().load() == AppSettings.defaults)
    }
}
