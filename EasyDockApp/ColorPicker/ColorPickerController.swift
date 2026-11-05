import AppKit
import EasyDockCore
import Observation
import os

/// Color Picker: the system's magnifier (`NSColorSampler`, which needs no
/// Screen Recording permission), the color converted to sRGB and copied in
/// the chosen format, the pinned and last colors picked, and the palettes.
@MainActor
@Observable
final class ColorPickerController {
    static let shared = ColorPickerController()

    private(set) var history = ColorHistory()
    private(set) var palettes: [ColorPalette] = []
    @ObservationIgnored private var isPicking = false
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.easydock", category: "color-picker")

    private var store: ColorHistoryStore? { AppDatabase.shared.map { ColorHistoryStore(dbQueue: $0.dbQueue) } }
    private var paletteStore: ColorPaletteStore? { AppDatabase.shared.map { ColorPaletteStore(dbQueue: $0.dbQueue) } }

    private init() {}

    func start() {
        history = (try? store?.load()) ?? ColorHistory()
        palettes = (try? paletteStore?.load()) ?? []
    }

    /// The panel closes first, so the magnifier can reach what it covered.
    func pick() {
        guard !isPicking else { return }
        isPicking = true
        StatusBarController.shared.closePanel()
        showSampler()
    }

    /// A pick made with Shift held opens the magnifier again for the next one.
    private func showSampler() {
        NSColorSampler().show { picked in
            let keepPicking = picked != nil && Self.isShiftDown
            // The display's color space (Display P3 on most Macs) turned into
            // sRGB here; taking the P3 components as they are gives a value
            // that is off on the web.
            let srgb = picked?.usingColorSpace(.sRGB)
            let components = srgb.map { (Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent)) }
            Task { @MainActor in ColorPickerController.shared.finishPicking(components, keepPicking: keepPicking) }
        }
    }

    /// `NSEvent.modifierFlags` can lag a key pressed just before the click;
    /// the hardware state never does.
    private nonisolated static var isShiftDown: Bool {
        NSEvent.modifierFlags.contains(.shift) || CGEventSource.flagsState(.hidSystemState).contains(.maskShift)
    }

    func copy(_ color: PickedColor, as format: ColorFormat? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(color.string(format ?? SettingsViewModel.shared.settings.colorPickerFormat), forType: .string)
    }

    func clearRecent() {
        update { try $0.clearRecent() }
    }

    func pin(_ color: PickedColor) { update { try $0.pin(color) } }
    func unpin(_ color: PickedColor) { update { try $0.unpin(color) } }
    func remove(_ color: PickedColor) { update { try $0.remove(color) } }

    private func update(_ change: (ColorHistoryStore) throws -> ColorHistory) {
        guard let store, let changed = try? change(store) else { return }
        history = changed
    }

    private func finishPicking(_ components: (Double, Double, Double)?, keepPicking: Bool) {
        guard let (red, green, blue) = components else {
            isPicking = false
            return
        }
        let color = PickedColor(red: red, green: green, blue: blue)
        copy(color)
        update { try $0.add(color) }
        log.info("color picked and copied")
        guard keepPicking else {
            isPicking = false
            return
        }
        // Opened again from the callback, or on the next pass of the run
        // loop, the magnifier cancels at once; a tenth of a second later it
        // holds.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            showSampler()
        }
    }

    // MARK: Palettes

    func addPalette(with color: PickedColor? = nil) {
        var palette = ColorPalette(name: String(localized: "Palette \(palettes.count + 1)", bundle: AppLocale.bundle))
        if let color { palette.add(color) }
        palettes.append(palette)
        savePalettes()
    }

    func deletePalette(_ id: ColorPalette.ID) {
        palettes.removeAll { $0.id == id }
        savePalettes()
    }

    func rename(_ id: ColorPalette.ID, to name: String) {
        guard let index = palettes.firstIndex(where: { $0.id == id }) else { return }
        palettes[index].name = name
        savePalettes()
    }

    func add(_ color: PickedColor, to id: ColorPalette.ID) {
        guard let index = palettes.firstIndex(where: { $0.id == id }) else { return }
        palettes[index].add(color)
        savePalettes()
    }

    func remove(_ color: PickedColor, from id: ColorPalette.ID) {
        guard let index = palettes.firstIndex(where: { $0.id == id }) else { return }
        palettes[index].remove(color)
        savePalettes()
    }

    func copy(_ palette: ColorPalette, as format: PaletteExportFormat) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(palette.export(format), forType: .string)
    }

    private func savePalettes() {
        do {
            try paletteStore?.save(palettes)
        } catch {
            log.error("palettes not saved: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension PaletteExportFormat {
    /// Format names stay as they are; only the plain words are translated.
    var label: String {
        switch self {
        case .css: String(localized: "CSS Variables", bundle: AppLocale.bundle)
        case .json: "JSON"
        case .swiftUI: String(localized: "SwiftUI Color Extension", bundle: AppLocale.bundle)
        case .tailwind: "Tailwind 4 (@theme)"
        }
    }
}

extension ColorFormat {
    /// The same in every language.
    var label: String {
        switch self {
        case .hex: "HEX"
        case .rgb: "RGB (CSS)"
        case .hsl: "HSL (CSS)"
        case .swiftUI: "SwiftUI"
        case .nsColor: "NSColor"
        }
    }
}
