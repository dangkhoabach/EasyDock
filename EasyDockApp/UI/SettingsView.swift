import EasyDockCore
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
    @Bindable private var viewModel = SettingsViewModel.shared
    @Bindable private var menuBar = MenuBarPreferences.shared
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

            Section("Menu Bar") {
                Picker("Menu bar icon", selection: $menuBar.iconMode) {
                    ForEach(MenuBarIconMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                if let hotKeys = StatusBarController.shared.hotKeys {
                    HotKeyRecorderView(title: "Open the menu bar panel", action: .togglePanel, manager: hotKeys)
                }
                LabeledContent("Tab order") {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(Array(menuBar.tabOrder.enumerated()), id: \.element) { index, tab in
                            HStack(spacing: 6) {
                                Text(verbatim: "⌘\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                                Label(tab.title, systemImage: tab.systemImage)
                                    .frame(width: 130, alignment: .leading)
                                Button { menuBar.move(tab, by: -1) } label: { Image(systemName: "chevron.up") }
                                    .disabled(index == 0)
                                    .accessibilityLabel("Move up")
                                Button { menuBar.move(tab, by: 1) } label: { Image(systemName: "chevron.down") }
                                    .disabled(index == menuBar.tabOrder.count - 1)
                                    .accessibilityLabel("Move down")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Text("Right-click the icon for a short menu. In the panel, ⌘1 to ⌘5 switch tabs and Esc closes it.")
                    .font(.caption).foregroundStyle(.secondary)
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

            cleanupSection
            systemAlertsSection

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
            viewModel.loadIfNeeded()
            viewModel.refreshLastRun()
        }
        .onChange(of: themeRaw) { _, _ in ThemePreference.apply() }
    }

    @ViewBuilder
    private var cleanupSection: some View {
        Section {
            Toggle("Clean selected locations on a schedule", isOn: $viewModel.settings.cleanupScheduleEnabled)
            if viewModel.settings.cleanupScheduleEnabled {
                // Said plainly at the switch, not buried: this is the one
                // setting in the app that deletes the user's files while
                // they are not looking.
                Text("Everything is moved to the Trash, never deleted outright, and you get a notification when a run finishes. The Trash itself can't be emptied on a schedule.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let run = viewModel.lastCleanupRun {
                    let when = run.at.formatted(.relative(presentation: .named))
                    let moved = ByteCountFormatter.string(fromByteCount: run.bytes, countStyle: .file)
                    if run.skipped.isEmpty {
                        Label("Last run \(when): moved \(moved) to the Trash from \(run.locations) location(s).", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Last run \(when): moved \(moved) to the Trash. Not fully cleared: \(run.skipped.joined(separator: ", ")).", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Picker("Frequency", selection: $viewModel.settings.cleanupFrequency) {
                    Text("Daily").tag("daily")
                    Text("Weekly").tag("weekly")
                    Text("Monthly").tag("monthly")
                }
                if viewModel.settings.cleanupFrequency == "weekly" {
                    Picker("Day of Week", selection: $viewModel.settings.cleanupDayOfWeek) {
                        ForEach(0..<7, id: \.self) { daysFromMonday in
                            Text(Calendar.current.weekdaySymbols[(daysFromMonday + 1) % 7]).tag(daysFromMonday)
                        }
                    }
                } else if viewModel.settings.cleanupFrequency == "monthly" {
                    Stepper("Day of Month: \(viewModel.settings.cleanupDayOfMonth)", value: $viewModel.settings.cleanupDayOfMonth, in: 1...28)
                }
                cleanupTargetPicker
            }
        } header: {
            Text("Scheduled Cleanup")
        } footer: {
            if let date = viewModel.signalBarImportDate {
                Text("Imported from SignalBar on \(date, format: .dateTime.day().month().year()).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Only Trash-safe locations are listed. The Trash target is excluded by
    /// `isEligibleForScheduledCleaning` rather than filtered out by name here,
    /// so this list and what the scheduler will actually touch cannot drift
    /// apart.
    @ViewBuilder
    private var cleanupTargetPicker: some View {
        let selected = Set(viewModel.settings.cleanupTargetPaths.split(separator: "\n").map(String.init))
        let available = JunkTarget.defaults(homeDirectory: NSHomeDirectory())
            .filter(\.isEligibleForScheduledCleaning)

        VStack(alignment: .leading, spacing: 4) {
            Text("Locations").font(.subheadline.weight(.medium))
            ForEach(available) { target in
                Toggle(isOn: Binding(
                    get: { selected.contains(target.path) },
                    set: { isOn in
                        var paths = selected
                        if isOn { paths.insert(target.path) } else { paths.remove(target.path) }
                        viewModel.settings.cleanupTargetPaths = paths.sorted().joined(separator: "\n")
                    }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(LocalizedStringKey(target.name))
                        Text(target.displayPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if selected.isEmpty {
                Label("No location selected — nothing will be cleaned.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var systemAlertsSection: some View {
        Section("System Alerts") {
            labeledStepper(
                "High temperature alert",
                value: $viewModel.settings.systemTempAlertThresholdCelsius, in: 0...100,
                suffix: "°C", zeroMeans: "off"
            )
            labeledStepper(
                "Low battery alert",
                value: $viewModel.settings.batteryLowAlertThresholdPercent, in: 0...100,
                suffix: "%", zeroMeans: "off"
            )
            Toggle("Memory running short: name the heaviest apps not in use", isOn: $viewModel.settings.memoryPressureAlerts)
        }
    }

    /// A number field the user can type an exact value into, plus a Stepper
    /// for quick nudges — a bare `Stepper` label only lets a wide range move
    /// one click at a time.
    @ViewBuilder
    private func labeledStepper(
        _ title: LocalizedStringKey, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1,
        suffix: String? = nil, zeroMeans: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                NumberField(value: value, range: range)
                if let suffix {
                    Text(suffix).foregroundStyle(.secondary)
                }
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
            }
            if let zeroMeans, value.wrappedValue == 0 {
                Text("0 = \(zeroMeans)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Backs `labeledStepper`'s editable number. `TextField(value:format:)`
    /// alone isn't strict enough here: `.number` still accepts things like
    /// grouping commas or a leading minus sign that don't make sense for
    /// these settings, and re-deriving the displayed string from a clamped
    /// `Binding<Int>` on every keystroke fights the user mid-type (e.g.
    /// typing "45" into a 1...90 field briefly reads back "4" then "45",
    /// but typing "99" into that same field snaps to "90" before they can
    /// backspace). Instead: non-digit characters are stripped as typed, the
    /// text is free to hold any digit string while focused, and the value
    /// only round-trips through `range` (parse, clamp, re-render) once on
    /// blur/Return — so the bound `AppSettings` field is never assigned
    /// anything outside `range`, but the field itself doesn't self-correct
    /// out from under an in-progress keystroke.
    private struct NumberField: View {
        @Binding var value: Int
        let range: ClosedRange<Int>

        @State private var text: String = ""
        @FocusState private var isFocused: Bool

        var body: some View {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .focused($isFocused)
                .onAppear { text = String(value) }
                .onChange(of: value) { _, newValue in
                    if !isFocused { text = String(newValue) }
                }
                .onChange(of: text) { _, newValue in
                    let digitsOnly = newValue.filter(\.isNumber)
                    if digitsOnly != newValue { text = digitsOnly }
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .onSubmit { commit() }
        }

        private func commit() {
            let parsed = Int(text) ?? range.lowerBound
            let clamped = min(max(parsed, range.lowerBound), range.upperBound)
            value = clamped
            text = String(clamped)
        }
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
