import Testing
@testable import EasyDockCore
@testable import EasyDock

/// Always returns the same fixed snapshot - enough to exercise
/// `MenuBarStatsViewModel`'s label formatting without touching real
/// hardware sensors.
private struct StubStatsProvider: SystemStatsProvider {
    func snapshot() async -> SystemStats {
        SystemStats(cpuPercent: 42, ramUsedMB: 2048, ramTotalMB: 4096, cpuTempCelsius: 55, batteryPercent: 80, batteryCharging: true)
    }
}

@MainActor
@Suite struct MenuBarStatsViewModelTests {
    // `LocalizedStringKey`'s `==` compares the format-string key plus its
    // interpolated arguments, not a rendered string - a plain string literal
    // like `"CPU: 42%"` has no arguments and never equals an interpolated
    // key even when they'd render identically, so the expected side has to
    // be built with the exact same interpolation shape as the production code.
    @Test func refreshFormatsStatsIntoLabels() async throws {
        let model = MenuBarStatsViewModel(statsProvider: StubStatsProvider())
        await model.refresh()

        let cpuPercent = 42
        let ramUsedGB = 2.0, ramTotalGB = 4.0
        let temperatureCelsius = 55
        let batteryPercent = 80

        // On macOS 27.2, `==` on two identical `LocalizedStringKey`s with
        // arguments returns false for a moment after the test host launches,
        // then true from then on. Waiting for that keeps the assertions below
        // about the labels rather than about launch timing.
        for _ in 0..<100 where !(model.cpuLabel == model.cpuLabel) {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(model.cpuLabel == "CPU: \(cpuPercent)%")
        #expect(model.ramLabel == "RAM: \(ramUsedGB, specifier: "%.1f") / \(ramTotalGB, specifier: "%.1f") GB")
        #expect(model.temperatureLabel == "Temperature: \(temperatureCelsius)°C")
        #expect(model.batteryLabel == "Battery: \(batteryPercent)% (Charging)")
    }
}
