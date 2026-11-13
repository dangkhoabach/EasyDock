import CoreGraphics

/// A part of the screen as fractions of its usable area: 0 is the left or
/// top edge, 1 the right or bottom one.
public struct UnitRect: Codable, Equatable, Sendable {
    public var x0: Double
    public var y0: Double
    public var x1: Double
    public var y1: Double

    public init(x0: Double, y0: Double, x1: Double, y1: Double) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }
}

/// Where each action puts a window. Every rectangle is in Accessibility
/// coordinates (origin at the top left of the main screen, y downwards),
/// and `visible` is the screen's area without the menu bar and the Dock.
public enum SnapGeometry {
    /// Pressing a half or a quarter again: half, two thirds, one third.
    public static let cycleSpans: [Double] = [1.0 / 2, 2.0 / 3, 1.0 / 3]
    /// Larger and Smaller move each free edge by this much.
    public static let sizeStep: Double = 30
    /// Smaller stops before a side gets shorter than this.
    public static let minimumSide: Double = 160
    /// macOS rounds frames to whole points and keeps a window that reaches the
    /// Dock 1 pt above it, so frames this close count as the same.
    public static let tolerance: Double = 2

    public static func isLandscape(_ visible: CGRect) -> Bool { visible.width >= visible.height }

    /// The part of the screen an action covers, or nil for an action that
    /// depends on the window itself (Center, Larger, Move…). `step` is the
    /// place in `cycleSpans` for a half or a quarter.
    public static func unitRect(for action: SnapAction, step: Int = 0, landscape: Bool = true) -> UnitRect? {
        let span = cycleSpans[((step % cycleSpans.count) + cycleSpans.count) % cycleSpans.count]
        func band(_ a: Double, _ b: Double) -> UnitRect {
            landscape ? UnitRect(x0: a, y0: 0, x1: b, y1: 1) : UnitRect(x0: 0, y0: a, x1: 1, y1: b)
        }
        func sixth(_ index: Int) -> UnitRect {
            // Read in order, left to right then down: three columns and two
            // rows, or two columns and three rows on a portrait screen.
            let columns = landscape ? 3 : 2, rows = landscape ? 2 : 3
            let column = Double(index % columns), row = Double(index / columns)
            return UnitRect(x0: column / Double(columns), y0: row / Double(rows),
                            x1: (column + 1) / Double(columns), y1: (row + 1) / Double(rows))
        }
        switch action {
        case .leftHalf: return UnitRect(x0: 0, y0: 0, x1: span, y1: 1)
        case .rightHalf: return UnitRect(x0: 1 - span, y0: 0, x1: 1, y1: 1)
        case .topHalf: return UnitRect(x0: 0, y0: 0, x1: 1, y1: span)
        case .bottomHalf: return UnitRect(x0: 0, y0: 1 - span, x1: 1, y1: 1)
        case .centerHalf: return band(0.25, 0.75)
        case .topLeft: return UnitRect(x0: 0, y0: 0, x1: span, y1: 0.5)
        case .topRight: return UnitRect(x0: 1 - span, y0: 0, x1: 1, y1: 0.5)
        case .bottomLeft: return UnitRect(x0: 0, y0: 0.5, x1: span, y1: 1)
        case .bottomRight: return UnitRect(x0: 1 - span, y0: 0.5, x1: 1, y1: 1)
        case .firstThird: return band(0, 1.0 / 3)
        case .centerThird: return band(1.0 / 3, 2.0 / 3)
        case .lastThird: return band(2.0 / 3, 1)
        case .firstTwoThirds: return band(0, 2.0 / 3)
        case .lastTwoThirds: return band(1.0 / 3, 1)
        case .topLeftSixth: return sixth(0)
        case .topCenterSixth: return sixth(1)
        case .topRightSixth: return sixth(2)
        case .bottomLeftSixth: return sixth(3)
        case .bottomCenterSixth: return sixth(4)
        case .bottomRightSixth: return sixth(5)
        case .maximize: return UnitRect(x0: 0, y0: 0, x1: 1, y1: 1)
        case .almostMaximize: return UnitRect(x0: 0.05, y0: 0.05, x1: 0.95, y1: 0.95)
        case .maximizeHeight, .center, .larger, .smaller, .moveLeft, .moveRight, .moveUp, .moveDown,
             .nextDisplay, .previousDisplay, .restore:
            return nil
        }
    }

    /// `unit` on the screen, in whole points. A side on the screen's edge is
    /// `gap` from it; a side inside is half a gap from the line it shares
    /// with its neighbour, so two windows side by side are a whole gap apart.
    /// The shared line is rounded once, for both of them: rounding each
    /// window's width instead left them overlapping or 1 pt apart.
    public static func region(_ unit: UnitRect, in visible: CGRect, gap: Double) -> CGRect {
        func line(_ fraction: Double, _ start: Double, _ length: Double) -> Double {
            (start + length * fraction).rounded()
        }
        func inset(_ fraction: Double) -> Double {
            fraction <= 0.0001 || fraction >= 0.9999 ? gap : gap / 2
        }
        let left = (line(unit.x0, visible.minX, visible.width) + inset(unit.x0)).rounded()
        let right = (line(unit.x1, visible.minX, visible.width) - inset(unit.x1)).rounded()
        let top = (line(unit.y0, visible.minY, visible.height) + inset(unit.y0)).rounded()
        let bottom = (line(unit.y1, visible.minY, visible.height) - inset(unit.y1)).rounded()
        return CGRect(x: left, y: top, width: max(1, right - left), height: max(1, bottom - top))
    }

