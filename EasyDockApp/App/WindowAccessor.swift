import AppKit
import SwiftUI

/// The red close button hides the app instead of destroying the window, and
/// drops the Dock icon: EasyDock keeps working from the menu bar.
final class HideInsteadOfCloseDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // `orderOut` alone leaves a window macOS still counts as open, and
        // Stage Manager kept a blank tile for it; hiding the app (as ⌘H does)
        // takes it out of Stage Manager, Mission Control and ⌘Tab.
        NSApp.hide(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }
}

/// Reaches the `WindowGroup`'s `NSWindow` once to set the delegate above and
/// let the content run under a transparent title bar, as in the sibling apps.
struct WindowAccessor: NSViewRepresentable {
    let delegate: HideInsteadOfCloseDelegate

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.delegate = delegate
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
