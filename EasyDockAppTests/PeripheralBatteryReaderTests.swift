import Foundation
import Testing
@testable import EasyDockCore
@testable import EasyDock

@Suite struct PeripheralBatteryReaderTests {
    /// Reads the real sources: there is no seam under them, and the point is
    /// whether macOS still answers where the code asks. Every accessory
    /// `pmset -g accps` lists with a level must be in the list with that
    /// level, and nothing may come back unnamed, repeated, empty or out of range.
    @Test func listsWhatPmsetListsWithTheSameLevels() throws {
        var reader = PeripheralBatteryReader()
        let devices = reader.read()

        #expect(Set(devices.map(\.id)).count == devices.count)
        for device in devices {
            #expect(!device.name.isEmpty)
            #expect(!device.parts.isEmpty)
            #expect(device.parts.allSatisfy { (0...100).contains($0.percent) })
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "accps"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        // " -Mouse (id=1234)\t80%; " — the Mac's own battery is
        // "InternalBattery-0" and is not an accessory.
        let line = /^ -(.+) \(id=\d+\)\t(\d+)%/
        for match in output.split(separator: "\n").compactMap({ try? line.firstMatch(in: String($0)) })
        where !match.output.1.hasPrefix("InternalBattery") {
            let device = devices.first { $0.name == String(match.output.1) }
            #expect(device != nil, "\(match.output.1) is missing")
            #expect(device?.parts.contains { $0.percent == Int(match.output.2) } == true)
        }
    }

    /// The second read within the minute reuses Bluetooth's answer instead of
    /// starting `system_profiler` again, and gives the same list.
    @Test func aSecondReadIsCheapAndTheSame() {
        var reader = PeripheralBatteryReader()
        let first = reader.read()
        let start = Date()
        let second = reader.read()
        #expect(Date().timeIntervalSince(start) < 0.05)
        #expect(second.map(\.name) == first.map(\.name))
    }
}
