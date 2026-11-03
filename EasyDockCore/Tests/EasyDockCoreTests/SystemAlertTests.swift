import Foundation
import GRDB
import Testing
@testable import EasyDockCore

private actor RecordingNotifier: NotificationSending {
    private(set) var notifications: [(title: String, body: String, route: String?)] = []
    func notify(title: String, body: String, route: String?) async {
        notifications.append((title, body, route))
    }
}

/// Parks the first `notify` until released, so a test can start a second
/// tick while the first one is suspended mid-alert.
///
/// Only the first call parks. A second one returns straight away and is
/// counted — if the guard under test regresses, this fails on the count
/// instead of deadlocking two parked callers against a single release.
private actor SuspendingNotifier: NotificationSending {
    private(set) var notifications: [String] = []
    private var resume: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var hasParked = false

    func notify(title: String, body: String, route: String?) async {
        notifications.append(title)
        started?.resume()
        started = nil
        guard !hasParked else { return }
        hasParked = true
        await withCheckedContinuation { resume = $0 }
    }

    func waitUntilNotifying() async {
        guard notifications.isEmpty else { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        resume?.resume()
        resume = nil
    }
}

private struct StaticStatsProvider: SystemStatsProvider {
    let value: SystemStats
    func snapshot() async -> SystemStats { value }
}

/// The temperature and battery alerts fire on the transition into the
/// condition only, and re-arm once it clears.
@Suite struct SystemAlertTests {
    private func makeDatabase(_ configure: (inout AppSettings) -> Void) throws -> AppDatabase {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        var settings = AppSettings.defaults
        configure(&settings)
        try SettingsRepository(dbQueue: app.dbQueue).update(settings)
        return app
    }

    @Test func tickFiresSystemTempAlertOnceThenClearsWhenCooled() async throws {
        let app = try makeDatabase { $0.systemTempAlertThresholdCelsius = 80 }

        let notifier = RecordingNotifier()
        let hotScheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier,
            statsProvider: StaticStatsProvider(value: SystemStats(cpuTempCelsius: 90))
        )
        await hotScheduler.tick()
        await hotScheduler.tick() // still hot: must not alert again

        let afterHot = await notifier.notifications
        #expect(afterHot.count == 1)
        #expect(afterHot[0].title == "Your Mac is running hot")
        #expect(afterHot[0].route == "/system")

        let coolScheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier,
            statsProvider: StaticStatsProvider(value: SystemStats(cpuTempCelsius: 50))
        )
        await coolScheduler.tick() // clears the flag, no new alert
        await hotScheduler.tick() // hot again: flag was cleared, must alert again

        let afterCycle = await notifier.notifications
        #expect(afterCycle.count == 2)
    }

    @Test func tickFiresBatteryLowAlertOnceThenClearsWhenCharging() async throws {
        let app = try makeDatabase { $0.batteryLowAlertThresholdPercent = 20 }

        let notifier = RecordingNotifier()
        let low = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier,
            statsProvider: StaticStatsProvider(value: SystemStats(batteryPercent: 15, batteryCharging: false))
        )
        await low.tick()
        await low.tick() // still low: must not alert again

        let afterLow = await notifier.notifications
        #expect(afterLow.count == 1)
        #expect(afterLow[0].title == "Battery low")
        #expect(afterLow[0].body == "15% left — plug in the charger")

        // Plugged in: still at 15%, but charging is not "low", and it re-arms.
        let charging = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier,
            statsProvider: StaticStatsProvider(value: SystemStats(batteryPercent: 15, batteryCharging: true))
        )
        await charging.tick()
        #expect(await notifier.notifications.count == 1)

        await low.tick() // unplugged again: alerts again
        #expect(await notifier.notifications.count == 2)
    }

    @Test func aThresholdOfZeroNeverAlerts() async throws {
        let app = try makeDatabase { _ in }

        let notifier = RecordingNotifier()
        let scheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier,
            statsProvider: StaticStatsProvider(value: SystemStats(cpuTempCelsius: 120, batteryPercent: 1, batteryCharging: false))
        )
        await scheduler.tick()

        #expect(await notifier.notifications.isEmpty)
    }

    /// What `tickInFlight` is actually for: the system-alert flags are a
    /// read-then-write around an `await`, with nothing else guarding them.
    /// Two reentrant ticks both read "not yet alerted" and both notified, so
    /// a wake-from-sleep during a hot spell produced a duplicate alert.
    @Test func aSecondTickDuringAnAlertDoesNotRaiseItTwice() async throws {
        let app = try makeDatabase { $0.systemTempAlertThresholdCelsius = 80 }

        let notifier = SuspendingNotifier()
        let scheduler = Scheduler(
            dbQueue: app.dbQueue, notifier: notifier,
            statsProvider: StaticStatsProvider(value: SystemStats(cpuTempCelsius: 95))
        )

        let first = Task { await scheduler.tick() }
        await notifier.waitUntilNotifying()
        await scheduler.tick()

        await notifier.release()
        await first.value

        #expect(await notifier.notifications.count == 1)
    }
}
