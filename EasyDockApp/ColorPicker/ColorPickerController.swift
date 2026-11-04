import AppKit
import EasyDockCore
import Observation
import os

/// Color Picker: the system's magnifier (`NSColorSampler`, which needs no
/// Screen Recording permission), the color converted to sRGB and copied in
/// the chosen format, and the last colors picked.
@MainActor
@Observable
final class ColorPickerController {
    static let shared = ColorPickerController()

    private(set) var history: [PickedColor] = []
    @ObservationIgnored private var isPicking = false
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.easydock", category: "color-picker")

    private var store: ColorHistoryStore? { AppDatabase.shared.map { ColorHistoryStore(dbQueue: $0.dbQueue) } }

    private init() {}

    func start() {
        history = (try? store?.load()) ?? []
    }

    /// The panel closes first, so the magnifier can reach what it covered.
    func pick() {
        guard !isPicking else { return }
        isPicking = true
        StatusBarController.shared.closePanel()
        NSColorSampler().show { picked in
            // The display's color space (Display P3 on most Macs) turned into
            // sRGB here; taking the P3 components as they are gives a value
            // that is off on the web.
            let srgb = picked?.usingColorSpace(.sRGB)
            let components = srgb.map { (Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent)) }
            Task { @MainActor in ColorPickerController.shared.finishPicking(components) }
        }
    }

    func copy(_ color: PickedColor, as format: ColorFormat? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(color.string(format ?? SettingsViewModel.shared.settings.colorPickerFormat), forType: .string)
    }

    func clearHistory() {
        try? store?.clear()
        history = []
    }

    private func finishPicking(_ components: (Double, Double, Double)?) {
        isPicking = false
        guard let (red, green, blue) = components else { return }
        let color = PickedColor(red: red, green: green, blue: blue)
        copy(color)
        history = (try? store?.add(color)) ?? [color] + history.filter { $0 != color }
        log.info("color picked and copied")
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
