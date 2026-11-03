import Charts
import EasyDockCore
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
///
/// The CPU/RAM part is SignalBar's: a standard `MenuBarExtra` menu can only
/// host menu items — no bars, no charts — and the windowed style lifts that
/// restriction, so the numbers read as a glanceable panel: progress bars
/// where there's a ratio, a sparkline where there's a trend.
struct MenuBarContentView: View {
    private let permissions = Permissions.shared
    @Bindable private var model = MenuBarStatsViewModel.shared

    private var stats: SystemStats { model.stats }

    private var ramPercent: Double {
        stats.ramTotalMB > 0 ? Double(stats.ramUsedMB) / Double(stats.ramTotalMB) * 100 : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "EasyDock").font(.headline)
            if !permissions.allGranted {
                Label("EasyDock needs permissions to work.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Divider()
            cpuSection
            memorySection
            sensorRow
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

    private var cpuSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            metricHeader("CPU", systemImage: "cpu", value: model.cpuLabelValue)
            MenuBarStatBar(percent: stats.cpuPercent)
            sparkline(model.cpuHistory)
            if stats.cpuCores.count > 1 {
                coreStrip
            }
        }
    }

    /// One thin bar per logical core, tinted by load. Efficiency cores are
    /// drawn at reduced opacity so the two clusters stay distinguishable at
    /// this size, where per-core text labels wouldn't fit.
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
                            .fill(barColor(percent).opacity(isEfficiency ? 0.55 : 1))
                            .frame(height: max(2, 14 * min(max(percent, 0), 100) / 100))
                    }
                    .clipShape(Capsule())
            }
        }
        .accessibilityHidden(true)
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            metricHeader("Memory", systemImage: "memorychip", value: model.ramLabelValue)
            MenuBarStatBar(percent: ramPercent)
            sparkline(model.ramHistory)
        }
    }

    private var sensorRow: some View {
        HStack(spacing: 14) {
            if let temp = stats.cpuTempCelsius {
                Label("\(Int(temp.rounded()))°C", systemImage: "thermometer.medium")
                    .foregroundStyle(temp >= 85 ? .red : temp >= 70 ? .yellow : .secondary)
            }
            if let battery = stats.batteryPercent {
                Label(
                    "\(Int(battery.rounded()))%",
                    systemImage: stats.batteryCharging == true ? "battery.100.bolt" : "battery.100"
                )
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.caption)
        .monospacedDigit()
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

    private func metricHeader(_ title: LocalizedStringKey, systemImage: String, value: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.weight(.semibold)).monospacedDigit()
        }
    }

    @ViewBuilder
    private func sparkline(_ data: [Double]) -> some View {
        if data.count > 1 {
            Chart(Array(data.enumerated()), id: \.offset) { sample in
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

    private func barColor(_ percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .yellow }
        return .blue
    }
}

/// `SystemView`'s `StatBar` is `private` to that file by design; this is the
/// same two-capsule shape at the popover's smaller scale, kept local rather
/// than promoting a shared component for two call sites.
private struct MenuBarStatBar: View {
    let percent: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(percent >= 90 ? Color.red : percent >= 70 ? .yellow : .blue)
                    .frame(width: geo.size.width * CGFloat(min(max(percent, 0), 100)) / 100)
            }
        }
        .frame(height: 5)
    }
}
