import Foundation
import GRDB
import Testing
@testable import EasyDockCore

@Suite struct SchedulerStateStoreTests {
    private func makeStore() throws -> SchedulerStateStore {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        return SchedulerStateStore(dbQueue: app.dbQueue)
    }

    @Test func alertFlagRoundTrips() throws {
        let store = try makeStore()
        #expect(try store.alertFlag("system_temp_alert_active") == false)
        try store.setAlertFlag("system_temp_alert_active", true)
        #expect(try store.alertFlag("system_temp_alert_active") == true)
        try store.setAlertFlag("system_temp_alert_active", false)
        #expect(try store.alertFlag("system_temp_alert_active") == false)
    }

    @Test func dailyScheduleIsAlwaysDue() {
        let period = SchedulerStateStore.schedulePeriod(frequency: "daily", dayOfWeek: 1, dayOfMonth: 1)
        #expect(period.isDueToday)
    }

    @Test func weeklyScheduleIsDueOnlyOnConfiguredWeekday() {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = Date()
        let weekday = calendar.component(.weekday, from: today)
        let todayFromMonday = (weekday + 5) % 7

        let matching = SchedulerStateStore.schedulePeriod(frequency: "weekly", dayOfWeek: todayFromMonday, dayOfMonth: 1, now: today)
        #expect(matching.isDueToday)

        let nonMatching = SchedulerStateStore.schedulePeriod(frequency: "weekly", dayOfWeek: (todayFromMonday + 1) % 7, dayOfMonth: 1, now: today)
        #expect(!nonMatching.isDueToday)
    }

    @Test func monthlyScheduleIsDueOnlyOnConfiguredDay() {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = Date()
        let dayOfMonth = calendar.component(.day, from: today)

        let matching = SchedulerStateStore.schedulePeriod(frequency: "monthly", dayOfWeek: 0, dayOfMonth: dayOfMonth, now: today)
        #expect(matching.isDueToday)

        let nonMatching = SchedulerStateStore.schedulePeriod(frequency: "monthly", dayOfWeek: 0, dayOfMonth: dayOfMonth == 1 ? 2 : 1, now: today)
        #expect(!nonMatching.isDueToday)
    }

    /// The identifiers must stay the ones SignalBar writes, or an imported
    /// `last_cleanup_period` would no longer guard the period it came from.
    @Test func periodIdentifiersKeepSignalBarsFormat() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12)))

        #expect(SchedulerStateStore.schedulePeriod(frequency: "daily", dayOfWeek: 0, dayOfMonth: 1, now: date).periodIdentifier == "2026-11-03")
        #expect(SchedulerStateStore.schedulePeriod(frequency: "weekly", dayOfWeek: 0, dayOfMonth: 1, now: date).periodIdentifier == "2026-W45")
        #expect(SchedulerStateStore.schedulePeriod(frequency: "monthly", dayOfWeek: 0, dayOfMonth: 1, now: date).periodIdentifier == "2026-11")
    }
}
