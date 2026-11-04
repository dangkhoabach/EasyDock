import CoreGraphics

/// The rules of Always on Top. macOS lets no app put another app's window
/// above the one in front, so EasyDock shows a live copy of a pinned window
/// in a floating panel of its own while the real one is behind.
public enum AlwaysOnTop {
    /// Each copy is a live capture; a few at most.
    public static let limit = 3

    public enum Toggle: Equatable, Sendable {
        case pinned, unpinned
        /// Already `limit` windows pinned; nothing changed.
        case full
    }

    /// Pins a window, or unpins it when it is pinned. The newest pin is last,
    /// and its copy is drawn above the others.
    public static func toggle(_ windowID: UInt32, in pinned: [UInt32]) -> ([UInt32], Toggle) {
        if pinned.contains(windowID) { return (pinned.filter { $0 != windowID }, .unpinned) }
        guard pinned.count < limit else { return (pinned, .full) }
        return (pinned + [windowID], .pinned)
    }

    /// The copy covers the window whenever the window itself isn't the one
    /// in use: its app is behind, or another of the app's windows is focused.
    /// A hidden app, a minimized window or one on a desktop not on screen
    /// has nothing to show.
    public static func showsCopy(
        windowID: UInt32, pid: Int32, frontPID: Int32?, focusedWindowID: UInt32?,
        isHidden: Bool, isMinimized: Bool, isOnShownDesktop: Bool
    ) -> Bool {
        guard !isHidden, !isMinimized, isOnShownDesktop else { return false }
        return !(frontPID == pid && focusedWindowID == windowID)
    }

    /// Accessibility and the window server measure from the top left of the
    /// main display, AppKit from its bottom left.
    public static func appKitFrame(_ frame: CGRect, mainDisplayHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: mainDisplayHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
