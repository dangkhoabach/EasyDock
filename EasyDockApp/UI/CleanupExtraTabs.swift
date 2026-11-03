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

/// An app and what it left in `~/Library`, previewed and ticked before
/// anything moves to the Trash.
struct UninstallTab: View {
    @Bindable private var viewModel = CleanupViewModel.shared
    @State private var isConfirming = false
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if let app = viewModel.uninstallApp {
                appDetail(app)
            } else {
                chooser
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chooser: some View {
        VStack(spacing: 14) {
            Image(systemName: "trash.square")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop an app here, or choose one").font(.headline)
            Text("EasyDock lists the app and what it left in your Library (settings, caches, saved state), and moves the ones you keep ticked to the Trash.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Choose App…") { viewModel.chooseAppToUninstall() }
                .buttonStyle(.borderedProminent)
            if let refusal = viewModel.uninstallRefusal {
                Label(refusal, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isDropTargeted ? Color.accentColor : .clear, style: StrokeStyle(lineWidth: 2, dash: [6]))
                .padding(16)
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.pathExtension == "app" else { return false }
            Task { await viewModel.prepareUninstall(url) }
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private func appDetail(_ app: CleanupViewModel.UninstallApp) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: app.icon).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.headline)
                    Text(verbatim: [app.version, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
}
