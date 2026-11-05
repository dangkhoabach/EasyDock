import GRDB
import Testing
@testable import EasyDockCore

@Suite struct PickedColorTests {
    private let blue = PickedColor(red: 0x33, green: 0x52, blue: 0xD6)

    @Test func everyFormat() {
        #expect(blue.string(.hex) == "#3352D6")
        #expect(blue.string(.rgb) == "rgb(51, 82, 214)")
        #expect(blue.string(.hsl) == "hsl(229, 67%, 52%)")
        #expect(blue.string(.swiftUI) == "Color(red: 0.200, green: 0.322, blue: 0.839)")
        #expect(blue.string(.nsColor) == "NSColor(srgbRed: 0.200, green: 0.322, blue: 0.839, alpha: 1)")
    }

    /// Hues on each side of red, and the greys that have none.
    @Test func hslAroundTheWheel() {
        #expect(PickedColor(red: 255, green: 0, blue: 0).string(.hsl) == "hsl(0, 100%, 50%)")
        #expect(PickedColor(red: 255, green: 0, blue: 64).string(.hsl) == "hsl(345, 100%, 50%)")
        #expect(PickedColor(red: 0, green: 255, blue: 0).string(.hsl) == "hsl(120, 100%, 50%)")
        #expect(PickedColor(red: 128, green: 128, blue: 128).string(.hsl) == "hsl(0, 0%, 50%)")
        #expect(PickedColor(red: 255, green: 255, blue: 255).string(.hsl) == "hsl(0, 0%, 100%)")
    }

    /// The sampler can hand back components a little outside 0…1 once a
    /// wide-gamut color is converted to sRGB.
    @Test func componentsOutsideTheRangeAreClamped() {
        #expect(PickedColor(red: 1.04, green: -0.02, blue: 0.5).hex == "#FF0080")
    }

    @Test func hexReadsBack() {
        #expect(PickedColor(hex: "#3352D6") == blue)
        #expect(PickedColor(hex: "3352d6") == blue)
        #expect(PickedColor(hex: "#3352D") == nil)
        #expect(PickedColor(hex: "#GG52D6") == nil)
    }

    @Test func theHistoryKeepsTheNewestFirstWithoutRepeats() throws {
        let store = ColorHistoryStore(dbQueue: try AppDatabase(inMemory: DatabaseQueue()).dbQueue)
        let red = PickedColor(red: 255, green: 0, blue: 0)
        try store.add(blue)
        try store.add(red)
        try store.add(blue)
        #expect(try store.load() == ColorHistory(recent: [blue, red]))
    }

    @Test func theHistoryStopsAtItsLimit() throws {
        let store = ColorHistoryStore(dbQueue: try AppDatabase(inMemory: DatabaseQueue()).dbQueue)
        for value in 0..<(ColorHistoryStore.limit + 5) { try store.add(PickedColor(red: value, green: 0, blue: 0)) }
        let colors = try store.load().recent
        #expect(colors.count == ColorHistoryStore.limit)
        #expect(colors.first == PickedColor(red: ColorHistoryStore.limit + 4, green: 0, blue: 0))
        try store.clearRecent()
        #expect(try store.load().isEmpty)
    }

    /// A pinned color outlives the limit and "Clear", and picking it again
    /// doesn't list it a second time.
    @Test func aPinnedColorStays() throws {
        let store = ColorHistoryStore(dbQueue: try AppDatabase(inMemory: DatabaseQueue()).dbQueue)
        let red = PickedColor(red: 255, green: 0, blue: 0)
        try store.add(red)
        try store.add(blue)
        #expect(try store.pin(red) == ColorHistory(pinned: [red], recent: [blue]))
        for value in 1...(ColorHistoryStore.limit + 5) { try store.add(PickedColor(red: 0, green: value, blue: 0)) }
        try store.add(red)
        #expect(try store.load().pinned == [red])
        #expect(!(try store.load().recent.contains(red)))
        #expect(try store.clearRecent() == ColorHistory(pinned: [red]))
        #expect(try store.unpin(red) == ColorHistory(recent: [red]))
        #expect(try store.remove(red).isEmpty)
    }

