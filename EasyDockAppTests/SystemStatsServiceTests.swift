import Foundation
import Testing
@testable import EasyDockCore
@testable import EasyDock

@Suite struct SystemStatsServiceTests {
    /// The dictionary `IOAccelerator` publishes as `PerformanceStatistics`.
    @Test func readsUtilisationFromTheStatistics() {
        let stats = GPUStatsReader.parse(["Device Utilization %": 37, "In use system memory": 292_962_304, "Tiler Utilization %": 20])
        #expect(stats == GPUStatsReader.Stats(utilizationPercent: 37))
    }

    @Test func readsZeroAsARealReadingRatherThanNothing() {
        #expect(GPUStatsReader.parse(["Device Utilization %": 0]).utilizationPercent == 0)
    }

    @Test func missingKeysReadAsNothing() {
        #expect(GPUStatsReader.parse([:]) == GPUStatsReader.Stats(utilizationPercent: nil))
        #expect(GPUStatsReader.parse(["Device Utilization %": "37"]).utilizationPercent == nil)
    }

    /// Reads the real registry: a Mac either has no accelerator statistics
    /// or reports a percentage, never something outside 0–100.
    @Test func realAcceleratorReportsAPercentageOrNothing() {
        guard let percent = GPUStatsReader().read()?.utilizationPercent else { return }
        #expect((0...100).contains(percent))
    }

    /// The snapshot the menu bar and the scheduler's alerts poll. CPU load
    /// is a delta between two calls, so the second one is the first real
    /// reading. Nothing may come back NaN or out of range, and a Mac that
    /// has a reading at all must keep it within physical bounds.
    @Test func lightSnapshotReturnsBoundedReadings() async throws {
        let service = SystemStatsService()
        _ = await service.snapshotLight()
        try await Task.sleep(for: .milliseconds(200))
        let stats = await service.snapshotLight()

        #expect((0...100).contains(stats.cpuPercent))
        #expect(stats.ramTotalMB > 0)
        #expect(stats.ramUsedMB <= stats.ramTotalMB)
        if let temp = stats.cpuTempCelsius { #expect(temp.isFinite && temp > 0) }
        if let battery = stats.batteryPercent { #expect((0...100).contains(battery)) }
    }

    /// Reads the real registry: there is no seam under the IOKit calls and
    /// the whole point is whether the keys are where the code expects them.
    /// On a Mac with a battery the wear figures are always present and
    /// bounded; on a desktop the whole thing must be absent, not zeroes.
    @Test func batteryHealthComesWithTheBatteryOrNotAtAll() async {
        let stats = await SystemStatsService().snapshot()
        guard stats.batteryPercent != nil else {
            #expect(stats.batteryHealth == nil)
            return
        }
        let health = stats.batteryHealth
        #expect(health != nil)
        #expect((health?.maxCapacityPercent).map { (1...100).contains($0) } == true)
        #expect((health?.cycleCount).map { $0 >= 0 } == true)
    }
}
