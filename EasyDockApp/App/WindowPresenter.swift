import AppKit

/// Brings the main window forward with a Dock icon, the same sequence for the
/// launch, a Dock-icon reopen and the menu bar items.
@MainActor
enum WindowPresenter {
    static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        for window in mainWindows(in: NSApp.windows) {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Only the `WindowGroup` window, recognised by the delegate
    /// `WindowAccessor` gives it. `NSApp.windows` also holds the menu bar
    /// extra's panel; ordering that front opens the dropdown outside
    /// SwiftUI's own tracking, so it never closes.
    static func mainWindows(in windows: [NSWindow]) -> [NSWindow] {
        windows.filter { $0.delegate is HideInsteadOfCloseDelegate }
    }

    static func showSettings() {
        showMainWindow()
        AppNavigationState.shared.sidebarSelection = .settings
    }
}
