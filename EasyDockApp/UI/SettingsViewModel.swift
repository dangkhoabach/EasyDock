import EasyDockCore
import Foundation
import Observation

/// Backs the Scheduled Cleanup and System Alerts sections of Settings.
@MainActor
@Observable
final class SettingsViewModel {
    static let shared = SettingsViewModel(
        database: AppDatabase.shared,
        requestNotificationAuthorization: { Task { await NotificationManager.shared.requestAuthorization() } }
    )

    /// Nil only when the database failed to open — the startup alert covers
    /// that case, so every action here just no-ops rather than repeating the
    /// complaint.
    private let database: AppDatabase?
    private let requestNotificationAuthorization: @MainActor () -> Void
    private var isLoaded = false

    /// Saved on every change rather than debounced: it is a handful of keys,
    /// and nothing is left waiting for a quit to discard.
    var settings: AppSettings = .defaults {
        didSet {
            guard isLoaded, oldValue != settings else { return }
            if let database {
                try? SettingsRepository(dbQueue: database.dbQueue).update(settings)
            }
            if Self.startsSendingNotifications(from: oldValue, to: settings) {
                requestNotificationAuthorization()
            }
        }
    }

    /// What the scheduler last did on the user's behalf. Read whenever the
    /// page opens, not observed: it changes in the background a few times a
    /// day at most, and a stale figure for the length of one visit is fine.
    var lastCleanupRun: SchedulerStateStore.CleanupRun?
    var signalBarImportDate: Date?

    init(database: AppDatabase?, requestNotificationAuthorization: @escaping @MainActor () -> Void) {
        self.database = database
        self.requestNotificationAuthorization = requestNotificationAuthorization
    }

    func loadIfNeeded() {
        guard !isLoaded else { return }
        settings = database.flatMap { try? SettingsRepository(dbQueue: $0.dbQueue).load() } ?? .defaults
        signalBarImportDate = database.flatMap { try? SignalBarSettingsImporter.importDate(in: $0.dbQueue) }
        isLoaded = true
        refreshLastRun()
    }

    func refreshLastRun() {
        lastCleanupRun = database.flatMap { try? SchedulerStateStore(dbQueue: $0.dbQueue).lastCleanupRun() }
    }

    /// Notifications are asked for at the moment the user turns on something
    /// that sends them, so the macOS prompt has context instead of appearing
    /// at launch. There is no in-app switch: macOS's answer is the switch.
    static func startsSendingNotifications(from old: AppSettings, to new: AppSettings) -> Bool {
        (!old.cleanupScheduleEnabled && new.cleanupScheduleEnabled)
            || (old.systemTempAlertThresholdCelsius == 0 && new.systemTempAlertThresholdCelsius > 0)
            || (old.batteryLowAlertThresholdPercent == 0 && new.batteryLowAlertThresholdPercent > 0)
    }
}
