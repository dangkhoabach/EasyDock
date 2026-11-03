import AppKit
import Charts
import EasyDockCore
import SwiftUI

// The panel's tabs. They read the same view models as the main window's
// System and Cleanup tabs, so both always show the same numbers;
// `StatusBarController` keeps `SystemViewModel` sampling only while the
// panel is open.

// MARK: - Overview

struct OverviewTab: View {
    private let model = SystemViewModel.shared
    private var stats: SystemStats { model.current }

    var body: some View {
        if !model.hasLoadedOnce {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                metric("CPU", systemImage: "cpu", value: "\(Int(stats.cpuPercent.rounded()))%",
                       percent: stats.cpuPercent, history: model.cpuHistory)
                if stats.cpuCores.count > 1 { coreStrip }
                metric("Memory", systemImage: "memorychip",
                       value: String(format: "%.1f / %.1f GB", Double(stats.ramUsedMB) / 1024, Double(stats.ramTotalMB) / 1024),
                       percent: ramPercent, history: model.ramHistory)
                sensorRow
                Divider()
                AppList(title: "Busiest apps", apps: Array(model.topApps.prefix(3)), sort: .cpu)
            }
            .padding(14)
        }
    }

    private var ramPercent: Double {
        stats.ramTotalMB > 0 ? Double(stats.ramUsedMB) / Double(stats.ramTotalMB) * 100 : 0
    }

    private func metric(_ title: LocalizedStringKey, systemImage: String, value: String, percent: Double, history: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value).font(.caption.weight(.semibold)).monospacedDigit()
            }
            PanelStatBar(percent: percent)
            Sparkline(values: history)
        }
    }

    /// One thin bar per logical core, tinted by load; efficiency cores at
    /// reduced opacity so the two clusters stay apart at this size.
    private var coreStrip: some View {
        let levels = stats.cpuTopology.coreLevels()
        let slowest = stats.cpuTopology.levels.map(\.index).max()
        let labelled = levels.count == stats.cpuCores.count && stats.cpuTopology.hasClusters
        return HStack(spacing: 2) {
            ForEach(Array(stats.cpuCores.enumerated()), id: \.offset) { index, percent in
                let isEfficiency = labelled && levels[index].index == slowest
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 14)
                    .overlay(alignment: .bottom) {
                        Capsule()
                            .fill(loadColor(percent).opacity(isEfficiency ? 0.55 : 1))
                            .frame(height: max(2, 14 * min(max(percent, 0), 100) / 100))
                    }
                    .clipShape(Capsule())
            }
        }
        .accessibilityHidden(true)
    }

    private var sensorRow: some View {
        HStack(spacing: 12) {
            if let temp = stats.cpuTempCelsius {
                Label("\(Int(temp.rounded()))°C", systemImage: "thermometer.medium")
                    .foregroundStyle(temp >= 85 ? .red : temp >= 70 ? .yellow : .secondary)
            }
            if let battery = stats.batteryPercent {
                Label("\(Int(battery.rounded()))%",
                      systemImage: stats.batteryCharging == true ? "battery.100.bolt" : "battery.100")
            }
            if stats.diskTotalGB > 0 {
                Label("\(Int((stats.diskUsedGB / stats.diskTotalGB * 100).rounded()))%", systemImage: "internaldrive")
            }
            Spacer()
            if stats.networkConnected {
                Label(formatKbps(stats.networkDownloadKbps), systemImage: "arrow.down")
                Label(formatKbps(stats.networkUploadKbps), systemImage: "arrow.up")
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .labelStyle(CompactLabelStyle())
    }

    private func formatKbps(_ kbps: Double) -> String {
        kbps >= 1024 ? String(format: "%.1f MB/s", kbps / 1024) : String(format: "%.0f KB/s", kbps)
    }
}

// MARK: - System

struct SystemTab: View {
    private let model = SystemViewModel.shared
    @State private var sort = AppList.Sort.cpu

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Sort by", selection: $sort) {
                Text("CPU").tag(AppList.Sort.cpu)
                Text("Memory").tag(AppList.Sort.memory)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ScrollView {
                AppList(title: nil, apps: Array(sorted.prefix(12)), sort: sort)
            }
            Button("Open System") { showMainWindowTab(.system) }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
    }

    private var sorted: [AppUsage] {
        switch sort {
        case .cpu: model.topApps.sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory: model.topApps.sorted { $0.memoryMB > $1.memoryMB }
        }
    }
}

