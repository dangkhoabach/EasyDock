import AppKit
import EasyDockCore
import SwiftUI
import UniformTypeIdentifiers

/// The Dock & Windows tab: the Dock click and the apps left out of it.
struct DockWindowsView: View {
    @Bindable private var viewModel = SettingsViewModel.shared
    private let permissions = Permissions.shared
    private let stageManager = StageManager.shared

    var body: some View {
        Form {
            Section {
                Toggle("Click a Dock icon to minimize the app in front", isOn: $viewModel.settings.dockClickEnabled)
                Picker("A click on the app in front", selection: $viewModel.settings.dockClickAction) {
                    Text("Minimizes its windows").tag(DockClickPreference.minimize)
                    Text("Hides the app").tag(DockClickPreference.hide)
                }
                .disabled(!viewModel.settings.dockClickEnabled)
                Text("Click the icon again to bring every window back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if viewModel.settings.dockClickEnabled && stageManager.isOn {
                    Label("Stage Manager is on, so Dock clicks are left to macOS: it doesn't let other apps minimize windows. Turn Stage Manager off in Control Center to use this.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if viewModel.settings.dockClickEnabled && !permissions.accessibility {
                    HStack {
                        Label("This needs the Accessibility permission.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Allow…") { permissions.requestAccessibility() }
                    }
                }
            } header: {
                Text("Dock")
            }

            Section {
                ForEach(viewModel.settings.dockClickExcludedApps, id: \.self) { bundleID in
                    HStack {
                        appLabel(bundleID)
                        Spacer()
                        Button {
                            viewModel.settings.dockClickExcludedApps.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove")
                    }
                }
                Button("Add App…", action: addExcludedApp)
            } header: {
                Text("Apps That Keep the Usual Dock Click")
            }

            Section("Window Switcher") {
                Text("Showing every window on ⌘Tab comes in a later version of EasyDock.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            viewModel.loadIfNeeded()
            stageManager.refresh()
        }
    }

    @ViewBuilder
    private func appLabel(_ bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Label {
                Text(FileManager.default.displayName(atPath: url.path))
            } icon: {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
            }
        } else {
            // Uninstalled since: the identifier is all there is to show.
            Text(verbatim: bundleID).foregroundStyle(.secondary)
        }
    }

    private func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier, !viewModel.settings.dockClickExcludedApps.contains(bundleID) {
                viewModel.settings.dockClickExcludedApps.append(bundleID)
            }
        }
    }
}
