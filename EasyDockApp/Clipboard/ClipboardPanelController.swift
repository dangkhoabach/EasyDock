import AppKit
import SwiftUI

/// The clipboard history next to the pointer, on its own shortcut (⌘⇧V by
/// default), for pasting without reaching for the menu bar.
@MainActor
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    static let shared = ClipboardPanelController()
    private static let size = CGSize(width: 380, height: 460)
    private var panel: MenuBarPanel?

    func toggle() {
        if panel?.isVisible == true { close() } else { open() }
    }

    func open() {
        ClipboardStore.shared.refresh()
        let panel = self.panel ?? makePanel()
        let mouse = NSEvent.mouseLocation
        let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let x = min(max(mouse.x - 24, visible.minX + 8), visible.maxX - Self.size.width - 8)
        let y = min(max(mouse.y - Self.size.height - 12, visible.minY + 8), visible.maxY - Self.size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> MenuBarPanel {
        let panel = MenuBarPanel(size: Self.size, rootView: ClipboardPanelRoot())
        panel.delegate = self
        panel.onClose = { [weak self] in self?.close() }
        self.panel = panel
        return panel
    }

    /// A click anywhere else closes it, as a menu would.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// The in-app language for a panel that isn't part of a SwiftUI scene.
private struct ClipboardPanelRoot: View {
    @AppStorage("languagePreference") private var languageRaw = AppLocale.systemDefault.rawValue

    var body: some View {
        ClipboardListView { ClipboardPanelController.shared.close() }
            .environment(\.locale, (AppLocale(rawValue: languageRaw) ?? .systemDefault).locale)
    }
}
