import AppKit
import EasyDockCore
import ServiceManagement
import SwiftUI

/// The background items list, read again each time the tab opens.
@MainActor
@Observable
final class BackgroundItemsModel {
    static let shared = BackgroundItemsModel()

    private(set) var rows: [BackgroundItemsService.Row] = []
    private(set) var isLoading = false
    private(set) var message: String?
    @ObservationIgnored private let service = BackgroundItemsService()

    var orphans: [BackgroundItemsService.Row] { rows.filter(\.isOrphan) }
    var others: [BackgroundItemsService.Row] { rows.filter { !$0.isOrphan } }

    private init() {}

    func reload() async {
        isLoading = true
        rows = await service.load().sorted {
            ($0.ownerName ?? $0.item.label).localizedStandardCompare($1.ownerName ?? $1.item.label) == .orderedAscending
        }
        isLoading = false
    }

    func setEnabled(_ enabled: Bool, _ row: BackgroundItemsService.Row) async {
        if !(await service.setEnabled(enabled, row.item)) {
            message = String(localized: "macOS didn't accept the change.", bundle: AppLocale.bundle)
        }
        await reload()
    }

    /// Unloads the job where macOS allows it, then moves its property list
    /// to the Trash; Finder asks for a password when it belongs to root.
    func moveToTrash(_ row: BackgroundItemsService.Row) async {
        await service.unload(row.item)
        do {
            try await NSWorkspace.shared.recycle([URL(fileURLWithPath: row.item.plistPath)])
            message = String(localized: "Moved \(row.item.label) to the Trash.", bundle: AppLocale.bundle)
        } catch {
            message = String(localized: "Couldn't move \(row.item.label) to the Trash.", bundle: AppLocale.bundle)
        }
        await reload()
    }
}

/// Launch agents and daemons apps installed: which app each belongs to,
/// whether it runs and how much memory it takes; the user's own agents
/// turned off here, the rest in System Settings; leftovers of removed apps
/// moved to the Trash.
struct BackgroundItemsTab: View {
    private let model = BackgroundItemsModel.shared
    @State private var confirming: BackgroundItemsService.Row?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text("What apps run in the background, even when they're closed. Your own agents can be turned off here and stay off; the others are switched in System Settings, which apps can't turn back on behind your back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                Button {
                    Task { await model.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload")
                .accessibilityLabel(Text("Reload"))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            Divider()

            if model.isLoading && model.rows.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.rows.isEmpty {
                ContentUnavailableView("No Background Items", systemImage: "checkmark.circle", description: Text("No app has installed a launch agent or daemon."))
            } else {
                List {
                    if !model.orphans.isEmpty {
                        Section {
                            ForEach(model.orphans) { row($0) }
                        } header: {
                            Text("Left by Removed Apps")
                        }
                    }
                    Section {
                        ForEach(model.others) { row($0) }
                    } header: {
                        Text("Background Items")
                    }
                }
            }
            if let message = model.message {
                Divider()
                Label(message, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
            }
        }
        .task { await model.reload() }
        .confirmationDialog(
            "Move \(confirming?.item.label ?? "") to the Trash?",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { row in
            Button("Move to Trash", role: .destructive) { Task { await model.moveToTrash(row) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its program is gone, so it does nothing but run into an error at each login. It stays recoverable from the Trash until you empty it.")
        }
    }

    private func row(_ row: BackgroundItemsService.Row) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: row.ownerPath.map { NSWorkspace.shared.icon(forFile: $0) } ?? NSWorkspace.shared.icon(for: .unixExecutable))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: row.ownerName ?? row.item.label)
                    .lineLimit(1)
                Text(verbatim: row.item.label + " · " + scopeText(row.item.scope))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status(row)
                    .font(.caption)
            }
            Spacer()
            if row.isOrphan {
                Button("Move to Trash…") { confirming = row }
            } else if row.canToggle {
                Toggle("", isOn: Binding(get: { !row.isDisabled }, set: { on in Task { await model.setEnabled(on, row) } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(Text(verbatim: row.ownerName ?? row.item.label))
            }
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.item.plistPath)]) }
            Button("Copy Label") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.item.label, forType: .string)
            }
        }
    }

    @ViewBuilder
    private func status(_ row: BackgroundItemsService.Row) -> some View {
        if row.isOrphan {
            Text("Its program is gone: \(row.item.programPath ?? "")")
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.middle)
        } else if row.isDisabled {
            Text("Turned off").foregroundStyle(.secondary)
        } else if let memory = row.memoryBytes {
            Text("Running · \(CleanupViewModel.formatBytes(memory))").foregroundStyle(.green)
        } else if row.pid != nil {
            Text("Running").foregroundStyle(.green)
        } else {
            Text("Not running").foregroundStyle(.secondary)
        }
    }

    private func scopeText(_ scope: LaunchItem.Scope) -> String {
        let key: String.LocalizationValue = switch scope {
        case .userAgent: "your agent"
        case .globalAgent: "agent for every user"
        case .globalDaemon: "system daemon"
        case .appAgent: "registered by the app"
        case .appDaemon: "system daemon registered by the app"
        }
        return String(localized: key, bundle: AppLocale.bundle)
    }
}
