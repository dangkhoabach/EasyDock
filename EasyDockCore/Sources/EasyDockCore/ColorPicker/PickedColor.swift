import Foundation
import GRDB

/// How a picked color is copied.
public enum ColorFormat: String, Sendable, CaseIterable {
    case hex, rgb, hsl, swiftUI, nsColor
}

/// A color picked from the screen, as 8-bit sRGB: what the web and most code
/// mean by a color, and what the screen showed once it is converted from
/// the display's own color space.
public struct PickedColor: Hashable, Sendable {
    public var red: Int
    public var green: Int
    public var blue: Int

    public init(red: Int, green: Int, blue: Int) {
        self.red = Self.clamped(red)
        self.green = Self.clamped(green)
        self.blue = Self.clamped(blue)
    }

    /// From sRGB components in 0…1.
    public init(red: Double, green: Double, blue: Double) {
        self.init(red: Int((red * 255).rounded()), green: Int((green * 255).rounded()), blue: Int((blue * 255).rounded()))
    }

    /// "#3352D6" or "3352d6".
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        self.init(red: value >> 16 & 0xFF, green: value >> 8 & 0xFF, blue: value & 0xFF)
    }

    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }

    public func string(_ format: ColorFormat) -> String {
        switch format {
        case .hex:
            return hex
        case .rgb:
            return "rgb(\(red), \(green), \(blue))"
        case .hsl:
            let (h, s, l) = hsl
            return "hsl(\(h), \(s)%, \(l)%)"
        case .swiftUI:
            return "Color(red: \(Self.unit(red)), green: \(Self.unit(green)), blue: \(Self.unit(blue)))"
        case .nsColor:
            return "NSColor(srgbRed: \(Self.unit(red)), green: \(Self.unit(green)), blue: \(Self.unit(blue)), alpha: 1)"
        }
    }

    /// Hue in degrees, saturation and lightness in percent, each rounded.
    var hsl: (Int, Int, Int) {
        let r = Double(red) / 255, g = Double(green) / 255, b = Double(blue) / 255
        let maxValue = max(r, g, b), minValue = min(r, g, b), delta = maxValue - minValue
        let lightness = (maxValue + minValue) / 2
        guard delta > 0 else { return (0, 0, Int((lightness * 100).rounded())) }
        let saturation = delta / (1 - abs(2 * lightness - 1))
        var hue: Double
        switch maxValue {
        case r: hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        case g: hue = (b - r) / delta + 2
        default: hue = (r - g) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (Int(hue.rounded()) % 360, Int((saturation * 100).rounded()), Int((lightness * 100).rounded()))
    }

    private static func unit(_ value: Int) -> String { String(format: "%.3f", Double(value) / 255) }
    private static func clamped(_ value: Int) -> Int { min(max(value, 0), 255) }
}

/// The last colors picked, newest first, kept in `app_settings`.
public struct ColorHistoryStore: Sendable {
    public static let limit = 20
    private static let key = "picked_colors"
    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func load() throws -> [PickedColor] {
        try dbQueue.read { db in
            try AppSettingsStore.get(db, key: Self.key, default: "").split(separator: "\n").compactMap { PickedColor(hex: String($0)) }
        }
    }

    /// Moves a color already there to the front instead of listing it twice.
    @discardableResult
    public func add(_ color: PickedColor) throws -> [PickedColor] {
        try dbQueue.write { db in
            let stored = try AppSettingsStore.get(db, key: Self.key, default: "").split(separator: "\n").compactMap { PickedColor(hex: String($0)) }
            let colors = Array(([color] + stored.filter { $0 != color }).prefix(Self.limit))
            try AppSettingsStore.set(db, key: Self.key, value: colors.map(\.hex).joined(separator: "\n"))
            return colors
        }
    }

    public func clear() throws {
        try dbQueue.write { db in try AppSettingsStore.set(db, key: Self.key, value: "") }
    }
}
