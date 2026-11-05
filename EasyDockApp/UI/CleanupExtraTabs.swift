import EasyDockCore
import SwiftUI
import UniformTypeIdentifiers

/// Simulators and Homebrew, under the junk list. Shown only when one of the
/// two tools is installed.
struct DeveloperToolsSection: View {
    @Bindable private var viewModel = CleanupViewModel.shared
    @State private var confirming: CleanupViewModel.DeveloperTool?

    var body: some View {
        Group {
            if let status = viewModel.developerStatus, status.unavailableSimulators != nil || status.hasHomebrew {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Developer Tools").font(.headline)
                    GroupBox {
                        VStack(spacing: 0) {
                            if let count = status.unavailableSimulators {
                                row(
                                    title: "Unavailable simulators",
                                    detail: count == 0
                                        ? Text("None: every simulator still has its runtime.")
                                        : Text("\(count) simulators whose iOS version is no longer installed. They can't start again."),
                                    tool: .simulators,
                                    enabled: count > 0
                                )
                            }
                            if status.unavailableSimulators != nil && status.hasHomebrew { Divider() }
                            if status.hasHomebrew {
                                row(
                                    title: "Homebrew cleanup",
                                    detail: status.homebrewReclaimable.map { Text("Old versions and downloads: about \($0).") }
                                        ?? Text("Nothing to remove."),
                                    tool: .homebrew,
                                    enabled: status.homebrewReclaimable != nil
                                )
                            }
                        }
                        .padding(10)
                    }
                }
            }
        }
        .task { if viewModel.developerStatus == nil { await viewModel.checkDeveloperTools() } }
        .confirmationDialog(
            confirming == .simulators ? "Delete the unavailable simulators?" : "Run Homebrew cleanup?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { tool in
            Button("Delete", role: .destructive) { Task { await viewModel.run(tool) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The tool deletes these files itself, so they don't go to the Trash.")
        }
    }

    private func row(title: LocalizedStringKey, detail: Text, tool: CleanupViewModel.DeveloperTool, enabled: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(.callout)
                    Text("Permanent")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.red.opacity(0.15), in: Capsule())
                        .foregroundStyle(.red)
                }
                detail.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.runningDeveloperTool == tool {
                ProgressView().controlSize(.small)
            } else {
                Button("Clean…") { confirming = tool }
                    .disabled(!enabled || viewModel.runningDeveloperTool != nil)
            }
        }
        .padding(.vertical, 5)
    }
}

/// Items that have sat in Downloads for longer than the chosen age. Found
/// and moved only from here, never on a schedule.
struct OldDownloadsTab: View {
    @Bindable private var viewModel = CleanupViewModel.shared
    @State private var isConfirming = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Added more than", selection: $viewModel.downloadsAge) {
                    ForEach(OldDownloads.ageChoices, id: \.self) { Text("\($0) days ago").tag($0) }
                }
                .frame(width: 280)
                Spacer()
                if viewModel.isScanningDownloads {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Find") { Task { await viewModel.scanDownloads() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            Divider()
            results.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: viewModel.downloadsAge) {
            if viewModel.hasScannedDownloads { Task { await viewModel.scanDownloads() } }
        }
    }

    @ViewBuilder
    private var results: some View {
        if let error = viewModel.downloadsError {
            ContentUnavailableView {
                Label("Could not read Downloads", systemImage: "folder.badge.questionmark")
            } description: {
                Text("\(error) Allow EasyDock in System Settings › Privacy & Security › Files and Folders.")
            }
        } else if viewModel.oldDownloads.isEmpty {
            ContentUnavailableView(
                viewModel.hasScannedDownloads ? "Nothing that old" : "Old downloads",
                systemImage: "arrow.down.circle",
                description: Text(viewModel.hasScannedDownloads
                    ? "Everything in Downloads was added more recently."
                    : "Finds what has sat in Downloads for a while. It only runs when you press Find.")
            )
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("\(viewModel.oldDownloads.count) items · \(CleanupViewModel.formatBytes(viewModel.oldDownloads.reduce(0) { $0 + $1.sizeBytes }))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Select All") { viewModel.downloadSelection = Set(viewModel.oldDownloads.map(\.path)) }
                    Button("Move to Trash") { isConfirming = true }
                        .disabled(viewModel.downloadSelection.isEmpty)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)

                List(viewModel.oldDownloads, selection: $viewModel.downloadSelection) { entry in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: entry.path)).resizable().frame(width: 18, height: 18)
                        Text(entry.name).lineLimit(1)
                        Spacer()
                        Text("Added \(entry.modified.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(CleanupViewModel.formatBytes(entry.sizeBytes))
                            .monospacedDigit()
                            .frame(width: 80, alignment: .trailing)
                    }
                    .tag(entry.path)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
                    }
                }
            }
            .confirmationDialog(
                "Move \(viewModel.downloadSelection.count) item(s), \(CleanupViewModel.formatBytes(viewModel.selectedDownloadBytes)), to the Trash?",
                isPresented: $isConfirming,
                titleVisibility: .visible
            ) {
                Button("Move to Trash", role: .destructive) { Task { await viewModel.trashSelectedDownloads() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("They stay recoverable from the Trash until you empty it.")
            }
        }
    }
}

