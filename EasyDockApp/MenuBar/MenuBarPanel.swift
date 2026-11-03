import AppKit
import SwiftUI

/// The window under the status item, and the clipboard panel. A
/// non-activating panel: it takes the keyboard without bringing EasyDock
/// forward, so the app the user was in stays the active one — which is also
/// where a pasted item goes — and it shows over full-screen apps.
final class MenuBarPanel: NSPanel {
    var onClose: (() -> Void)?

    init<Content: View>(size: CGSize, rootView: Content) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .utilityWindow

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        let hosting = NSHostingView(rootView: rootView)
        // The panel keeps a hidden title bar for the system's rounded corners
        // and shadow; SwiftUI would otherwise inset the content by its height,
        // leaving an empty band above the header.
        hosting.safeAreaRegions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
    }

    override var canBecomeKey: Bool { true }

    /// Esc.
    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }
}
