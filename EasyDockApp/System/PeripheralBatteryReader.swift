import EasyDockCore
import Foundation
import IOKit

/// The batteries of connected mice, keyboards, headphones and the like, for
/// the System tab and the panel's Overview. Three sources, none of which
/// asks for a permission (see `PeripheralBattery.merge`):
/// - the accessory power sources macOS keeps, read on every call (a few
///   hundredths of a millisecond);
/// - the `BatteryPercent` of Apple's Magic accessories in the IORegistry;
/// - `system_profiler`, for what kind each device is and for the levels only
///   Bluetooth knows, such as each AirPod's. It takes about a tenth of a
///   second, so it runs again only when the devices change or a minute has
///   passed.
///
/// Reading Bluetooth's Battery Service directly would need the Bluetooth
/// permission, and devices behind a Logitech receiver speak Logitech's own
/// protocol; neither is read.
struct PeripheralBatteryReader {
    private static let bluetoothTTL: TimeInterval = 60

    private var bluetooth: [PeripheralBattery.BluetoothDevice] = []
    private var bluetoothReadAt: Date?
    /// The devices the other two sources saw when Bluetooth was last read.
    private var namesAtBluetoothRead: Set<String> = []

    mutating func read(now: Date = Date()) -> [PeripheralBattery] {
        let powerSources = PeripheralBattery.fromPowerSources(PrivateAPIs.accessoryPowerSources())
        let registry = PeripheralBattery.fromRegistry(Self.magicAccessoryEntries())
        let names = Set((powerSources + registry).map(\.name))
        if names != namesAtBluetoothRead || bluetoothReadAt.map({ now.timeIntervalSince($0) >= Self.bluetoothTTL }) ?? true {
            bluetooth = Self.systemProfilerOutput().map(PeripheralBattery.bluetoothDevices(fromSystemProfilerJSON:)) ?? []
            bluetoothReadAt = now
            namesAtBluetoothRead = names
        }
        return PeripheralBattery.merge(powerSources: powerSources, registry: registry, bluetooth: bluetooth)
    }

    /// The product name and level of each Magic accessory; two properties
    /// each rather than every property of the entry.
    private static func magicAccessoryEntries() -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var entries: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entry: [String: Any] = [:]
            for key in ["Product", "BatteryPercent"] {
                entry[key] = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            entries.append(entry)
        }
        return entries
    }

    private static func systemProfilerOutput() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        // A Bluetooth stack that doesn't answer gives up after five seconds
        // rather than holding the stats behind it.
        process.arguments = ["SPBluetoothDataType", "-json", "-timeout", "5"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