/// An app and what it left in `~/Library`, or what apps already removed
/// left there, previewed and ticked before anything moves to the Trash.
struct UninstallTab: View {
    @Bindable private var viewModel = CleanupViewModel.shared
    @Bindable private var settings = SettingsViewModel.shared
    @State private var isConfirming = false
    @State private var isConfirmingOrphans = false
    @State private var isConfirmingApps = false
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if let groups = viewModel.orphanGroups {
                orphanList(groups)
            } else if let app = viewModel.uninstallApp {
                appDetail(app)
            } else {
                chooser
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Every installed app, as soon as the tab opens: tick some to remove
    /// them with what they left, or open one to review its files first.
    private var chooser: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search Apps", text: $viewModel.appQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Picker("Sort by", selection: $viewModel.appSort) {
                    ForEach(CleanupViewModel.AppSort.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .fixedSize()
                Spacer()
                Menu("More") {
                    Button("Choose App…") { viewModel.chooseAppToUninstall() }
                    Button("Find Files Left by Removed Apps") { Task { await viewModel.findOrphans() } }
                }
                .fixedSize()
                Button(viewModel.appSelection.isEmpty ? "Uninstall…" : "Uninstall \(viewModel.appSelection.count) Apps…") { isConfirmingApps = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.appSelection.isEmpty || viewModel.isUninstallingApps)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            if let refusal = viewModel.uninstallRefusal {
                Label(refusal, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
            Divider()

            if viewModel.installedApps.isEmpty && viewModel.isLoadingApps {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.installedApps.isEmpty {
                ContentUnavailableView("No Apps to Remove", systemImage: "app.dashed", description: Text("Apps in Applications that aren't part of macOS show here."))
            } else {
                List(viewModel.shownApps) { app in
                    appRow(app)
                }
            }
            Divider()
            HStack {
                Text("Drop an app from anywhere here to review it. Apps that are part of macOS aren't listed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Notify me when a removed app leaves files behind", isOn: $settings.settings.removedAppAlerts)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
        }
        .onAppear { settings.loadIfNeeded() }
        .task { await viewModel.loadInstalledApps() }
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isDropTargeted ? Color.accentColor : .clear, style: StrokeStyle(lineWidth: 2, dash: [6]))
                .padding(8)
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.pathExtension == "app" else { return false }
            Task { await viewModel.prepareUninstall(url) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .confirmationDialog(
            "Move \(viewModel.appSelection.count) app(s) and what they left, \(CleanupViewModel.formatBytes(viewModel.selectedAppsBytes)), to the Trash?",
            isPresented: $isConfirmingApps,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { Task { await viewModel.uninstallSelectedApps() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apps that are open are skipped. Files matched only by an app's name stay: open the app's details to review them. Everything stays recoverable from the Trash until you empty it.")
        }
    }

    private func appRow(_ app: AppUninstaller.InstalledApp) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { viewModel.appSelection.contains(app.path) },
                set: { isOn in
                    if isOn { viewModel.appSelection.insert(app.path) } else { viewModel.appSelection.remove(app.path) }
                }
            ))
            .labelsHidden()
            .accessibilityLabel(Text(verbatim: app.name))
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: [app.name, app.version].compactMap { $0 }.joined(separator: " "))
                    .lineLimit(1)
                Group {
                    if let lastUsed = app.lastUsed {
                        // Formatted by SwiftUI, in the app's language rather than the system's.
                        Text("Last opened \(Text(lastUsed, format: .dateTime.day().month(.abbreviated).year()))")
                    } else {
                        Text("Last opened: not recorded")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let total = app.totalBytes {
                Text(CleanupViewModel.formatBytes(total))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help(Text("App \(CleanupViewModel.formatBytes(app.appBytes ?? 0)), in your Library \(CleanupViewModel.formatBytes(app.leftoverBytes ?? 0))"))
            } else {
                ProgressView().controlSize(.small)
            }
            Button {
                Task { await viewModel.prepareUninstall(URL(fileURLWithPath: app.path)) }
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .help("Review what it left")
            .accessibilityLabel(Text("Review what \(app.name) left"))
        }
        .contextMenu {
            Button("Review what it left") { Task { await viewModel.prepareUninstall(URL(fileURLWithPath: app.path)) } }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
        }
    }

    private func appDetail(_ app: CleanupViewModel.UninstallApp) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: app.icon).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.headline)
                    if app.isRemoved {
                        Text("Removed · \(app.bundleID)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: [app.version, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Cancel") { viewModel.clearUninstall() }
                Button("Move to Trash…") { isConfirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.uninstallSelection.isEmpty || viewModel.isFindingLeftovers || viewModel.uninstallAppIsRunning)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)

            if viewModel.uninstallAppIsRunning {
                HStack {
                    Label("\(app.name) is open. Quit it first, so it doesn't write its files back.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Quit \(app.name)") { viewModel.quitUninstallApp() }
                }
                .font(.callout)
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            }
            Divider()

            if viewModel.isFindingLeftovers {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.uninstallItems) { item in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { viewModel.uninstallSelection.contains(item.path) },
                            set: { isOn in
                                if isOn { viewModel.uninstallSelection.insert(item.path) }
                                else { viewModel.uninstallSelection.remove(item.path) }
                            }
                        ))
                        .labelsHidden()
                        .accessibilityLabel(Text(verbatim: item.displayPath))
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 18, height: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Group {
                                if item.isAppBundle {
                                    Text("The app")
                                } else if item.matchedByName {
                                    Text("Matched by the app's name: check it isn't shared with another app")
                                } else {
                                    Text("Left in your Library")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(item.matchedByName ? .orange : .secondary)
                            Text(verbatim: item.displayPath).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(CleanupViewModel.formatBytes(item.bytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                    }
                }
            }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            viewModel.refreshUninstallAppIsRunning()
        }
        .confirmationDialog(
            "Move \(viewModel.uninstallSelection.count) item(s), \(CleanupViewModel.formatBytes(viewModel.selectedUninstallBytes)), to the Trash?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { Task { await viewModel.uninstallSelected() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They stay recoverable from the Trash until you empty it. macOS may ask for your password if the app was installed for all users.")
        }
    }

    private func orphanList(_ groups: [AppUninstaller.OrphanGroup]) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Files Left by Removed Apps").font(.headline)
                    Text("Named after apps that are no longer on this Mac. Some can belong to a command-line tool or a helper that isn't an app, so nothing is ticked: tick only what you recognize.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Done") { viewModel.clearOrphans() }
                Button("Move to Trash…") { isConfirmingOrphans = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.orphanSelection.isEmpty || viewModel.isFindingOrphans)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            Divider()

            if viewModel.isFindingOrphans {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groups.isEmpty {
                ContentUnavailableView("Nothing Left Behind", systemImage: "checkmark.circle", description: Text("No file in your Library is named after an app that is gone."))
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { item in
                                HStack(spacing: 10) {
                                    Toggle("", isOn: Binding(
                                        get: { viewModel.orphanSelection.contains(item.path) },
                                        set: { isOn in
                                            if isOn { viewModel.orphanSelection.insert(item.path) }
                                            else { viewModel.orphanSelection.remove(item.path) }
                                        }
                                    ))
                                    .labelsHidden()
                                    .accessibilityLabel(Text(verbatim: item.displayPath))
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.path)).resizable().frame(width: 18, height: 18)
                                    Text(verbatim: item.displayPath).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(CleanupViewModel.formatBytes(item.bytes))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                .contextMenu {
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
                                }
                            }
                        } header: {
                            HStack {
                                Text(verbatim: group.bundleID)
                                if let vendorApp = group.vendorApp {
                                    Text("\(vendorApp) from the same maker is still installed and may use these")
                                        .foregroundStyle(.orange)
                                }
                                Spacer()
                                Text(CleanupViewModel.formatBytes(group.bytes)).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Move \(viewModel.orphanSelection.count) item(s), \(CleanupViewModel.formatBytes(viewModel.selectedOrphanBytes)), to the Trash?",
            isPresented: $isConfirmingOrphans,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { Task { await viewModel.trashSelectedOrphans() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They stay recoverable from the Trash until you empty it.")
        }
    }
}
