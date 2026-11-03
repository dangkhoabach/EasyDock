import AppKit
import EasyDockCore

/// AppKit glue SwiftUI scenes don't expose: apply the theme, start the
/// updater and the background work, keep running with no window open, and
/// reopen the window from the Dock icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemePreference.apply()
        if let failure = AppDatabase.openFailure {
            presentDatabaseFailure(failure)
        }
        // Before the scheduler's first tick, so an imported schedule (and the
        // period SignalBar last cleaned in) is what that tick sees. A failed
        // read is tried again on the next launch.
        if let db = AppDatabase.shared {
            _ = try? SignalBarSettingsImporter.importIfNeeded(from: SignalBarSettingsImporter.defaultSourcePath(), into: db.dbQueue)
        }

        StatusBarController.shared.start()
        AppActivationHistory.shared.start()
        DockClickController.shared.start()
        WindowFocusHistory.shared.start()
        SwitcherController.shared.start()
        NotificationManager.shared.onRouteSelected = { route in
            AppNavigationState.shared.handleNotificationRoute(route)
        }
        AppScheduler.start()
        // The loop sleeps a fixed interval between ticks, so a sleep/wake
        // cycle leaves it waiting out the rest of that interval — this forces
        // an immediate catch-up tick the moment the Mac wakes. Core has no
        // AppKit dependency, so it can't observe this notification itself.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { await AppScheduler.shared?.tick() }
        }

        _ = AppUpdater.shared   // starts Sparkle's scheduled check (the controller is lazy)
        // `LSUIElement` keeps the app out of the Dock; the window SwiftUI
        // opens at launch is created a turn later and brings the icon back.
        DispatchQueue.main.async { WindowPresenter.showMainWindow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowPresenter.showMainWindow()
        return true
    }

    /// Says plainly that settings can't be kept, and where the file it
    /// couldn't open lives.
    private func presentDatabaseFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "EasyDock can't open its database"
        alert.informativeText = """
            Settings can't be saved until this is fixed.

            \(error.localizedDescription)

            The database is at:
            \(AppDatabaseLocation.productionPath().path)
            """
        alert.addButton(withTitle: "Continue Anyway")
        alert.addButton(withTitle: "Show in Finder")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([AppDatabaseLocation.productionPath()])
        }
    }
}
