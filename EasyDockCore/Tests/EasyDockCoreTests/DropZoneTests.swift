import CoreGraphics
import Foundation
import Testing
@testable import EasyDockCore

@Suite struct ShakeDetectorTests {
    /// Points every `step` seconds along the given x positions.
    private func feed(_ xs: [CGFloat], step: TimeInterval) -> Bool {
        var detector = ShakeDetector()
        var shook = false
        for (index, x) in xs.enumerated() where detector.add(x: x, at: Double(index) * step) {
            shook = true
        }
        return shook
    }

    @Test func aQuickShakeCounts() {
        #expect(feed([0, 40, 0, 40, 0, 40, 0], step: 0.1))
    }

    /// The same moves spread over two seconds are a slow drag, not a shake.
    @Test func aSlowBackAndForthDoesNot() {
        #expect(!feed([0, 40, 0, 40, 0, 40, 0], step: 0.35))
    }

    @Test func smallWobblesDoNot() {
        #expect(!feed([0, 20, 0, 20, 0, 20, 0, 20, 0], step: 0.05))
    }

    /// A drag that only goes one way, however far and fast.
    @Test func aStraightDragDoesNot() {
        #expect(!feed(Array(stride(from: 0, through: 800, by: 40)), step: 0.02))
    }

    /// Steps in between the turning points don't count as turns.
    @Test func intermediatePointsAreFine() {
        #expect(feed([0, 20, 40, 60, 30, 0, 30, 60, 30, 0, 30, 60], step: 0.04))
    }
}

@Suite struct DropZoneHotZoneTests {
    @Test func theNotchItself() {
        let notch = CGRect(x: 790, y: 1131, width: 220, height: 38)
        #expect(DropZoneHotZone.rect(screen: CGRect(x: 0, y: 0, width: 1800, height: 1169), notch: notch) == notch)
    }

    /// A screen to the right of the built-in one, without a notch.
    @Test func theMiddleOfTheTopEdgeElsewhere() {
        let rect = DropZoneHotZone.rect(screen: CGRect(x: 1800, y: 0, width: 2560, height: 1440), notch: nil)
        #expect(rect == CGRect(x: 2980, y: 1436, width: 200, height: 4))
    }
}

@Suite struct DropShelfTests {
    @Test func noRepeats() {
        var shelf = DropShelf()
        _ = shelf.add([.file("/a"), .text("hi"), .file("/a")])
        _ = shelf.add([.text("hi"), .link("https://example.com")])
        #expect(shelf.items == [.file("/a"), .text("hi"), .link("https://example.com")])
    }

    @Test func theOldestGoPastTheLimit() {
        var shelf = DropShelf()
        _ = shelf.add((0..<DropShelf.limit).map { .file("/\($0)") })
        #expect(shelf.add([.file("/new"), .file("/newer")]) == [.file("/0"), .file("/1")])
        #expect(shelf.items.count == DropShelf.limit)
        #expect(shelf.items.last == .file("/newer"))
    }

    @Test func aMovedFileKeepsItsPlace() {
        var shelf = DropShelf(items: [.file("/a"), .file("/b"), .file("/c")])
        shelf.replace(.file("/b"), with: .file("/moved/b"))
        #expect(shelf.items == [.file("/a"), .file("/moved/b"), .file("/c")])
        // Moved onto a path already on the shelf: listed once.
        shelf.replace(.file("/a"), with: .file("/c"))
        #expect(shelf.items == [.file("/moved/b"), .file("/c")])
        shelf.remove([.file("/c")])
        #expect(shelf.items == [.file("/moved/b")])
    }
}