    /// The frame `action` gives a window now at `current`. Nil for Restore
    /// and the display moves, which need more than one screen's geometry.
    public static func frame(for action: SnapAction, step: Int = 0, current: CGRect, visible: CGRect, gap: Double) -> CGRect? {
        if let unit = unitRect(for: action, step: step, landscape: isLandscape(visible)) {
            return region(unit, in: visible, gap: gap)
        }
        let area = visible.insetBy(dx: gap, dy: gap)
        let size = CGSize(width: min(current.width, area.width), height: min(current.height, area.height))
        switch action {
        case .maximizeHeight:
            let x = clamp(current.minX, area.minX, area.maxX - size.width)
            return CGRect(x: x, y: area.minY, width: size.width, height: area.height).integral
        case .center:
            return CGRect(x: (area.midX - size.width / 2).rounded(), y: (area.midY - size.height / 2).rounded(),
                          width: size.width.rounded(), height: size.height.rounded())
        case .larger, .smaller:
            let delta = action == .larger ? sizeStep : -sizeStep
            let (x0, x1) = resize(current.minX, current.maxX, within: area.minX, area.maxX, by: delta)
            let (y0, y1) = resize(current.minY, current.maxY, within: area.minY, area.maxY, by: delta)
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).integral
        case .moveLeft, .moveRight, .moveUp, .moveDown:
            var x = clamp(current.minX, area.minX, area.maxX - size.width)
            var y = clamp(current.minY, area.minY, area.maxY - size.height)
            switch action {
            case .moveLeft: x = area.minX
            case .moveRight: x = area.maxX - size.width
            case .moveUp: y = area.minY
            default: y = area.maxY - size.height
            }
            return CGRect(x: x.rounded(), y: y.rounded(), width: size.width.rounded(), height: size.height.rounded())
        default:
            return nil
        }
    }

    /// Larger moves each edge that isn't against the screen out by `delta`;
    /// an edge already against it stays, and the other one moves twice as
    /// far, so a window in a corner grows into the screen. Smaller is the
    /// reverse, except that a window across the whole screen shrinks from
    /// both sides. Too small to shrink, it stays as it is.
    static func resize(_ low: Double, _ high: Double, within start: Double, _ end: Double, by delta: Double) -> (Double, Double) {
        let atStart = abs(low - start) <= tolerance, atEnd = abs(high - end) <= tolerance
        var newLow = low, newHigh = high
        let step = abs(delta)
        if delta > 0 {
            switch (atStart, atEnd) {
            case (false, false): newLow -= step; newHigh += step
            case (true, false): newHigh += 2 * step
            case (false, true): newLow -= 2 * step
            case (true, true): break
            }
            return (max(newLow, start), min(newHigh, end))
        }
        switch (atStart, atEnd) {
        case (true, false): newHigh -= 2 * step
        case (false, true): newLow += 2 * step
        default: newLow += step; newHigh -= step
        }
        return newHigh - newLow < minimumSide ? (low, high) : (newLow, newHigh)
    }

    /// The step to use when `action` is pressed with the window at
    /// `current`: the one after the step whose frame it is in, else the first.
    public static func nextStep(for action: SnapAction, current: CGRect, visible: CGRect, gap: Double) -> Int {
        guard action.cycles else { return 0 }
        for step in cycleSpans.indices {
            if let frame = frame(for: action, step: step, current: current, visible: visible, gap: gap), matches(frame, current) {
                return (step + 1) % cycleSpans.count
            }
        }
        return 0
    }

    public static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.maxX - b.maxX) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
    }

    /// Where a window that came out `actual` big instead of `target` goes,
    /// because the app won't let it be smaller: against the same side as the
    /// target (the right half stays against the right edge), centred if the
    /// target was, and inside the screen when it fits.
    public static func origin(for actual: CGSize, target: CGRect, visible: CGRect) -> CGPoint {
        func axis(_ length: Double, _ targetMin: Double, _ targetMax: Double, _ start: Double, _ end: Double) -> Double {
            guard length > targetMax - targetMin + tolerance else { return targetMin }
            let targetMid = (targetMin + targetMax) / 2, middle = (start + end) / 2
            let value: Double
            if abs(targetMid - middle) <= tolerance {
                value = targetMid - length / 2
            } else if targetMid > middle {
                value = targetMax - length
            } else {
                value = targetMin
            }
            return length >= end - start ? start : clamp(value, start, end - length)
        }
        return CGPoint(x: axis(actual.width, target.minX, target.maxX, visible.minX, visible.maxX).rounded(),
                       y: axis(actual.height, target.minY, target.maxY, visible.minY, visible.maxY).rounded())
    }

    /// The same place and size on another screen, in proportion: a window
    /// on the left half of one screen lands on the left half of the next.
    public static func move(_ frame: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        let scaleX = destination.width / source.width, scaleY = destination.height / source.height
        let width = min(frame.width * scaleX, destination.width).rounded()
        let height = min(frame.height * scaleY, destination.height).rounded()
        let x = clamp(destination.minX + (frame.minX - source.minX) * scaleX, destination.minX, destination.maxX - width)
        let y = clamp(destination.minY + (frame.minY - source.minY) * scaleY, destination.minY, destination.maxY - height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }

    static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        high < low ? low : min(max(value, low), high)
    }
}
