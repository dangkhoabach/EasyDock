import Foundation

/// What Window Snapping can do to the window in front.
public enum SnapAction: String, CaseIterable, Codable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf, centerHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
    case topLeftSixth, topCenterSixth, topRightSixth, bottomLeftSixth, bottomCenterSixth, bottomRightSixth
    case maximize, almostMaximize, maximizeHeight, center
    case larger, smaller
    case moveLeft, moveRight, moveUp, moveDown
    case nextDisplay, previousDisplay
    case restore

    public enum Group: CaseIterable, Sendable {
        case halves, quarters, thirds, sixths, maximize, size, move, display
    }

    public var group: Group {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf, .centerHalf: .halves
        case .topLeft, .topRight, .bottomLeft, .bottomRight: .quarters
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds: .thirds
        case .topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth: .sixths
        case .maximize, .almostMaximize, .maximizeHeight, .center, .restore: .maximize
        case .larger, .smaller: .size
        case .moveLeft, .moveRight, .moveUp, .moveDown: .move
        case .nextDisplay, .previousDisplay: .display
        }
    }

    /// Pressing the same shortcut again steps through 1/2, 2/3 and 1/3.
    public var cycles: Bool { group == .halves && self != .centerHalf || group == .quarters }
}

/// What a snap area does: one of the actions, or a custom size.
public enum SnapTarget: Hashable, Sendable {
    case action(SnapAction)
    case custom(UUID)

    /// "leftHalf", or "custom:<UUID>".
    public var stored: String {
        switch self {
        case .action(let action): action.rawValue
        case .custom(let id): "custom:\(id.uuidString)"
        }
    }

    public init?(stored: String) {
        if stored.hasPrefix("custom:") {
            guard let id = UUID(uuidString: String(stored.dropFirst("custom:".count))) else { return nil }
            self = .custom(id)
        } else if let action = SnapAction(rawValue: stored) {
            self = .action(action)
        } else {
            return nil
        }
    }
}
