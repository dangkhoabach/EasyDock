import CoreGraphics

/// A display as Window Snapping sees it, in Accessibility coordinates.
public struct SnapScreen: Equatable, Sendable {
    /// The display's UUID, which outlives unplugging and rearranging.
    public var id: String
    public var frame: CGRect
    /// Without the menu bar and the Dock.
    public var visibleFrame: CGRect

    public init(id: String, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

public enum SnapScreens {
    /// AppKit counts y upwards from the bottom of the main screen;
    /// Accessibility counts it downwards from its top.
    public static func accessibilityRect(fromAppKit rect: CGRect, mainScreenHeight: Double) -> CGRect {
        CGRect(x: rect.minX, y: mainScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The screen holding most of the window, not the one under its corner:
    /// a window hanging off the left edge of the right screen belongs to the
    /// right one. Off every screen, the nearest one.
    public static func index(of window: CGRect, in screens: [SnapScreen]) -> Int? {
        let areas = screens.map { screen -> Double in
            let overlap = screen.frame.intersection(window)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 { return best }
        let center = CGPoint(x: window.midX, y: window.midY)
        return screens.indices.min { distance(center, screens[$0].frame) < distance(center, screens[$1].frame) }
    }

    public static func index(containing point: CGPoint, in screens: [SnapScreen]) -> Int? {
        screens.firstIndex { $0.frame.contains(point) }
    }

    /// The next or previous screen, left to right and then top to bottom,
    /// going round.
    public static func neighbor(of index: Int, in screens: [SnapScreen], forward: Bool) -> Int {
        let order = screens.indices.sorted {
            let a = screens[$0].frame, b = screens[$1].frame
            return a.minX != b.minX ? a.minX < b.minX : a.minY < b.minY
        }
        guard let position = order.firstIndex(of: index) else { return index }
        return order[(position + (forward ? 1 : order.count - 1)) % order.count]
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
