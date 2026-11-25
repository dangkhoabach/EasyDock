import Foundation

/// The battery of a mouse, keyboard, headphones or other device connected to
/// the Mac. macOS has no single public list of these, so the app reads three
/// sources and this type turns what each returns into one list; the reading
/// itself stays in the app's `PeripheralBatteryReader`.
public struct PeripheralBattery: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case mouse, keyboard, trackpad, headphones, speaker, gamepad, other
    }

    /// One battery of the device. AirPods have three: each bud and the case.
    public struct Part: Sendable, Equatable {
        public enum Role: Sendable, Equatable { case main, left, right, chargingCase }

        public var role: Role
        public var percent: Int
        /// `nil` when the source doesn't say.
        public var isCharging: Bool?

        public init(role: Role, percent: Int, isCharging: Bool?) {
            self.role = role
            self.percent = percent
            self.isCharging = isCharging
        }
    }

    /// macOS's identifier for the accessory when it gives one, so two
    /// devices with the same name stay apart; otherwise the name.
    public var id: String
    public var name: String
    public var kind: Kind
    /// Left, right, case, in that order; a single `main` for most devices.
    public var parts: [Part]
    /// The level macOS warns at, when the device reports one.
    public var lowWarningPercent: Int?

    public init(name: String, kind: Kind, parts: [Part], lowWarningPercent: Int? = nil, id: String? = nil) {
        self.id = id ?? name
        self.name = name
        self.kind = kind
        self.parts = parts
        self.lowWarningPercent = lowWarningPercent
    }

    /// 20% unless the device names its own level.
    public var isLow: Bool {
        parts.contains { $0.percent <= (lowWarningPercent ?? 20) && $0.isCharging != true }
    }

    // MARK: - Sources

    /// The accessory power sources macOS keeps (what `pmset -g accps`
    /// prints). A device with several batteries is several sources sharing
    /// an `Accessory Identifier`, each with a `Part Identifier`.
    public static func fromPowerSources(_ sources: [[String: Any]]) -> [PeripheralBattery] {
        var devices: [PeripheralBattery] = []
        var indexByAccessory: [String: Int] = [:]
        for source in sources {
            guard source["Type"] as? String == "Accessory Source",
                  source["Is Present"] as? Bool != false,
                  let name = source["Name"] as? String, !name.isEmpty,
                  let current = source["Current Capacity"] as? Int
            else { continue }
            let max = source["Max Capacity"] as? Int ?? 100
            guard max > 0 else { continue }
            let charging = source["Is Charging"] as? Bool ?? source["Power Source State"].map { $0 as? String == "AC Power" }
            let part = Part(role: role(forPart: source["Part Identifier"] as? String),
                            percent: clamped(Double(current) / Double(max) * 100), isCharging: charging)
            let key = source["Accessory Identifier"] as? String ?? name
            if let index = indexByAccessory[key] {
                devices[index].parts.append(part)
            } else {
                indexByAccessory[key] = devices.count
                devices.append(PeripheralBattery(name: name, kind: kind(from: source["Accessory Category"] as? String),
                                                 parts: [part], lowWarningPercent: source["Low Warn Level"] as? Int, id: key))
            }
        }
        return devices.map { $0.withPartsInOrder() }
    }

    /// The IORegistry entries of Apple's own Bluetooth accessories (Magic
    /// Mouse, Keyboard, Trackpad), which carry `BatteryPercent`.
    public static func fromRegistry(_ entries: [[String: Any]]) -> [PeripheralBattery] {
        entries.compactMap { entry in
            guard let name = entry["Product"] as? String, !name.isEmpty,
                  let percent = entry["BatteryPercent"] as? Int
            else { return nil }
            return PeripheralBattery(name: name, kind: kind(from: name),
                                     parts: [Part(role: .main, percent: clamped(Double(percent)), isCharging: nil)])
        }
    }

    /// `system_profiler SPBluetoothDataType -json`: what kind each connected
    /// device is, and the battery levels Bluetooth itself reports (AirPods
    /// buds and case among them).
    public struct BluetoothDevice: Sendable, Equatable {
        public var name: String
        public var kind: Kind
        public var parts: [Part]
    }

    public static func bluetoothDevices(fromSystemProfilerJSON data: Data) -> [BluetoothDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [] }
        let keys: [(String, Part.Role)] = [
            ("device_batteryLevelMain", .main), ("device_batteryLevelLeft", .left),
            ("device_batteryLevelRight", .right), ("device_batteryLevelCase", .chargingCase),
        ]
        return controllers.flatMap { controller -> [BluetoothDevice] in
            let connected = controller["device_connected"] as? [[String: Any]] ?? []
            return connected.flatMap { entry in
                entry.compactMap { name, value -> BluetoothDevice? in
                    guard let info = value as? [String: Any] else { return nil }
                    let parts = keys.compactMap { key, role -> Part? in
                        guard let text = info[key] as? String,
                              let percent = Int(text.trimmingCharacters(in: CharacterSet(charactersIn: "% ")))
                        else { return nil }
                        return Part(role: role, percent: clamped(Double(percent)), isCharging: nil)
                    }
                    return BluetoothDevice(name: name, kind: kind(from: info["device_minorType"] as? String), parts: parts)
                }
            }
        }
    }

    /// One entry per device name. Power sources come first: they are read
    /// fresh on every call and say whether a device is charging. The
    /// registry and Bluetooth fill in devices the others miss. Bluetooth's
    /// kind wins over the others', which can call a mouse a keyboard.
    public static func merge(powerSources: [PeripheralBattery], registry: [PeripheralBattery],
                             bluetooth: [BluetoothDevice]) -> [PeripheralBattery] {
        var devices = powerSources
        var names = Set(devices.map(\.name))
        for device in registry + bluetooth.filter({ !$0.parts.isEmpty }).map({
            PeripheralBattery(name: $0.name, kind: $0.kind, parts: $0.parts)
        }) where names.insert(device.name).inserted {
            devices.append(device.withPartsInOrder())
        }
        let kinds = Dictionary(bluetooth.map { ($0.name, $0.kind) }, uniquingKeysWith: { first, _ in first })
        for index in devices.indices {
            if let kind = kinds[devices[index].name], kind != .other { devices[index].kind = kind }
        }
        return devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Helpers

    /// Reads the words macOS uses for a device's type — Bluetooth's minor
    /// type, the power source's category, or failing both the product name.
    public static func kind(from text: String?) -> Kind {
        guard let text = text?.lowercased() else { return .other }
        if text.contains("trackpad") { return .trackpad }
        if text.contains("mouse") { return .mouse }
        if text.contains("keyboard") { return .keyboard }
        if text.contains("headphone") || text.contains("headset") || text.contains("airpods") { return .headphones }
        if text.contains("gamepad") || text.contains("joystick") || text.contains("game controller") { return .gamepad }
        if text.contains("speaker") || text.contains("audio") { return .speaker }
        return .other
    }

    private static func role(forPart part: String?) -> Part.Role {
        switch part {
        case "Left": .left
        case "Right": .right
        case "Case": .chargingCase
        default: .main
        }
    }

    private static func clamped(_ percent: Double) -> Int {
        Int(min(max(percent, 0), 100).rounded())
    }

    private func withPartsInOrder() -> PeripheralBattery {
        let order: [Part.Role] = [.main, .left, .right, .chargingCase]
        var copy = self
        copy.parts.sort { order.firstIndex(of: $0.role)! < order.firstIndex(of: $1.role)! }
        return copy
    }
}
