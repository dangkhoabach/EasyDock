import CoreGraphics
import Foundation

/// A shake while dragging: the pointer turning back and forth sideways,
/// at least `minimumTurns` times within `window`, each leg `minimumTravel`
/// points or more. Small wobbles and slow drags never count.
public struct ShakeDetector: Sendable {
    public static let minimumTravel: CGFloat = 30
    public static let minimumTurns = 4
    public static let window: TimeInterval = 0.6

    private var extreme: CGFloat?
    private var direction: CGFloat = 0
    private var turns: [TimeInterval] = []

    public init() {}

    /// Feeds one pointer position; true once the moves so far make a shake.
    public mutating func add(x: CGFloat, at time: TimeInterval) -> Bool {
        guard let last = extreme else {
            extreme = x
            return false
        }
        let travel = x - last
        if direction == 0 {
            if abs(travel) >= Self.minimumTravel {
                direction = travel > 0 ? 1 : -1
                extreme = x
            }
        } else if travel * direction > 0 {
            extreme = x
        } else if abs(travel) >= Self.minimumTravel {
            direction = -direction
            extreme = x
            turns = turns.filter { time - $0 < Self.window } + [time]
        }
        return turns.count >= Self.minimumTurns
    }
}

/// Where dragging a file onto the top of a screen opens the Drop Zone: the
/// notch, or on a screen without one a stretch of the same width in the
/// middle of its top edge, where the menu bar usually has nothing.
public enum DropZoneHotZone {
    public static let edgeDepth: CGFloat = 4
    public static let width: CGFloat = 200

    /// In AppKit's coordinates (origin at the bottom left). `notch` is the
    /// gap between the screen's two auxiliary top areas, when it has them.
    public static func rect(screen: CGRect, notch: CGRect?) -> CGRect {
        if let notch { return notch }
        return CGRect(x: screen.midX - width / 2, y: screen.maxY - edgeDepth, width: width, height: edgeDepth)
    }
}

/// What the Drop Zone holds.
public enum ShelfItem: Hashable, Sendable {
    /// A file or folder, by its path when it was dropped.
    case file(String)
    /// A web link.
    case link(String)
    case text(String)
}

/// The Drop Zone's items, oldest first, without repeats and up to `limit`.
public struct DropShelf: Equatable, Sendable {
    public static let limit = 50
    public private(set) var items: [ShelfItem] = []

    public init(items: [ShelfItem] = []) {
        self.items = []
        _ = add(items)
    }

    /// Adds what isn't there yet; returns the oldest items pushed out to
    /// stay within the limit.
    public mutating func add(_ new: [ShelfItem]) -> [ShelfItem] {
        for item in new where !items.contains(item) {
            items.append(item)
        }
        let overflow = max(0, items.count - Self.limit)
        let dropped = Array(items.prefix(overflow))
        items.removeFirst(overflow)
        return dropped
    }

    public mutating func remove(_ removed: [ShelfItem]) {
        items.removeAll { removed.contains($0) }
    }

    /// A file that was moved: same place in the list, new path.
    public mutating func replace(_ old: ShelfItem, with new: ShelfItem) {
        guard let index = items.firstIndex(of: old) else { return }
        if items.contains(new) {
            items.remove(at: index)
        } else {
            items[index] = new
        }
    }
}
