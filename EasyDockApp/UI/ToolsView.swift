import EasyDockCore
import SwiftUI

/// The Tools tab: Always on Top, Color Picker with its palettes and the
/// contrast check, Drop Zone, then Keep Awake and the apps that keep the Mac
/// awake.
struct ToolsView: View {
    @Bindable private var viewModel = SettingsViewModel.shared
    private let colorPicker = ColorPickerController.shared
    private let permissions = Permissions.shared

    var body: some View {
        Form {
            Section {
                if let hotKeys = StatusBarController.shared.hotKeys {
                    HotKeyRecorderView(title: "Pin or unpin the window in front", action: .pinWindow, manager: hotKeys)
                }
                Text("macOS doesn't let an app put another app's window above the one you are using, so EasyDock shows a live copy of a pinned window above the others while you work in another window. Click the copy to use the window. With Stage Manager on, the copy shows the window as it was when you left it. A pinned window stays on its own desktop; up to three at a time, until EasyDock quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !permissions.accessibility {
                    HStack {
                        Label("This needs the Accessibility permission.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Allow…") { permissions.requestAccessibility() }
                    }
                }
                if !permissions.screenRecording {
                    HStack {
                        Label("The live copy needs the Screen Recording permission.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Allow…") { permissions.requestScreenRecording() }
                    }
                }
            } header: {
                Text("Always on Top")
            }

            colorPickerSection
            PalettesSection()
            ContrastSection()

            Section {
                Toggle("Shake a file while dragging it", isOn: $viewModel.settings.dropZoneShake)
                Toggle("Drag a file onto the notch", isOn: $viewModel.settings.dropZoneTopEdge)
                Text("On a display without a notch, the middle of its top edge works the same way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let hotKeys = StatusBarController.shared.hotKeys {
                    HotKeyRecorderView(title: "Show or hide the Drop Zone", action: .dropZone, manager: hotKeys)
                }
                Text("A shelf above every window that holds files, pictures, links and text while you go to where they belong. Drag an item out to copy it, or hold Command to move it, as with any app's files in Finder; a moved item leaves the shelf. Files stay where they are until then, and the shelf empties when EasyDock quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Drop Zone")
            }

            Section {
                Picker("A session lasts", selection: $viewModel.settings.keepAwakeMinutes) {
                    ForEach(KeepAwakePolicy.durations, id: \.self) { minutes in
                        Text(LocalizedStringKey(KeepAwakeDurationText.title(minutes))).tag(minutes)
                    }
                }
                Toggle("Let the display sleep", isOn: $viewModel.settings.keepAwakeAllowDisplaySleep)
                Text("Only the Mac stays awake: the display still turns off and locks on its usual schedule.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Stop on battery at", selection: $viewModel.settings.keepAwakeBatteryMinimumPercent) {
                    Text("Never").tag(0)
                    ForEach([10, 20, 30, 50], id: \.self) { percent in
                        Text(verbatim: "\(percent)%").tag(percent)
                    }
                }
                if let hotKeys = StatusBarController.shared.hotKeys {
                    HotKeyRecorderView(title: "Turn Keep Awake on or off", action: .keepAwake, manager: hotKeys)
                }
                Text("Start a session from the menu bar panel's Tools tab, the icon's right-click menu or the shortcut. A session ends when you quit EasyDock, log out or restart the Mac; when EasyDock starts again on its own, as after an update, the session carries on. With the lid closed on battery and no external display, the Mac still sleeps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Keep Awake")
            }

            Section {
                ExcludedAppsList(bundleIDs: $viewModel.settings.keepAwakeApps)
                Text("While one of these apps is open, the Mac stays awake, with or without a session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Apps That Keep the Mac Awake")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            viewModel.loadIfNeeded()
            permissions.refresh()
        }
    }

    private var colorPickerSection: some View {
        Section {
            Picker("Copy as", selection: $viewModel.settings.colorPickerFormat) {
                ForEach(ColorFormat.allCases, id: \.self) { format in
                    Text(verbatim: format.label).tag(format)
                }
            }
            if let hotKeys = StatusBarController.shared.hotKeys {
                HotKeyRecorderView(title: "Pick a color", action: .pickColor, manager: hotKeys)
            }
            Text("The color under the pointer is converted to sRGB, the color space of the web and of most code, so the value matches what the screen shows. Hold Shift as you click to keep picking, one color after another. Esc cancels.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !colorPicker.history.recent.isEmpty {
                HStack {
                    Spacer()
                    Button("Clear Recent Colors") { colorPicker.clearRecent() }
                }
            }
        } header: {
            Text("Color Picker")
        }
    }
}

/// The names of Keep Awake's durations, as String Catalog keys: `Text` takes
/// them as `LocalizedStringKey`, the right-click menu through `String(localized:)`.
enum KeepAwakeDurationText {
    static func title(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Until turned off"
        case 15: "15 minutes"
        case 30: "30 minutes"
        case 60: "1 hour"
        case 120: "2 hours"
        default: "4 hours"
        }
    }

    /// For the panel's row of buttons.
    static func short(_ minutes: Int) -> String {
        switch minutes {
        case 0: "∞"
        case 15: "15 min"
        case 30: "30 min"
        case 60: "1 h"
        case 120: "2 h"
        default: "4 h"
        }
    }
}
