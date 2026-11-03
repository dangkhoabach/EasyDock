import Foundation
import GRDB

/// One minute of the machine's load: the average of the scheduler's readings
/// in that minute.
public struct SystemSample: Sendable, Equatable {
    /// The start of the minute.
    public var time: Date
    public var cpuPercent: Double
    public var memoryPercent: Double
    /// Nil on Macs whose sensors EasyDock can't read.
    public var temperatureCelsius: Double?

    public init(time: Date, cpuPercent: Double, memoryPercent: Double, temperatureCelsius: Double?) {
        self.time = time
        self.cpuPercent = cpuPercent
        self.memoryPercent = memoryPercent
        self.temperatureCelsius = temperatureCelsius
    }
}

/// Averages readings by wall-clock minute. A minute is handed back once a
/// reading from a later minute arrives, so it is never cut short.
public struct SystemSampleAverager: Sendable {
    private var minute: Date?
    private var count = 0
    private var cpu = 0.0
    private var memory = 0.0
    private var temperatureCount = 0
    private var temperature = 0.0

    public init() {}

    public mutating func add(_ stats: SystemStats, at now: Date) -> SystemSample? {
        let thisMinute = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 60).rounded(.down) * 60)
        var finished: SystemSample?
        if let minute, minute != thisMinute {
            finished = SystemSample(
                time: minute,
                cpuPercent: cpu / Double(count),
                memoryPercent: memory / Double(count),
                temperatureCelsius: temperatureCount > 0 ? temperature / Double(temperatureCount) : nil
            )
            self = SystemSampleAverager()
        }
        minute = thisMinute
        count += 1
        cpu += stats.cpuPercent
        memory += stats.ramTotalMB > 0 ? Double(stats.ramUsedMB) / Double(stats.ramTotalMB) * 100 : 0
        if let celsius = stats.cpuTempCelsius {
            temperatureCount += 1
            temperature += celsius
        }
        return finished
    }
}

/// The last 24 hours of samples, for the System tab's history charts. At one
/// row a minute that is at most 1,440 rows.
public struct SystemHistoryStore: Sendable {
    public static let keptFor: TimeInterval = 24 * 3600

    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// Adds a sample and drops the ones older than a day before it, and any
    /// after it, left by a clock that was set ahead and then put back.
    public func append(_ sample: SystemSample) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO system_samples (time, cpu, memory, temperature) VALUES (?, ?, ?, ?)",
                arguments: [sample.time.timeIntervalSince1970, sample.cpuPercent, sample.memoryPercent, sample.temperatureCelsius]
            )
            try db.execute(
                sql: "DELETE FROM system_samples WHERE time < ? OR time > ?",
                arguments: [sample.time.timeIntervalSince1970 - Self.keptFor, sample.time.timeIntervalSince1970]
            )
        }
    }

    /// Oldest first.
    public func samples(since start: Date) throws -> [SystemSample] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT time, cpu, memory, temperature FROM system_samples WHERE time >= ? ORDER BY time",
                arguments: [start.timeIntervalSince1970]
            ).map { row in
                SystemSample(
                    time: Date(timeIntervalSince1970: row["time"]),
                    cpuPercent: row["cpu"],
                    memoryPercent: row["memory"],
                    temperatureCelsius: row["temperature"]
                )
            }
        }
    }

    /// Splits samples where minutes are missing (the Mac slept, or EasyDock
    /// wasn't running), so a chart doesn't draw a line across the gap.
    public static func runs(_ samples: [SystemSample], maxGap: TimeInterval = 180) -> [[SystemSample]] {
        var runs: [[SystemSample]] = []
        for sample in samples {
            if let last = runs.last?.last, sample.time.timeIntervalSince(last.time) <= maxGap {
                runs[runs.count - 1].append(sample)
            } else {
                runs.append([sample])
            }
        }
        return runs
    }
}
