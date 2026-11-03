import SwiftUI

/// Sidebar + content, styled like the sibling apps: unselected row icons
/// dimmed, and focus handed back to the sidebar after every switch so its
/// selection keeps the accent colour instead of the inactive grey.
struct ContentView: View {
    @Bindable private var navigationState = AppNavigationState.shared
    @FocusState private var sidebarFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: Binding(
                get: { navigationState.sidebarSelection },
                set: { if let newValue = $0 { navigationState.sidebarSelection = newValue } }
            )) { section in
                Label {
                    Text(section.title)
                } icon: {
                    Image(systemName: section.systemImage)
                        .foregroundStyle(section == navigationState.sidebarSelection ? Color.primary : Color.secondary)
                }
                .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .focused($sidebarFocused)
        } detail: {
            switch navigationState.sidebarSelection {
            case .settings:
                SettingsView()
            case .dockWindows:
                DockWindowsView()
            case .clipboard:
                ClipboardSettingsView()
            case .system:
                SystemView()
            case .cleanup:
                CleanupView()
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onAppear { sidebarFocused = true }
        .onChange(of: navigationState.sidebarSelection) { _, _ in sidebarFocused = true }
    }
}

