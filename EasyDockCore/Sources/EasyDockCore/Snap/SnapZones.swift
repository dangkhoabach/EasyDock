import CoreGraphics

/// The places at a screen's edges where dropping a window snaps it.
public enum SnapZone: String, CaseIterable, Codable, Sendable {
    case topLeft, top, topRight
    case left, right
    case bottomLeft, bottomLeftThird, bottomCenterThird, bottomRightThird, bottomRight
}

public enum SnapZones {
    /// How close to the edge the pointer has to be.
    public static let edgeDistance: Double = 4
    /// How far from a corner, along either edge, the corner still counts.
    public static let cornerLength: Double = 24

    public static let defaults: [SnapZone: SnapTarget] = [
        .topLeft: .action(.topLeft), .top: .action(.maximize), .topRight: .action(.topRight),
        .left: .action(.leftHalf), .right: .action(.rightHalf),
        .bottomLeft: .action(.bottomLeft), .bottomRight: .action(.bottomRight),
        .bottomLeftThird: .action(.firstThird), .bottomCenterThird: .action(.centerThird),
        .bottomRightThird: .action(.lastThird),
    ]

    /// The zone under `point` on the screen whose frame is `screen`. An edge
    /// another screen continues from has no zone where the two meet, so a
    /// window can still be dragged across.
    public static func zone(at point: CGPoint, screen: CGRect, otherScreens: [CGRect]) -> SnapZone? {
        // The pointer stops 1 pt short of the right and bottom edges.
        let fromLeft = point.x - screen.minX, fromRight = screen.maxX - 1 - point.x
        let fromTop = point.y - screen.minY, fromBottom = screen.maxY - 1 - point.y
        guard min(fromLeft, fromRight, fromTop, fromBottom) >= -1 else { return nil }

        let leftOpen = !otherScreens.contains { abs($0.maxX - screen.minX) < 1 && $0.minY <= point.y && point.y < $0.maxY }
        let rightOpen = !otherScreens.contains { abs($0.minX - screen.maxX) < 1 && $0.minY <= point.y && point.y < $0.maxY }
        let topOpen = !otherScreens.contains { abs($0.maxY - screen.minY) < 1 && $0.minX <= point.x && point.x < $0.maxX }
        let bottomOpen = !otherScreens.contains { abs($0.minY - screen.maxY) < 1 && $0.minX <= point.x && point.x < $0.maxX }

        let atLeft = leftOpen && fromLeft <= edgeDistance, atRight = rightOpen && fromRight <= edgeDistance
        let atTop = topOpen && fromTop <= edgeDistance, atBottom = bottomOpen && fromBottom <= edgeDistance
        let nearLeft = fromLeft <= cornerLength, nearRight = fromRight <= cornerLength
        let nearTop = fromTop <= cornerLength, nearBottom = fromBottom <= cornerLength

        if (atLeft && nearTop) || (atTop && nearLeft) { return .topLeft }
        if (atRight && nearTop) || (atTop && nearRight) { return .topRight }
        if (atLeft && nearBottom) || (atBottom && nearLeft) { return .bottomLeft }
        if (atRight && nearBottom) || (atBottom && nearRight) { return .bottomRight }
        if atTop { return .top }
        if atLeft { return .left }
        if atRight { return .right }
        if atBottom {
            let across = fromLeft / screen.width
            return across < 1.0 / 3 ? .bottomLeftThird : across < 2.0 / 3 ? .bottomCenterThird : .bottomRightThird
        }
        return nil
    }

    /// "zone=target" lines, with "none" for a zone the user emptied, so it
    /// doesn't come back as its default.
    public static func encode(_ map: [SnapZone: SnapTarget]) -> String {
        SnapZone.allCases.map { "\($0.rawValue)=\(map[$0]?.stored ?? "none")" }.joined(separator: "\n")
    }

    /// A zone missing from `text`, one added in a later version say, gets
    /// its default.
    public static func decode(_ text: String) -> [SnapZone: SnapTarget] {
        var map = defaults
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let zone = SnapZone(rawValue: parts[0]) else { continue }
            map[zone] = SnapTarget(stored: parts[1])
        }
        return map
    }
}
