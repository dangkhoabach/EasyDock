import SwiftUI

/// Top-level sidebar sections. Settings is one tab among these, reached from
/// the app menu (⌘,) and the menu bar extra alike.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case dockWindows, snap, clipboard, tools, system, cleanup, settings

    var id: Self { self }

    /// The sidebar's groups, in order; Settings is pinned under them.
    static var groups: [(title: LocalizedStringKey, sections: [SidebarSection])] { [
        ("Windows", [.dockWindows, .snap]),
        ("Productivity", [.clipboard, .tools]),
        ("Maintenance", [.system, .cleanup]),
    ] }

    /// `LocalizedStringKey`, not `String`: only that overload of `Text` reads
    /// the String Catalog.
    var title: LocalizedStringKey {
        switch self {
        case .dockWindows: "Dock & Windows"
        case .snap: "Window Snapping"
        case .clipboard: "Clipboard"
        case .tools: "Tools"
        case .system: "System"
        case .cleanup: "Cleanup"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dockWindows: "dock.rectangle"
        case .snap: "rectangle.split.2x1"
        case .clipboard: "doc.on.clipboard"
        case .tools: "wrench.and.screwdriver"
        case .system: "cpu"
        case .cleanup: "sparkles"
        case .settings: "gearshape"
        }
    }
}
