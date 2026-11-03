import Foundation
import GRDB
import Testing
@testable import EasyDockCore

private struct NoNotifier: NotificationSending {
    func notify(title: String, body: String, route: String?) async {}
}

private actor SequenceStatsProvider: SystemStatsProvider {
    private var values: [SystemStats]
    init(_ values: [SystemStats]) { self.values = values }
    func snapshot() async -> SystemStats { values.isEmpty ? SystemStats() : values.removeFirst() }
}

/// The System tab's history: one averaged sample a minute, a day of them kept.
@Suite struct SystemHistoryTests {
    private static let minute = Date(timeIntervalSince1970: 1_800_000_000)

    private func stats(cpu: Double, usedMB: UInt64, temperature: Double?) -> SystemStats {
        SystemStats(cpuPercent: cpu, ramUsedMB: usedMB, ramTotalMB: 1000, cpuTempCelsius: temperature)
    }

    @Test func aMinuteIsAveragedAndHandedBackOnceTheNextOneStarts() {
        var averager = SystemSampleAverager()
        #expect(averager.add(stats(cpu: 10, usedMB: 400, temperature: 50), at: Self.minute) == nil)
        #expect(averager.add(stats(cpu: 30, usedMB: 600, temperature: nil), at: Self.minute + 45) == nil)

        let sample = averager.add(stats(cpu: 90, usedMB: 900, temperature: 70), at: Self.minute + 60)
        #expect(sample == SystemSample(time: Self.minute, cpuPercent: 20, memoryPercent: 50, temperatureCelsius: 50))

        let next = averager.add(stats(cpu: 0, usedMB: 0, temperature: nil), at: Self.minute + 125)
        #expect(next == SystemSample(time: Self.minute + 60, cpuPercent: 90, memoryPercent: 90, temperatureCelsius: 70))
    }

    @Test func aDayIsKeptAndOlderSamplesGo() throws {
        let store = SystemHistoryStore(dbQueue: try AppDatabase(inMemory: DatabaseQueue()).dbQueue)
        let old = SystemSample(time: Self.minute, cpuPercent: 1, memoryPercent: 1, temperatureCelsius: nil)
        let recent = SystemSample(time: Self.minute + 3600, cpuPercent: 2, memoryPercent: 2, temperatureCelsius: 40)
        try store.append(old)
        try store.append(recent)
        #expect(try store.samples(since: Self.minute) == [old, recent])

        let dayLater = SystemSample(time: Self.minute + SystemHistoryStore.keptFor + 60, cpuPercent: 3, memoryPercent: 3, temperatureCelsius: nil)
        try store.append(dayLater)
        #expect(try store.samples(since: .distantPast) == [recent, dayLater])
    }

    @Test func missingMinutesSplitTheLine() {
        let times: [TimeInterval] = [0, 60, 120, 900, 960]
        let samples = times.map { SystemSample(time: Self.minute + $0, cpuPercent: 0, memoryPercent: 0, temperatureCelsius: nil) }
        #expect(SystemHistoryStore.runs(samples).map(\.count) == [3, 2])
    }

    @Test func theSchedulerRecordsAMinuteFromItsTicks() async throws {
        let app = try AppDatabase(inMemory: DatabaseQueue())
        let provider = SequenceStatsProvider((0..<5).map { stats(cpu: Double($0) * 10, usedMB: 500, temperature: nil) })
        let scheduler = Scheduler(dbQueue: app.dbQueue, notifier: NoNotifier(), statsProvider: provider)
        for tick in 0..<5 {
            await scheduler.tick(now: Self.minute + Double(tick) * 15)
        }
        let samples = try SystemHistoryStore(dbQueue: app.dbQueue).samples(since: .distantPast)
        #expect(samples == [SystemSample(time: Self.minute, cpuPercent: 15, memoryPercent: 50, temperatureCelsius: nil)])
    }
}
