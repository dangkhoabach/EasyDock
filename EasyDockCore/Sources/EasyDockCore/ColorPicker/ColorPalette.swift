import Foundation
import GRDB

/// A named set of colors, in the order the user keeps them.
public struct ColorPalette: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public private(set) var colors: [PickedColor]

    public init(id: UUID = UUID(), name: String, colors: [PickedColor] = []) {
        self.id = id
        self.name = name
        self.colors = []
        colors.forEach { add($0) }
    }

    /// At the end; a color already in the palette isn't added twice.
    public mutating func add(_ color: PickedColor) {
        if !colors.contains(color) { colors.append(color) }
    }

    public mutating func remove(_ color: PickedColor) {
        colors.removeAll { $0 == color }
    }
}

/// What a palette is copied as.
public enum PaletteExportFormat: String, Sendable, CaseIterable {
    case css, json, swiftUI, tailwind
}

extension ColorPalette {
    public func export(_ format: PaletteExportFormat) -> String {
        switch format {
        case .css:
            let slug = Self.words(name).map { $0.lowercased() }.joined(separator: "-")
            let lines = colors.enumerated().map { "  --\(slug)-\($0.offset + 1): \($0.element.hex);" }
            return ([":root {"] + lines + ["}"]).joined(separator: "\n")
        case .tailwind:
            // Tailwind 4 reads its colors from `--color-*` variables in `@theme`.
            let slug = Self.words(name).map { $0.lowercased() }.joined(separator: "-")
            let lines = colors.enumerated().map { "  --color-\(slug)-\($0.offset + 1): \($0.element.hex);" }
            return (["@theme {"] + lines + ["}"]).joined(separator: "\n")
        case .json:
            let quotedName = (try? JSONEncoder().encode(name)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
            let list = colors.map { "    \"\($0.hex)\"" }.joined(separator: ",\n")
            return "{\n  \"name\": \(quotedName),\n  \"colors\": [\n\(list)\n  ]\n}"
        case .swiftUI:
            let words = Self.words(name)
            var identifier = ([words[0].lowercased()] + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }).joined()
            // "Palette 1" would give palette11 for its first color.
            if identifier.last?.isNumber == true { identifier += "_" }
            let lines = colors.enumerated().map { "    static let \(identifier)\($0.offset + 1) = \($0.element.string(.swiftUI))" }
            return (["import SwiftUI", "", "extension Color {"] + lines + ["}"]).joined(separator: "\n")
        }
    }

    /// The name's letters and digits as plain ASCII words ("Màu Đỏ 2" →
    /// ["Mau", "Do", "2"]), starting with a letter so every format can use
    /// them as a name; "palette" when nothing is left.
    static func words(_ name: String) -> [String] {
        let plain = name.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
            .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        var words = plain.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.map(String.init)
        if words.first?.first?.isLetter != true { words.insert("palette", at: 0) }
        return words
    }
}

/// The palettes, kept in `app_settings` as JSON with colors as HEX.
public struct ColorPaletteStore: Sendable {
    private static let key = "color_palettes"
    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    private struct Stored: Codable {
        var id: UUID
        var name: String
        var colors: [String]
    }

    public func load() throws -> [ColorPalette] {
        let json = try dbQueue.read { db in try AppSettingsStore.get(db, key: Self.key, default: "[]") }
        let stored = (try? JSONDecoder().decode([Stored].self, from: Data(json.utf8))) ?? []
        return stored.map { ColorPalette(id: $0.id, name: $0.name, colors: $0.colors.compactMap(PickedColor.init(hex:))) }
    }

    public func save(_ palettes: [ColorPalette]) throws {
        let stored = palettes.map { Stored(id: $0.id, name: $0.name, colors: $0.colors.map(\.hex)) }
        let json = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)
        try dbQueue.write { db in try AppSettingsStore.set(db, key: Self.key, value: json) }
    }
}
