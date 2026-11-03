import Foundation

/// What a click on the Dock icon of the app in front does.
public enum DockClickPreference: String, Sendable, CaseIterable {
    /// Minimize its windows, then bring the next app forward, as the
    /// Windows taskbar does.
    case minimize
    /// Hide the app, as ⌘H does.
    case hide
}

public enum DockClickAction: Equatable, Sendable {
    /// Leave the click to the Dock.
    case none
    case minimizeWindows
    case hide
    /// Bring back the windows EasyDock minimized; the app has already
    /// restored one of them on its own when the Dock sent it the reopen event.
    case restoreMinimized
}

/// One finished click on an app's Dock icon, as seen at mouse-down — by
/// mouse-up the Dock has already activated the app and its reopen handler
/// has restored a window, so later state can't tell what the user saw.
public struct DockClick: Equatable, Sendable {
    public var appWasInFront: Bool
    public var visibleWindows: Int
    /// Some of the windows EasyDock minimized for this app are still minimized.
    public var hasWindowsMinimizedByEasyDock: Bool
    /// The farthest the pointer got from where the button went down.
    public var travel: Double
    public var heldSeconds: Double
    public var isExcluded: Bool

    public init(appWasInFront: Bool, visibleWindows: Int, hasWindowsMinimizedByEasyDock: Bool,
                travel: Double, heldSeconds: Double, isExcluded: Bool) {
        self.appWasInFront = appWasInFront
        self.visibleWindows = visibleWindows
        self.hasWindowsMinimizedByEasyDock = hasWindowsMinimizedByEasyDock
        self.travel = travel
        self.heldSeconds = heldSeconds
        self.isExcluded = isExcluded
    }
}

public enum DockClickDecision {
    /// More than this and the press was a drag (reordering icons), not a click;
    /// a hand on a trackpad moves a pixel or two during a plain click.
    public static let maxTravel = 4.0
    /// Holding longer opens the Dock's menu.
    public static let maxHeldSeconds = 0.5

    /// Under Stage Manager every click is left to macOS: it ignores
    /// minimizing through Accessibility and arranges the front app itself.
    public static func decide(_ click: DockClick, preference: DockClickPreference, stageManager: Bool) -> DockClickAction {
        guard !stageManager, !click.isExcluded, click.travel <= maxTravel, click.heldSeconds < maxHeldSeconds else { return .none }
        if click.hasWindowsMinimizedByEasyDock, !click.appWasInFront || click.visibleWindows == 0 {
            return .restoreMinimized
        }
        guard click.appWasInFront, click.visibleWindows > 0 else { return .none }
        switch preference {
        case .hide: return .hide
        case .minimize: return .minimizeWindows
        }
    }
}
