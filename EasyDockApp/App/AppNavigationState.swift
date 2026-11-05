import Observation

/// Sidebar selection, shared between `ContentView` and whatever opens a tab
/// from outside the window: the menu items (Settings…) and a click on a
/// notification (`NotificationManager`'s routes, wired in `AppDelegate`).
@MainActor
@Observable
final class AppNavigationState {
    static let shared = AppNavigationState()

    var sidebarSelection: SidebarSection = .dockWindows

    private init() {}

    func handleNotificationRoute(_ route: String) {
        let removedApp = "/cleanup/uninstall/"
        if route.hasPrefix(removedApp) {
            sidebarSelection = .cleanup
            Task { await CleanupViewModel.shared.showLeftovers(ofRemoved: String(route.dropFirst(removedApp.count))) }
            return
        }
        switch route {
        case "/system": sidebarSelection = .system
        case "/cleanup": sidebarSelection = .cleanup
        default: break
        }
    }
}
