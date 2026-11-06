import AppKit
import SwiftUI

/// Brings the main window forward with a Dock icon, the same sequence for the
/// launch, a Dock-icon reopen and the menu bar items.
@MainActor
enum WindowPresenter {
    static let mainWindowID = "main"
    /// SwiftUI's own way to open the main window, kept by the Extract
    /// window: the one window there is when an archive started the app.
    static var openWindow: OpenWindowAction?

    static func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        if mainWindows(in: NSApp.windows).isEmpty {
            openWindow?(id: mainWindowID)
        }
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

    /// The main window ordered out, with no Dock icon, as `LSUIElement` has it.
    static func hideMainWindow() {
        for window in mainWindows(in: NSApp.windows) {
            window.orderOut(nil)
        }
        NSApp.setActivationPolicy(.accessory)
    }

    static func showSettings() {
        showMainWindow()
        AppNavigationState.shared.sidebarSelection = .settings
    }
}
