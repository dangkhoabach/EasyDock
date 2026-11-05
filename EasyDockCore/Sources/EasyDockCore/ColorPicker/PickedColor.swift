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

    /// WCAG 2 relative luminance: 0 for black, 1 for white.
    public var relativeLuminance: Double {
        func linear(_ value: Int) -> Double {
            let c = Double(value) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2 contrast ratio between two colors, 1 to 21, whichever is lighter.
    public func contrastRatio(with other: PickedColor) -> Double {
        let (lighter, darker) = (max(relativeLuminance, other.relativeLuminance), min(relativeLuminance, other.relativeLuminance))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func unit(_ value: Int) -> String { String(format: "%.3f", Double(value) / 255) }
    private static func clamped(_ value: Int) -> Int { min(max(value, 0), 255) }
}

/// WCAG 2 contrast thresholds for text.
public struct ContrastCheck: Sendable {
    public let ratio: Double

    public init(_ first: PickedColor, _ second: PickedColor) {
        ratio = first.contrastRatio(with: second)
    }

    public var normalTextAA: Bool { ratio >= 4.5 }
    public var largeTextAA: Bool { ratio >= 3 }
    public var normalTextAAA: Bool { ratio >= 7 }
    public var largeTextAAA: Bool { ratio >= 4.5 }

    /// "4.48:1", cut rather than rounded, so a ratio just under a threshold
    /// never reads as reaching it.
    public var text: String {
        String(format: "%.2f:1", (ratio * 100).rounded(.down) / 100)
    }
}

/// Pinned colors, kept until unpinned, and the last colors picked; each
/// newest first, and no color in both.
public struct ColorHistory: Equatable, Sendable {
    public var pinned: [PickedColor] = []
    public var recent: [PickedColor] = []

    public init(pinned: [PickedColor] = [], recent: [PickedColor] = []) {
        self.pinned = pinned
        self.recent = recent
    }

    public var isEmpty: Bool { pinned.isEmpty && recent.isEmpty }
    public var all: [PickedColor] { pinned + recent }
}

/// The history kept in `app_settings` as one color per line, a pinned one
/// marked with `*`. Versions before pinning read only the unmarked lines.
public struct ColorHistoryStore: Sendable {
    public static let limit = 20
    private static let key = "picked_colors"
    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func load() throws -> ColorHistory {
        try dbQueue.read { db in try Self.read(db) }
    }

    /// Moves a color already listed to the front instead of listing it
    /// twice; a pinned color stays where it is.
    @discardableResult
    public func add(_ color: PickedColor) throws -> ColorHistory {
        try update { history in
            guard !history.pinned.contains(color) else { return }
            history.recent = Array(([color] + history.recent.filter { $0 != color }).prefix(Self.limit))
        }
    }

    @discardableResult
    public func pin(_ color: PickedColor) throws -> ColorHistory {
        try update { history in
            history.recent.removeAll { $0 == color }
            history.pinned = [color] + history.pinned.filter { $0 != color }
        }
    }

    /// Back to the front of the recent colors.
    @discardableResult
    public func unpin(_ color: PickedColor) throws -> ColorHistory {
        try update { history in
            guard history.pinned.contains(color) else { return }
            history.pinned.removeAll { $0 == color }
            history.recent = Array(([color] + history.recent).prefix(Self.limit))
        }
    }

    @discardableResult
    public func remove(_ color: PickedColor) throws -> ColorHistory {
        try update { history in
            history.pinned.removeAll { $0 == color }
            history.recent.removeAll { $0 == color }
        }
    }

    /// Clears the recent colors; pinned ones stay.
    @discardableResult
    public func clearRecent() throws -> ColorHistory {
        try update { history in history.recent = [] }
    }

    private func update(_ change: (inout ColorHistory) -> Void) throws -> ColorHistory {
        try dbQueue.write { db in
            var history = try Self.read(db)
            change(&history)
            let lines = history.pinned.map { "*" + $0.hex } + history.recent.map(\.hex)
            try AppSettingsStore.set(db, key: Self.key, value: lines.joined(separator: "\n"))
            return history
        }
    }

    private static func read(_ db: Database) throws -> ColorHistory {
        var history = ColorHistory()
        for line in try AppSettingsStore.get(db, key: key, default: "").split(separator: "\n") {
            if line.hasPrefix("*") {
                if let color = PickedColor(hex: String(line.dropFirst())) { history.pinned.append(color) }
            } else if let color = PickedColor(hex: String(line)) {
                history.recent.append(color)
            }
        }
        return history
    }
}
