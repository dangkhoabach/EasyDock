import SwiftUI

/// One grouped `Form` with a `Section` per topic, like the sibling apps'
/// Settings pages. Every change applies at once.
struct SettingsView: View {
    @AppStorage(ThemePreference.key) private var themeRaw = ThemePreference.system.rawValue
    @AppStorage("languagePreference") private var languageRaw = AppLocale.systemDefault.rawValue
    @State private var loginItemEnabled = LoginItemManager.shared.isEnabled
    @State private var loginItemNeedsApproval = LoginItemManager.shared.requiresApproval
    @State private var loginItemError: String?
    /// Mirrors Sparkle's own preference for display only; `onAppear` reads it
    /// again because Sparkle's prompt can change it after the view was built.
    @State private var automaticUpdateChecks = AppUpdater.automaticallyChecksForUpdates
    private let permissions = Permissions.shared

    var body: some View {
        Form {
            Section {
                permissionRow(
                    "Accessibility",
                    detail: "Lets EasyDock minimize apps from the Dock, switch windows and paste from the clipboard history.",
                    granted: permissions.accessibility,
                    request: permissions.requestAccessibility
                )
                permissionRow(
                    "Screen Recording",
                    detail: "Used only for window thumbnails in the switcher. Nothing is recorded or saved.",
                    granted: permissions.screenRecording,
                    request: permissions.requestScreenRecording
                )
            } header: {
                Text("Permissions")
            } footer: {
                if !permissions.allGranted {
                    Text("After you allow it in System Settings, macOS may ask to quit and reopen EasyDock.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $themeRaw) {
                    ForEach(ThemePreference.allCases) { theme in
                        Text(theme.label).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Language", selection: Binding(
                    get: { AppLocale(rawValue: languageRaw) ?? .systemDefault },
                    set: { languageRaw = $0.rawValue }
                )) {
                    Text(verbatim: "VI").tag(AppLocale.vi)
                    Text(verbatim: "EN").tag(AppLocale.en)
                }
                .pickerStyle(.segmented)
            }

            Section("General") {
                Toggle("Launch at Login", isOn: Binding(get: { loginItemEnabled }, set: { setLoginItem($0) }))
                if loginItemNeedsApproval {
                    Label("Waiting for your approval in System Settings › General › Login Items. Until then EasyDock won't start at login.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { automaticUpdateChecks },
                    set: {
                        automaticUpdateChecks = $0
                        AppUpdater.automaticallyChecksForUpdates = $0
                    }
                ))
                Text("Checks updates.dangkhoabach.vn once a day. Turning this off means updates only happen when you ask for them.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Check Now") { AppUpdater.checkForUpdates() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            automaticUpdateChecks = AppUpdater.automaticallyChecksForUpdates
            permissions.refresh()
        }
        .onChange(of: themeRaw) { _, _ in ThemePreference.apply() }
    }

    private func permissionRow(
        _ title: LocalizedStringKey, detail: LocalizedStringKey, granted: Bool, request: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if granted {
                Text("Allowed").foregroundStyle(.secondary)
            } else {
                Button("Allow…", action: request)
            }
        }
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                loginItemNeedsApproval = try LoginItemManager.shared.enable()
            } else {
                try LoginItemManager.shared.disable()
                loginItemNeedsApproval = false
            }
            loginItemEnabled = LoginItemManager.shared.isEnabled
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            loginItemEnabled = LoginItemManager.shared.isEnabled
        }
    }
}
