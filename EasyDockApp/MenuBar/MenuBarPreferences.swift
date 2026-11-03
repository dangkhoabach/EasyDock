import Foundation
import Observation
import SwiftUI

/// What the status item shows next to the EasyDock glyph.
enum MenuBarIconMode: String, CaseIterable, Identifiable {
    case glyph, cpuPercent, cpuChart

    var id: Self { self }

    var label: LocalizedStringKey {
        switch self {
        case .glyph: "Icon only"
        case .cpuPercent: "Icon + CPU %"
        case .cpuChart: "Icon + CPU chart"
        }
    }

    /// Only these two keep sampling the CPU while the panel is closed.
    var needsLiveStats: Bool { self != .glyph }
}

/// Menu bar choices, kept in `UserDefaults` and observable so the status item
/// redraws as soon as Settings changes them.
@MainActor
@Observable
final class MenuBarPreferences {
    static let shared = MenuBarPreferences()
    private static let iconModeKey = "menuBarIconMode"
    private static let tabOrderKey = "menuBarTabOrder"
    static let defaultTabOrder: [MenuBarTab] = [.clipboard, .overview, .cleanup, .system]

    var iconMode: MenuBarIconMode {
        didSet { UserDefaults.standard.set(iconMode.rawValue, forKey: Self.iconModeKey) }
    }

    /// The panel's tabs left to right, which also numbers their ⌘1…⌘4.
    var tabOrder: [MenuBarTab] {
        didSet { UserDefaults.standard.set(tabOrder.map(\.rawValue), forKey: Self.tabOrderKey) }
    }

    private init() {
        iconMode = UserDefaults.standard.string(forKey: Self.iconModeKey).flatMap(MenuBarIconMode.init) ?? .glyph
        let stored = (UserDefaults.standard.stringArray(forKey: Self.tabOrderKey) ?? []).compactMap(MenuBarTab.init)
        tabOrder = Self.normalized(stored)
    }

    /// Each tab exactly once: duplicates dropped, and any tab missing from a
    /// stored order (one added by a later version) appended at the end.
    static func normalized(_ tabs: [MenuBarTab]) -> [MenuBarTab] {
        var order: [MenuBarTab] = []
        for tab in tabs + defaultTabOrder where !order.contains(tab) {
            order.append(tab)
        }
        return order
    }

    /// Moves a tab one place left (`-1`) or right (`+1`); nothing past the ends.
    func move(_ tab: MenuBarTab, by offset: Int) {
        guard let index = tabOrder.firstIndex(of: tab), tabOrder.indices.contains(index + offset) else { return }
        tabOrder.swapAt(index, index + offset)
    }
}

/// The panel's tabs. Their order is the user's (`MenuBarPreferences.tabOrder`).
enum MenuBarTab: String, CaseIterable, Identifiable {
    case overview, clipboard, cleanup, system

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .overview: "Overview"
        case .clipboard: "Clipboard"
        case .cleanup: "Cleanup"
        case .system: "System"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .clipboard: "doc.on.clipboard"
        case .cleanup: "sparkles"
        case .system: "cpu"
        }
    }
}

/// The selected tab, kept across openings of the panel; the first tab of the
/// user's order until they pick another.
@MainActor
@Observable
final class MenuBarNavigation {
    static let shared = MenuBarNavigation()
    var tab: MenuBarTab = MenuBarPreferences.shared.tabOrder.first ?? .clipboard
    private init() {}
}
