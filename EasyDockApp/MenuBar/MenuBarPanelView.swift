import SwiftUI

/// The menu bar panel: header, tab bar, the selected tab, and a footer with
/// the app-level actions. A fixed size, so switching tabs never makes the
/// panel jump under the pointer.
struct MenuBarPanelView: View {
    static let size = CGSize(width: 360, height: 500)

    @AppStorage("languagePreference") private var languageRaw = AppLocale.systemDefault.rawValue

    var body: some View {
        // The panel is not part of a SwiftUI scene, so the in-app language is
        // applied here rather than inherited.
        MenuBarPanelContent()
            .environment(\.locale, (AppLocale(rawValue: languageRaw) ?? .systemDefault).locale)
            .frame(width: Self.size.width, height: Self.size.height)
    }
}

private struct MenuBarPanelContent: View {
    @Bindable private var navigation = MenuBarNavigation.shared
    private let preferences = MenuBarPreferences.shared
    @Bindable private var settings = SettingsViewModel.shared
    private let permissions = Permissions.shared
    private let keepAwake = KeepAwakeController.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            quickToggles
            tabBar
            Divider()
            Group {
                switch navigation.tab {
                case .overview: OverviewTab()
                case .clipboard: ClipboardTab()
                case .cleanup: CleanupTab()
                case .system: SystemTab()
                case .tools: ToolsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack {
            Text(verbatim: "EasyDock").font(.headline)
            Spacer()
            if !permissions.allGranted {
                Button {
                    WindowPresenter.showSettings()
                } label: {
                    Label("Permissions needed", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .help("Open Settings › Permissions")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// One switch per feature that exists so far; each later feature adds its own.
    private var quickToggles: some View {
        HStack(spacing: 6) {
            QuickToggle(
                title: "Dock",
                systemImage: "dock.arrow.down.rectangle",
                isOn: settings.settings.dockClickEnabled,
                needsAttention: !permissions.accessibility || StageManager.shared.isOn,
                help: StageManager.shared.isOn
                    ? "Off while Stage Manager is on: macOS doesn't let other apps minimize windows."
                    : "Click a Dock icon to minimize the app in front"
            ) {
                settings.settings.dockClickEnabled.toggle()
            }
            QuickToggle(
                title: settings.settings.switcherShortcut == .commandTab ? "⌘Tab" : "⌥Tab",
                systemImage: "rectangle.on.rectangle",
                isOn: settings.settings.switcherEnabled,
                needsAttention: !permissions.accessibility,
                help: "Show every window when switching"
            ) {
                settings.settings.switcherEnabled.toggle()
            }
            QuickToggle(
                title: "Clipboard",
                systemImage: "doc.on.clipboard",
                isOn: settings.settings.clipboardEnabled,
                needsAttention: ClipboardStore.shared.failure != nil,
                help: "Record copies in the clipboard history"
            ) {
                settings.settings.clipboardEnabled.toggle()
            }
            QuickToggle(
                title: "Awake",
                systemImage: "cup.and.saucer",
                isOn: keepAwake.session != nil,
                needsAttention: false,
                help: "Keep the Mac awake"
            ) {
                keepAwake.toggleSession()
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(preferences.tabOrder.enumerated()), id: \.element) { index, tab in
                let selected = navigation.tab == tab
                Button {
                    navigation.tab = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.systemImage).font(.system(size: 14))
                        Text(tab.title).font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .background(selected ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var footer: some View {
        HStack(spacing: 2) {
            footerButton("Show EasyDock", systemImage: "macwindow") { WindowPresenter.showMainWindow() }
            footerButton("Settings…", systemImage: "gearshape") { WindowPresenter.showSettings() }
            footerButton("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") { AppUpdater.checkForUpdates() }
            Spacer()
            footerButton("Quit EasyDock", systemImage: "power") { UserQuit.quit() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func footerButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
    }
}

/// A feature's on/off switch in the panel: filled while on, with an orange
/// dot while something keeps it from working (a missing permission, Stage
/// Manager); the tooltip says which.
private struct QuickToggle: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isOn: Bool
    let needsAttention: Bool
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(isOn ? Color.accentColor : Color.secondary.opacity(0.15), in: Capsule())
                .overlay(alignment: .topTrailing) {
                    if isOn && needsAttention {
                        Circle().fill(.orange).frame(width: 7, height: 7).offset(x: 1, y: -1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Each at its own width: four switches fit, but the row would
        // otherwise share it out evenly and wrap the longest title.
        .fixedSize()
        .help(help)
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
    }
}

/// Opens a tab of the main window from the panel.
@MainActor
func showMainWindowTab(_ section: SidebarSection) {
    WindowPresenter.showMainWindow()
    AppNavigationState.shared.sidebarSelection = section
}

// MARK: - Tabs

private struct ClipboardTab: View {
    var body: some View {
        ClipboardListView { StatusBarController.shared.closePanel() }
    }
}
