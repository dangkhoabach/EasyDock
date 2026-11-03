import SwiftUI

/// The menu bar icon: a warning triangle while a permission is missing, so
/// the problem shows without opening the menu.
struct MenuBarIconView: View {
    private let permissions = Permissions.shared

    var body: some View {
        Image(systemName: permissions.allGranted ? "dock.rectangle" : "exclamationmark.triangle")
    }
}

/// The menu bar dropdown, a SwiftUI panel (`.menuBarExtraStyle(.window)`)
/// laid out like the sibling apps': header, state, then full-width rows.
struct MenuBarContentView: View {
    private let permissions = Permissions.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "EasyDock").font(.headline)
            if !permissions.allGranted {
                Label("EasyDock needs permissions to work.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                menuButton("Show EasyDock", systemImage: "macwindow") { WindowPresenter.showMainWindow() }
                menuButton("Settings…", systemImage: "gearshape") { WindowPresenter.showSettings() }
                menuButton("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") { AppUpdater.checkForUpdates() }
                menuButton("Quit EasyDock", systemImage: "power") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 280)
        // Opening the dropdown does not activate the app.
        .onAppear { permissions.refresh() }
    }

    private func menuButton(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .padding(.horizontal, 5)
        .background(.quaternary.opacity(0.001), in: RoundedRectangle(cornerRadius: 5))
    }
}
