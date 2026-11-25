import Foundation
import Testing
@testable import EasyDockCore

@Suite struct PeripheralBatteryTests {
    /// What macOS 27 returned for a Microsoft Bluetooth LE mouse, with the
    /// Mac's own battery, which is not an accessory, beside it.
    private let mouseSource: [String: Any] = [
        "Power Source State": "Battery Power", "Accessory Category": "Keyboard", "Name": "R1mouse2",
        "Vendor ID Source": 2, "Current Capacity": 80, "Low Warn Level": 20, "Power Source ID": 1234,
        "Transport Type": "Bluetooth LE", "Vendor ID": 1118, "Type": "Accessory Source", "Product ID": 64,
        "Accessory Identifier": "00000000-0000-0000-0000-000000000001", "Max Capacity": 100,
    ]
    private let internalBattery: [String: Any] = [
        "Type": "InternalBattery", "Name": "InternalBattery-0", "Current Capacity": 81, "Max Capacity": 100,
        "Is Charging": true, "Power Source State": "AC Power",
    ]

    @Test func readsAnAccessoryAndSkipsTheMacsOwnBattery() {
        let devices = PeripheralBattery.fromPowerSources([internalBattery, mouseSource])
        #expect(devices == [PeripheralBattery(
            name: "R1mouse2", kind: .keyboard,
            parts: [.init(role: .main, percent: 80, isCharging: false)], lowWarningPercent: 20,
            id: "00000000-0000-0000-0000-000000000001"
        )])
    }

    @Test func chargingComesFromTheFlagOrTheState() {
        var charging = mouseSource
        charging["Is Charging"] = true
        #expect(PeripheralBattery.fromPowerSources([charging]).first?.parts.first?.isCharging == true)
        var plugged = mouseSource
        plugged["Power Source State"] = "AC Power"
        #expect(PeripheralBattery.fromPowerSources([plugged]).first?.parts.first?.isCharging == true)
        var unknown = mouseSource
        unknown["Power Source State"] = nil
        #expect(PeripheralBattery.fromPowerSources([unknown]).first?.parts.first?.isCharging == nil)
    }

    /// Earbuds and their case: one device, three batteries, left to right
    /// then the case whatever order macOS lists them in.
    @Test func partsOfOneAccessoryMakeOneDevice() {
        func part(_ id: String, _ percent: Int) -> [String: Any] {
            ["Type": "Accessory Source", "Name": "AirPods Pro", "Accessory Identifier": "A1",
             "Part Identifier": id, "Current Capacity": percent, "Max Capacity": 100, "Accessory Category": "Headphone"]
        }
        let devices = PeripheralBattery.fromPowerSources([part("Case", 40), part("Right", 85), part("Left", 90)])
        #expect(devices.count == 1)
        #expect(devices[0].kind == .headphones)
        #expect(devices[0].parts.map(\.role) == [.left, .right, .chargingCase])
        #expect(devices[0].parts.map(\.percent) == [90, 85, 40])
    }

    /// Two mice of the same model share a name but not an identifier.
    @Test func devicesWithTheSameNameStayApart() {
        var second = mouseSource
        second["Accessory Identifier"] = "00000000-0000-0000-0000-000000000002"
        let devices = PeripheralBattery.fromPowerSources([mouseSource, second])
        #expect(devices.count == 2)
        #expect(Set(devices.map(\.id)).count == 2)
    }

    @Test func absentOrUnreadableSourcesAreSkipped() {
        var absent = mouseSource
        absent["Is Present"] = false
        var noLevel = mouseSource
        noLevel["Current Capacity"] = nil
        var noMax = mouseSource
        noMax["Max Capacity"] = 0
        #expect(PeripheralBattery.fromPowerSources([absent, noLevel, noMax]).isEmpty)
    }

    @Test func levelIsAPercentageOfTheMaximum() {
        var source = mouseSource
        source["Current Capacity"] = 1500
        source["Max Capacity"] = 2000
        #expect(PeripheralBattery.fromPowerSources([source]).first?.parts.first?.percent == 75)
    }

    @Test func readsMagicAccessoriesFromTheRegistry() {
        let devices = PeripheralBattery.fromRegistry([
            ["Product": "Magic Trackpad", "BatteryPercent": 64],
            ["Product": "Apple Internal Keyboard / Trackpad"],
        ])
        #expect(devices == [PeripheralBattery(name: "Magic Trackpad", kind: .trackpad,
                                              parts: [.init(role: .main, percent: 64, isCharging: nil)])])
    }

    /// The shape `system_profiler SPBluetoothDataType -json` prints: the
    /// connected devices with their minor type, earbud levels as strings.
    private let profilerJSON = Data("""
    {"SPBluetoothDataType": [{
      "controller_properties": {"controller_state": "attrib_on"},
      "device_connected": [
        {"R1mouse2": {"device_minorType": "Mouse", "device_vendorID": "0x045E"}},
        {"AirPods Pro": {"device_minorType": "Headphones", "device_batteryLevelLeft": "90%",
                         "device_batteryLevelRight": "85%", "device_batteryLevelCase": "40%"}}
      ],
      "device_not_connected": [{"Magic Trackpad": {"device_minorType": "Magic Trackpad"}}]
    }]}
    """.utf8)

    @Test func readsConnectedBluetoothDevicesOnly() {
        let devices = PeripheralBattery.bluetoothDevices(fromSystemProfilerJSON: profilerJSON)
        #expect(devices.map(\.name) == ["R1mouse2", "AirPods Pro"])
        #expect(devices[0] == .init(name: "R1mouse2", kind: .mouse, parts: []))
        #expect(devices[1].kind == .headphones)
        #expect(devices[1].parts.map(\.percent) == [90, 85, 40])
        #expect(PeripheralBattery.bluetoothDevices(fromSystemProfilerJSON: Data("nope".utf8)).isEmpty)
    }

    /// The mouse macOS calls a keyboard is a mouse; a device only Bluetooth
    /// knows the level of still shows; a name seen twice shows once.
    @Test func mergeKeepsOneEntryPerDeviceWithBluetoothsKind() {
        let merged = PeripheralBattery.merge(
            powerSources: PeripheralBattery.fromPowerSources([mouseSource]),
            registry: [PeripheralBattery(name: "R1mouse2", kind: .mouse, parts: [.init(role: .main, percent: 10, isCharging: nil)])],
            bluetooth: PeripheralBattery.bluetoothDevices(fromSystemProfilerJSON: profilerJSON)
        )
        #expect(merged.map(\.name) == ["AirPods Pro", "R1mouse2"])
        #expect(merged[1].kind == .mouse)
        #expect(merged[1].parts.first?.percent == 80)
    }

    @Test func kindsFromTheWordsMacOSUses() {
        #expect(PeripheralBattery.kind(from: "Magic Trackpad") == .trackpad)
        #expect(PeripheralBattery.kind(from: "Mouse") == .mouse)
        #expect(PeripheralBattery.kind(from: "Headset") == .headphones)
        #expect(PeripheralBattery.kind(from: "Gamepad") == .gamepad)
        #expect(PeripheralBattery.kind(from: "Portable Audio") == .speaker)
        #expect(PeripheralBattery.kind(from: "Watch") == .other)
        #expect(PeripheralBattery.kind(from: nil) == .other)
    }

    @Test func lowUsesTheDevicesOwnLevelAndIgnoresACharger() {
        let low = PeripheralBattery(name: "M", kind: .mouse, parts: [.init(role: .main, percent: 15, isCharging: false)], lowWarningPercent: 10)
        #expect(!low.isLow)
        #expect(PeripheralBattery(name: "M", kind: .mouse, parts: [.init(role: .main, percent: 20, isCharging: nil)]).isLow)
        #expect(!PeripheralBattery(name: "M", kind: .mouse, parts: [.init(role: .main, percent: 5, isCharging: true)]).isLow)
    }
}