/// Apps with their load and a Quit button; the context menu adds Force Quit.
struct AppList: View {
    enum Sort { case cpu, memory }

    let title: LocalizedStringKey?
    let apps: [AppUsage]
    let sort: Sort

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            ForEach(apps) { app in
                HStack(spacing: 8) {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                    }
                    Text(app.name).lineLimit(1)
                    Spacer()
                    Text(sort == .cpu ? String(format: "%.1f%%", app.cpuPercent) : String(format: "%.0f MB", app.memoryMB))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Button {
                        app.runningApplication.terminate()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Quit \(app.name)")
                }
                .contextMenu {
                    Button("Quit") { app.runningApplication.terminate() }
                    Button("Force Quit") { app.runningApplication.forceTerminate() }
                }
            }
        }
    }
}

// MARK: - Cleanup

struct CleanupTab: View {
    @Bindable private var viewModel = CleanupViewModel.shared
    /// An inline question instead of a dialog: a sheet would take the focus
    /// from the panel, which closes it.
    @State private var isConfirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Junk found").foregroundStyle(.secondary)
                Spacer()
                if viewModel.isMeasuring {
                    ProgressView().controlSize(.small)
                } else {
                    Text(CleanupViewModel.formatBytes(viewModel.totalJunkBytes)).font(.headline).monospacedDigit()
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(targets) { target in
                        Toggle(isOn: selection(for: target)) {
                            HStack {
                                Text(target.name).lineLimit(1)
                                Spacer()
                                Text(CleanupViewModel.formatBytes(viewModel.junkSizes[target.path] ?? 0))
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            if let message = viewModel.statusMessage {
                Label(message, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
            if isConfirming {
                confirmation
            } else {
                HStack {
                    Button("Find Large Files…") { showMainWindowTab(.cleanup) }
                    Spacer()
                    Button("Move to Trash…") { isConfirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.junkSelection.isEmpty || viewModel.isMeasuring)
                }
            }
        }
        .padding(14)
        .task {
            await viewModel.loadTargets()
            if viewModel.junkSizes.isEmpty { await viewModel.measureJunk() }
        }
    }

    /// Largest first, and only what has something in it.
    private var targets: [JunkTarget] {
        viewModel.junkTargets
            .filter { (viewModel.junkSizes[$0.path] ?? 0) > 0 }
            .sorted { (viewModel.junkSizes[$0.path] ?? 0) > (viewModel.junkSizes[$1.path] ?? 0) }
    }

    private var emptiesTheTrash: Bool {
        viewModel.junkTargets.contains { viewModel.junkSelection.contains($0.path) && $0.deletesPermanently }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(emptiesTheTrash
                 ? "The Trash is emptied for good; everything else goes to the Trash."
                 : "Everything selected goes to the Trash.")
                .font(.caption)
                .foregroundStyle(emptiesTheTrash ? .orange : .secondary)
            HStack {
                Spacer()
                Button("Cancel") { isConfirming = false }
                Button("Clean \(CleanupViewModel.formatBytes(viewModel.selectedJunkBytes))") {
                    isConfirming = false
                    Task { await viewModel.cleanSelected() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func selection(for target: JunkTarget) -> Binding<Bool> {
        Binding(
            get: { viewModel.junkSelection.contains(target.path) },
            set: { isOn in
                if isOn { viewModel.junkSelection.insert(target.path) } else { viewModel.junkSelection.remove(target.path) }
            }
        )
    }
}

// MARK: - Shared pieces

/// Two capsules: the track and the load, tinted by how high it is.
struct PanelStatBar: View {
    let percent: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(loadColor(percent))
                    .frame(width: geo.size.width * CGFloat(min(max(percent, 0), 100)) / 100)
            }
        }
        .frame(height: 5)
    }
}

/// The last couple of minutes of a 0–100 value.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        if values.count > 1 {
            Chart(Array(values.enumerated()), id: \.offset) { sample in
                AreaMark(x: .value("Tick", sample.offset), y: .value("Value", sample.element))
                    .interpolationMethod(.catmullRom)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...100)
            .foregroundStyle(.blue.opacity(0.35))
            .frame(height: 26)
            .accessibilityHidden(true)
        }
    }
}

/// Icon and value with a tight gap, for rows of small readings.
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

private func loadColor(_ percent: Double) -> Color {
    if percent >= 90 { return .red }
    if percent >= 70 { return .yellow }
    return .blue
}
