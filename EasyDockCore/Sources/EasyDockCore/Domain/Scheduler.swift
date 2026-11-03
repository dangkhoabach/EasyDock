import Foundation
import GRDB

/// One background cycle: records the System tab's history, raises the system
/// temperature/battery alerts on state transitions and runs the scheduled
/// cleanup when it is due.
///
/// The app calls `tick()` on a fixed interval and again on wake; this type
/// owns no loop of its own.
public actor Scheduler {
    public static let tickIntervalSecs: UInt64 = 15

    private let settingsRepo: SettingsRepository
    private let stateStore: SchedulerStateStore
    private let historyStore: SystemHistoryStore
    private var averager = SystemSampleAverager()
    private let notifier: NotificationSending
    private let alertText: AlertTextLocalizing
    private let statsProvider: SystemStatsProvider?
    /// Nil in tests that don't exercise cleanup, and in any host that has no
    /// AppKit — a nil runner means the scheduler simply never cleans, which
    /// is the correct fallback for a file-deleting job.
    private let cleanupRunner: CleanupRunning?

    /// The scheduled cleanup in progress, if any. Kept out of `tick()`
    /// because measuring and trashing caches can take minutes, and the tick
    /// is what checks the system alerts — see `maybeRunScheduledCleanup`.
    private var cleanupTask: Task<Void, Never>?
    /// Guards `tick()` against re-entering while a previous run is suspended
    /// — see the comment on `tick()` itself.
    private var tickInFlight = false

    public init(
        dbQueue: DatabaseQueue,
        notifier: NotificationSending,
        statsProvider: SystemStatsProvider? = nil,
        cleanupRunner: CleanupRunning? = nil,
        alertText: AlertTextLocalizing = EnglishAlertText()
    ) {
        self.settingsRepo = SettingsRepository(dbQueue: dbQueue)
        self.stateStore = SchedulerStateStore(dbQueue: dbQueue)
        self.historyStore = SystemHistoryStore(dbQueue: dbQueue)
        self.notifier = notifier
        self.statsProvider = statsProvider
        // No production default: cleanup deletes files, so it runs only
        // where a host has explicitly wired it up.
        self.cleanupRunner = cleanupRunner
        self.alertText = alertText
    }

    /// Waits for work that `tick()` deliberately hands off rather than
    /// awaits — today only the scheduled cleanup. Internal, for tests.
    func waitForBackgroundWork() async {
        await cleanupTask?.value
    }

    /// Runs one cycle immediately — used both by the app's periodic loop and
    /// by its `NSWorkspace.didWakeNotification` handler (Core has no AppKit
    /// dependency, so it can't observe that notification itself).
    public func tick(now: Date = Date()) async {
        // Actors are reentrant, and this method suspends — on taking a stats
        // snapshot, on posting a notification. The app also calls it a second
        // time from `NSWorkspace.didWakeNotification`, which is exactly when
        // the periodic loop is likely to be mid-tick.
        //
        // Both runs would then clear the same check-then-set gates before
        // either closed them: `alertFlag()` before `setAlertFlag`, and the
        // user got a duplicate temperature alert. One guard here covers every
        // such gate inside the cycle, rather than one flag per gate.
        //
        // Skipping is the right answer for a wake-up tick: its job is to stop
        // the loop waiting out the rest of an interval, and a tick already
        // running has that covered.
        guard !tickInFlight else { return }
        tickInFlight = true
        defer { tickInFlight = false }

        // One light reading a tick serves both: it costs a few system calls
        // and no process spawns.
        if let stats = await statsProvider?.snapshotLight() {
            recordHistory(stats, at: now)
            await checkSystemAlerts(stats)
        }
        await maybeRunScheduledCleanup()
    }

    // MARK: - Scheduled cleanup

    /// Runs the user's chosen cleanup targets at most once per scheduled
    /// period.
    ///
    /// Three separate things have to be true before a single file moves, and
    /// they are kept separate on purpose: the schedule must be on, the saved
    /// selection must still match targets this build offers, and each of
    /// those targets must be Trash-safe. A selection saved by an older build
    /// is re-filtered here on every run rather than trusted, so nothing an
    /// unattended run touches depends on what was written to the database
    /// months ago.
    private func maybeRunScheduledCleanup() async {
        guard cleanupTask == nil,
              let cleanupRunner, let settings = try? settingsRepo.load(), settings.cleanupScheduleEnabled
        else { return }

        let period = SchedulerStateStore.schedulePeriod(
            frequency: settings.cleanupFrequency,
            dayOfWeek: settings.cleanupDayOfWeek,
            dayOfMonth: settings.cleanupDayOfMonth
        )
        guard period.isDueToday, (try? stateStore.lastCleanupPeriod()) != period.periodIdentifier else { return }

        let selected = Set(settings.cleanupTargetPaths.split(separator: "\n").map(String.init))
        guard !selected.isEmpty else { return }

        let targets = JunkTarget.scheduledCleaningTargets(
            from: selected, available: await cleanupRunner.availableTargets()
        )
        guard !targets.isEmpty else { return }

        // Marked before the work, not after: a clean that crashes or is
        // killed partway must not re-run on the next 15-second tick and start
        // deleting again.
        try? stateStore.markCleanupRun(period: period.periodIdentifier)

        // Handed off rather than awaited. Measuring and trashing a few cache
        // trees can take minutes, and `tick()` is what checks the system
        // alerts — holding it would silence the temperature and battery
        // alerts for the whole run. The period is already marked, so a tick
        // arriving meanwhile cannot start a second run; `cleanupTask` only
        // guards the moment between marking and reading the mark back.
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            await self.runScheduledCleanup(targets, with: cleanupRunner)
            await self.finishCleanupTask()
        }
    }

    private func runScheduledCleanup(_ targets: [JunkTarget], with runner: CleanupRunning) async {
        let result = await runner.clean(targets)
        try? stateStore.recordCleanupRun(
            .init(at: Date(), bytes: result.bytes, locations: targets.count, skipped: result.skipped)
        )

        // Always announced. An unattended job that moves gigabytes to the
        // Trash without saying so is exactly the kind of silent behaviour
        // this feature must not have.
        let freed = ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file)
        await notify(
            .cleanupFinished(freed: freed, locations: targets.count, skipped: result.skipped),
            route: "/cleanup"
        )
    }

    private func finishCleanupTask() {
        cleanupTask = nil
    }

    // MARK: - History

    private func recordHistory(_ stats: SystemStats, at now: Date) {
        guard let sample = averager.add(stats, at: now) else { return }
        try? historyStore.append(sample)
    }

    // MARK: - System alerts

    private func checkSystemAlerts(_ stats: SystemStats) async {
        guard let settings = try? settingsRepo.load() else { return }
        guard settings.systemTempAlertThresholdCelsius > 0 || settings.batteryLowAlertThresholdPercent > 0 else { return }

        if settings.systemTempAlertThresholdCelsius > 0, let temp = stats.cpuTempCelsius {
            let isHot = temp >= Double(settings.systemTempAlertThresholdCelsius)
            let wasActive = (try? stateStore.alertFlag("system_temp_alert_active")) ?? false
            if isHot && !wasActive {
                await notify(.systemHot(celsius: Int(temp), thresholdCelsius: settings.systemTempAlertThresholdCelsius), route: "/system")
                try? stateStore.setAlertFlag("system_temp_alert_active", true)
            } else if !isHot && wasActive {
                try? stateStore.setAlertFlag("system_temp_alert_active", false)
            }
        }

        if settings.batteryLowAlertThresholdPercent > 0, let percent = stats.batteryPercent {
            let charging = stats.batteryCharging ?? false
            let isLow = !charging && percent <= Double(settings.batteryLowAlertThresholdPercent)
            let wasActive = (try? stateStore.alertFlag("system_battery_alert_active")) ?? false
            if isLow && !wasActive {
                await notify(.batteryLow(percent: Int(percent)), route: "/system")
                try? stateStore.setAlertFlag("system_battery_alert_active", true)
            } else if (!isLow || charging) && wasActive {
                try? stateStore.setAlertFlag("system_battery_alert_active", false)
            }
        }
    }

    /// The single funnel every alert goes through. There is no in-app switch
    /// for notifications: whether one is shown is macOS's permission, asked
    /// for when the user turns on a feature that sends them.
    private func notify(_ message: AlertMessage, route: String?) async {
        let (title, body) = alertText.text(for: message)
        await notifier.notify(title: title, body: body, route: route)
    }
}
