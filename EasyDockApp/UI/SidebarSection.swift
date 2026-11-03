import SwiftUI

/// Top-level sidebar sections. Settings is one tab among these, reached from
/// the app menu (⌘,) and the menu bar extra alike.
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case dockWindows, clipboard, system, cleanup, settings

    var id: Self { self }

    /// `LocalizedStringKey`, not `String`: only that overload of `Text` reads
    /// the String Catalog.
    var title: LocalizedStringKey {
        switch self {
        case .dockWindows: "Dock & Windows"
        case .clipboard: "Clipboard"
        case .system: "System"
        case .cleanup: "Cleanup"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .dockWindows: "dock.rectangle"
        case .clipboard: "doc.on.clipboard"
        case .system: "cpu"
        case .cleanup: "sparkles"
        case .settings: "gearshape"
        }
    }
}
