import EasyDockCore

/// The single running `Scheduler` for the app's lifetime and the loop that
/// ticks it, started from `AppDelegate.applicationDidFinishLaunching`.
///
/// A `Task.sleep`-based loop rather than a `Timer`/`DispatchSourceTimer`:
/// each iteration sleeps a fixed duration *after* finishing its work, so
/// there's nothing to "catch up" on after the process was suspended by
/// system sleep — no burst of back-to-back ticks on wake.
///
/// `@MainActor`: constructing it touches `NotificationManager.shared`, which
/// is main-actor-isolated.
@MainActor
enum AppScheduler {
    static let shared: Scheduler? = AppDatabase.shared.map { db in
        Scheduler(
            dbQueue: db.dbQueue,
            notifier: NotificationManager.shared,
            statsProvider: SystemStatsService(),
            cleanupRunner: ScheduledCleanupRunner(service: JunkCleanerService()),
            alertText: LocalizedAlertText()
        )
    }

    private static var loopTask: Task<Void, Never>?

    static func start() {
        guard loopTask == nil, let scheduler = shared else { return }
        loopTask = Task {
            while !Task.isCancelled {
                await scheduler.tick()
                try? await Task.sleep(nanoseconds: Scheduler.tickIntervalSecs * 1_000_000_000)
            }
        }
    }
}
