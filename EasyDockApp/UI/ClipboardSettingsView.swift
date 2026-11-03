import EasyDockCore
import SwiftUI

/// The Clipboard tab of the main window: how the history behaves. The
/// history itself is in the menu bar panel and on its shortcut.
struct ClipboardSettingsView: View {
    @Bindable private var viewModel = SettingsViewModel.shared
    private let store = ClipboardStore.shared
    @State private var isConfirmingClear = false

    var body: some View {
        Form {
            Section {
                Toggle("Record copies", isOn: $viewModel.settings.clipboardEnabled)
                if let hotKeys = StatusBarController.shared.hotKeys {
                    HotKeyRecorderView(title: "Open the clipboard history", action: .clipboardPanel, manager: hotKeys)
                }
                Toggle("Paste the chosen item into the app in front", isOn: $viewModel.settings.clipboardPasteDirectly)
                Picker("Keep", selection: $viewModel.settings.clipboardMaxItems) {
                    Text("100 items").tag(100)
                    Text("500 items").tag(500)
                    Text("1,000 items").tag(1000)
                }
                Picker("For", selection: $viewModel.settings.clipboardMaxDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Ever").tag(0)
                }
                Text("Pinned items are kept whatever these say. Everything is encrypted on this Mac with a key in your Keychain and never leaves it. Images over 10 MB are not kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let failure = store.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } header: {
                Text("History")
            }

            Section {
                ExcludedAppsList(bundleIDs: $viewModel.settings.clipboardExcludedApps)
            } header: {
                Text("Apps Never Recorded")
            } footer: {
                Text("Copies that password managers mark as concealed are never recorded, from any app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if isConfirmingClear {
                    HStack {
                        Text("Delete all \(store.items.count) items, pinned ones too?")
                        Spacer()
                        Button("Cancel") { isConfirmingClear = false }
                        Button("Delete All", role: .destructive) {
                            store.clearHistory()
                            isConfirmingClear = false
                        }
                    }
                } else {
                    Button("Clear History…") { isConfirmingClear = true }
                        .disabled(store.items.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { viewModel.loadIfNeeded() }
    }
}
