import Observation

/// Sidebar selection, shared between `ContentView` and the menu items that
/// open a tab from outside the window (Settings…).
@MainActor
@Observable
final class AppNavigationState {
    static let shared = AppNavigationState()

    var sidebarSelection: SidebarSection = .dockWindows

    private init() {}
}
