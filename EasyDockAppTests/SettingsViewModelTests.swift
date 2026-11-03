import GRDB
import Testing
@testable import EasyDockCore
@testable import EasyDock

@MainActor
private final class AuthorizationRequests {
    var count = 0
}

@MainActor
@Suite struct SettingsViewModelTests {
    private func makeModel() throws -> (SettingsViewModel, AppDatabase, AuthorizationRequests) {
        let database = try AppDatabase(inMemory: DatabaseQueue())
        let requests = AuthorizationRequests()
        let model = SettingsViewModel(database: database, requestNotificationAuthorization: { requests.count += 1 })
        model.loadIfNeeded()
        return (model, database, requests)
    }

    /// Saved as it changes, so a change made right before quitting is not
    /// lost to a pending write.
    @Test func aChangeIsSavedImmediately() throws {
        let (model, database, _) = try makeModel()

        model.settings.cleanupDayOfMonth = 12

        #expect(try SettingsRepository(dbQueue: database.dbQueue).load().cleanupDayOfMonth == 12)
    }

    /// Turning on the schedule, or raising a threshold from 0, is the moment
    /// to ask macOS; other edits are not.
    @Test func notificationsAreAskedForOnlyWhenSomethingStartsSendingThem() throws {
        let (model, _, requests) = try makeModel()

        model.settings.cleanupFrequency = "daily"
        model.settings.cleanupScheduleEnabled = true
        model.settings.systemTempAlertThresholdCelsius = 90
        model.settings.systemTempAlertThresholdCelsius = 85
        model.settings.batteryLowAlertThresholdPercent = 10

        #expect(requests.count == 3)
    }

    @Test func turningThingsOffAsksForNothing() {
        var on = AppSettings.defaults
        on.cleanupScheduleEnabled = true
        on.systemTempAlertThresholdCelsius = 90
        on.batteryLowAlertThresholdPercent = 10

        #expect(!SettingsViewModel.startsSendingNotifications(from: on, to: .defaults))
        #expect(SettingsViewModel.startsSendingNotifications(from: .defaults, to: on))
    }
}

@MainActor
@Suite struct AppNavigationStateTests {
    @Test func notificationRoutesOpenTheirTab() {
        let state = AppNavigationState.shared
        let original = state.sidebarSelection
        defer { state.sidebarSelection = original }

        state.handleNotificationRoute("/system")
        #expect(state.sidebarSelection == .system)

        state.handleNotificationRoute("/cleanup")
        #expect(state.sidebarSelection == .cleanup)

        state.handleNotificationRoute("/unknown")
        #expect(state.sidebarSelection == .cleanup)
    }
}
