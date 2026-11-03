import EasyDockCore
import Foundation
import Observation
import SwiftUI

/// Feeds the status item when it shows the CPU next to the glyph:
/// `SystemStatsProvider` read every 2s via a `Task.sleep` loop (same
/// burst-avoiding shape as the scheduler's) rather than a `Timer`, and only
/// while that icon mode is on — `StatusBarController` starts and stops it.
/// Uses `snapshotLight()` (not `snapshot()`): the full snapshot would fork
/// `route`/`networksetup`/`ifconfig` processes on every tick for values
/// nobody reads.
///
/// Exposes `LocalizedStringKey` labels (not pre-formatted `String`s) so
/// Xcode's String Catalog extraction can localize them — a
/// `String` handed to `Text(_:)` is shown verbatim with no catalog lookup.
@MainActor
@Observable
final class MenuBarStatsViewModel {
    private static let refreshIntervalSecs: UInt64 = 2

    // Matches `NotificationManager`'s singleton shape: one instance for the
    // app's lifetime, started once from `AppDelegate.applicationDidFinishLaunching`.
    static let shared = MenuBarStatsViewModel(statsProvider: SystemStatsService())

    private let statsProvider: SystemStatsProvider
    private var loopTask: Task<Void, Never>?

    /// Rolling window for the icon's CPU chart, which draws the last 13.
    private static let historyLimit = 24

    private var cpuPercent: Int?
    private var ramUsedGB: Double?
    private var ramTotalGB: Double?
    private var temperatureCelsius: Int?
    private var batteryPercent: Int?
    private var batteryCharging = false

    private(set) var cpuHistory: [Double] = []

    init(statsProvider: SystemStatsProvider) {
        self.statsProvider = statsProvider
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: Self.refreshIntervalSecs * 1_000_000_000)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    func refresh() async {
        let stats = await statsProvider.snapshotLight()
        appendClamped(&cpuHistory, stats.cpuPercent)

        cpuPercent = Int(stats.cpuPercent.rounded())
        ramUsedGB = Double(stats.ramUsedMB) / 1024
        ramTotalGB = Double(stats.ramTotalMB) / 1024
        temperatureCelsius = stats.cpuTempCelsius.map { Int($0.rounded()) }
        batteryPercent = stats.batteryPercent.map { Int($0.rounded()) }
        batteryCharging = stats.batteryCharging ?? false
    }

    var cpuLabel: LocalizedStringKey {
        guard let cpuPercent else { return "CPU: —" }
        return "CPU: \(cpuPercent)%"
    }

    var ramLabel: LocalizedStringKey {
        guard let ramUsedGB, let ramTotalGB else { return "RAM: —" }
        return "RAM: \(ramUsedGB, specifier: "%.1f") / \(ramTotalGB, specifier: "%.1f") GB"
    }

    var temperatureLabel: LocalizedStringKey {
        guard let temperatureCelsius else { return "Temperature: N/A" }
        return "Temperature: \(temperatureCelsius)°C"
    }

    var batteryLabel: LocalizedStringKey {
        guard let batteryPercent else { return "Battery: N/A" }
        return batteryCharging ? "Battery: \(batteryPercent)% (Charging)" : "Battery: \(batteryPercent)%"
    }

    private func appendClamped(_ array: inout [Double], _ value: Double) {
        array.append(value)
        if array.count > Self.historyLimit {
            array.removeFirst(array.count - Self.historyLimit)
        }
    }
}