    /// Versions before pinning stored bare HEX lines; those load as recent.
    @Test func anOldHistoryLoadsAsRecent() throws {
        let queue = try AppDatabase(inMemory: DatabaseQueue()).dbQueue
        try queue.write { db in try AppSettingsStore.set(db, key: "picked_colors", value: "#3352D6\n#FF0000") }
        #expect(try ColorHistoryStore(dbQueue: queue).load() == ColorHistory(recent: [blue, PickedColor(red: 255, green: 0, blue: 0)]))
    }

    /// Known WCAG values: the extremes, and the two greys either side of 4.5:1 on white.
    @Test func contrastRatios() {
        let white = PickedColor(red: 255, green: 255, blue: 255), black = PickedColor(red: 0, green: 0, blue: 0)
        #expect(ContrastCheck(black, white).text == "21.00:1")
        #expect(ContrastCheck(white, white).text == "1.00:1")
        let failing = ContrastCheck(PickedColor(hex: "#777777")!, white)
        #expect(failing.text == "4.47:1")
        #expect(!failing.normalTextAA && failing.largeTextAA)
        let passing = ContrastCheck(white, PickedColor(hex: "#767676")!)
        #expect(passing.text == "4.54:1")
        #expect(passing.normalTextAA && passing.largeTextAAA && !passing.normalTextAAA)
    }
}

@Suite struct ColorPaletteTests {
    private let palette = ColorPalette(name: "Màu Đỏ Brand", colors: [
        PickedColor(hex: "#3352D6")!, PickedColor(hex: "#FF0000")!, PickedColor(hex: "#3352D6")!,
    ])

    @Test func aColorIsKeptOnce() {
        #expect(palette.colors.map(\.hex) == ["#3352D6", "#FF0000"])
        var copy = palette
        copy.remove(PickedColor(hex: "#3352D6")!)
        #expect(copy.colors.map(\.hex) == ["#FF0000"])
    }

    @Test func everyExportFormat() {
        #expect(palette.export(.css) == ":root {\n  --mau-do-brand-1: #3352D6;\n  --mau-do-brand-2: #FF0000;\n}")
        #expect(palette.export(.tailwind) == "@theme {\n  --color-mau-do-brand-1: #3352D6;\n  --color-mau-do-brand-2: #FF0000;\n}")
        #expect(palette.export(.json) == "{\n  \"name\": \"Màu Đỏ Brand\",\n  \"colors\": [\n    \"#3352D6\",\n    \"#FF0000\"\n  ]\n}")
        #expect(palette.export(.swiftUI) == """
            import SwiftUI

            extension Color {
                static let mauDoBrand1 = Color(red: 0.200, green: 0.322, blue: 0.839)
                static let mauDoBrand2 = Color(red: 1.000, green: 0.000, blue: 0.000)
            }
            """)
    }

    /// A name with nothing usable, or starting with a digit, still gives a valid identifier.
    @Test func namesThatCannotStartAnIdentifier() {
        #expect(ColorPalette.words("") == ["palette"])
        #expect(ColorPalette.words("2026 Brand") == ["palette", "2026", "Brand"])
        #expect(ColorPalette(name: "🎨", colors: [PickedColor(hex: "#000000")!]).export(.css) == ":root {\n  --palette-1: #000000;\n}")
        #expect(ColorPalette(name: "Palette 1", colors: [PickedColor(hex: "#000000")!]).export(.swiftUI).contains("static let palette1_1 = "))
    }

    @Test func palettesRoundTrip() throws {
        let store = ColorPaletteStore(dbQueue: try AppDatabase(inMemory: DatabaseQueue()).dbQueue)
        #expect(try store.load().isEmpty)
        try store.save([palette, ColorPalette(name: "Empty")])
        #expect(try store.load() == [palette, ColorPalette(id: try store.load()[1].id, name: "Empty")])
    }
}
