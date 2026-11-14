import SwiftUI

/// Sidebar + content, styled like the sibling apps: unselected row icons
/// dimmed, and focus handed back to the sidebar after every switch so its
/// selection keeps the accent colour instead of the inactive grey.
struct ContentView: View {
    @Bindable private var navigationState = AppNavigationState.shared
    @FocusState private var sidebarFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(
                get: { navigationState.sidebarSelection },
                set: { if let newValue = $0 { navigationState.sidebarSelection = newValue } }
            )) {
                ForEach(SidebarSection.groups, id: \.sections) { group in
                    Section {
                        ForEach(group.sections) { section in
                            Label {
                                Text(section.title)
                            } icon: {
                                Image(systemName: section.systemImage)
                                    .foregroundStyle(section == navigationState.sidebarSelection ? Color.primary : Color.secondary)
                            }
                            .tag(section)
                        }
                    } header: {
                        Text(group.title)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarSettingsRow(isSelected: navigationState.sidebarSelection == .settings) {
                    navigationState.sidebarSelection = .settings
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .focused($sidebarFocused)
        } detail: {
            switch navigationState.sidebarSelection {
            case .settings:
                SettingsView()
            case .dockWindows:
                DockWindowsView()
            case .snap:
                SnapView()
            case .clipboard:
                ClipboardSettingsView()
            case .tools:
                ToolsView()
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

