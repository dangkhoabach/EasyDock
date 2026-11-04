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
        #expect(try store.load() == [blue, red])
    }

    @Test func theHistoryStopsAtItsLimit() throws {
        let store = ColorHistoryStore(dbQueue: try AppDatabase(inMemory: DatabaseQueue()).dbQueue)
        for value in 0..<(ColorHistoryStore.limit + 5) { try store.add(PickedColor(red: value, green: 0, blue: 0)) }
        let colors = try store.load()
        #expect(colors.count == ColorHistoryStore.limit)
        #expect(colors.first == PickedColor(red: ColorHistoryStore.limit + 4, green: 0, blue: 0))
        try store.clear()
        #expect(try store.load().isEmpty)
    }
}
