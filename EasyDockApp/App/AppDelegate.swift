import AppKit
import EasyDockCore

/// AppKit glue SwiftUI scenes don't expose: apply the theme, start the
/// updater, keep running with no window open, and reopen the window from the
/// Dock icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        ThemePreference.apply()
        if let failure = AppDatabase.openFailure {
            presentDatabaseFailure(failure)
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
