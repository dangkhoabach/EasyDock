import AppKit
import EasyDockCore

/// Quitting from EasyDock's own menus and buttons: a Keep Awake session
/// ends with it. Any other quit lets the session carry on when EasyDock
/// starts again in the same boot.
@MainActor
enum UserQuit {
    static func quit() {
        KeepAwakeController.shared.stopSession()
        NSApp.terminate(nil)
    }
}

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
        ClipboardStore.shared.start()
        KeepAwakeController.shared.start()
        ColorPickerController.shared.start()
        AlwaysOnTopController.shared.start()
        AppRemovalWatcher.shared.start()
        DropZoneController.shared.start()
        QuickConvertController.shared.start()
        MemoryReliefController.shared.start()
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
        // Opened at login, EasyDock stays in the menu bar: the window SwiftUI
        // creates a turn later opens hidden. Otherwise `LSUIElement` keeps
        // the app out of the Dock until that window brings the icon back.
        if LoginItemManager.wasOpenedAtLogin() {
            NSApp.hide(nil)
        } else if ExtractController.shared.hasWindow || CompressController.shared.hasWindow {
            // Opened by a double-click on an archive, or by Finder's Services
            // menu to compress: only that window.
            DispatchQueue.main.async { WindowPresenter.hideMainWindow() }
        } else {
            DispatchQueue.main.async { WindowPresenter.showMainWindow() }
        }
    }

    /// Archives double-clicked in Finder or opened with EasyDock. At launch
    /// this comes before `applicationDidFinishLaunching`.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        ExtractController.shared.open(files)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowPresenter.showMainWindow()
        // Already handled: with the closed window ordered out, AppKit's own
        // reopen would have the `WindowGroup` make a second window.
        return false
    }

    /// Says plainly that settings can't be kept, and where the file it
    /// couldn't open lives.
    private func presentDatabaseFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        let bundle = AppLocale.bundle
        alert.messageText = String(localized: "EasyDock can't open its database", bundle: bundle)
        alert.informativeText = String(localized: "Settings can't be saved until this is fixed.", bundle: bundle)
            + "\n\n\(error.localizedDescription)\n\n"
            + String(localized: "The database is at:", bundle: bundle)
            + "\n\(AppDatabaseLocation.productionPath().path)"
        alert.addButton(withTitle: String(localized: "Continue Anyway", bundle: bundle))
        alert.addButton(withTitle: String(localized: "Show in Finder", bundle: bundle))
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([AppDatabaseLocation.productionPath()])
        }
    }
}
