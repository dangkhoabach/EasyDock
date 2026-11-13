import CoreGraphics
import Foundation
import GRDB
import Testing
@testable import EasyDockCore

/// A 1800 × 1169 pt screen with a 39 pt menu bar and a 77 pt Dock, as on the
/// MacBook the feature was tried on.
private let visible = CGRect(x: 0, y: 39, width: 1800, height: 1053)
private let portrait = CGRect(x: 0, y: 0, width: 1080, height: 1920)

private func frame(_ action: SnapAction, step: Int = 0, current: CGRect = CGRect(x: 300, y: 300, width: 600, height: 400),
                   in area: CGRect = visible, gap: Double = 0) -> CGRect {
    SnapGeometry.frame(for: action, step: step, current: current, visible: area, gap: gap)!
}

@Suite struct SnapGeometryTests {
    @Test func halvesSplitTheUsableArea() {
        #expect(frame(.leftHalf) == CGRect(x: 0, y: 39, width: 900, height: 1053))
        #expect(frame(.rightHalf) == CGRect(x: 900, y: 39, width: 900, height: 1053))
        #expect(frame(.centerHalf) == CGRect(x: 450, y: 39, width: 900, height: 1053))
        #expect(frame(.maximize) == visible)
    }

    /// 1053 doesn't halve: the shared line is rounded once, so the two
    /// halves meet exactly instead of overlapping or leaving a gap.
    @Test func neighboursShareTheRoundedLine() {
        let top = frame(.topHalf), bottom = frame(.bottomHalf)
        #expect(top == CGRect(x: 0, y: 39, width: 1800, height: 527))
        #expect(bottom == CGRect(x: 0, y: 566, width: 1800, height: 526))
        #expect(top.maxY == bottom.minY)
    }

    /// Every set of tiles covers the screen once, landscape and portrait.
    @Test(arguments: [visible, portrait, CGRect(x: -1366, y: -200, width: 1366, height: 745)])
    func tilesCoverTheScreenWithoutOverlapping(_ area: CGRect) {
        let sets: [[SnapAction]] = [
            [.leftHalf, .rightHalf], [.topHalf, .bottomHalf],
            [.topLeft, .topRight, .bottomLeft, .bottomRight],
            [.firstThird, .centerThird, .lastThird], [.firstTwoThirds, .lastThird], [.firstThird, .lastTwoThirds],
            [.topLeftSixth, .topCenterSixth, .topRightSixth, .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth],
        ]
        for set in sets {
            let tiles = set.map { frame($0, in: area) }
            #expect(tiles.reduce(0) { $0 + $1.width * $1.height } == area.width * area.height, "\(set)")
            for (i, a) in tiles.enumerated() {
                #expect(area.contains(a), "\(set[i])")
                for b in tiles[(i + 1)...] { #expect(a.intersection(b).width * a.intersection(b).height == 0, "\(set)") }
            }
        }
    }

    @Test func aPortraitScreenSplitsIntoRows() {
        #expect(frame(.firstThird, in: portrait) == CGRect(x: 0, y: 0, width: 1080, height: 640))
        #expect(frame(.lastTwoThirds, in: portrait) == CGRect(x: 0, y: 640, width: 1080, height: 1280))
        // Sixths are read in order: two columns, three rows.
        #expect(frame(.topRightSixth, in: portrait) == CGRect(x: 0, y: 640, width: 540, height: 640))
        #expect(frame(.bottomRightSixth, in: portrait) == CGRect(x: 540, y: 1280, width: 540, height: 640))
        // Halves stay what their name says.
        #expect(frame(.leftHalf, in: portrait) == CGRect(x: 0, y: 0, width: 540, height: 1920))
    }

    @Test func aGapSeparatesWindowsAndTheScreenEdges() {
        let left = frame(.leftHalf, gap: 10), right = frame(.rightHalf, gap: 10)
        #expect(left == CGRect(x: 10, y: 49, width: 885, height: 1033))
        #expect(right == CGRect(x: 905, y: 49, width: 885, height: 1033))
        // An odd gap still leaves exactly that much between them.
        #expect(frame(.rightHalf, gap: 5).minX - frame(.leftHalf, gap: 5).maxX == 5)
        let quarters = [frame(.topLeft, gap: 8), frame(.bottomLeft, gap: 8)]
        #expect(quarters[1].minY - quarters[0].maxY == 8)
    }

    @Test func halvesAndQuartersCycleThroughTwoThirdsAndOneThird() {
        var window = CGRect(x: 300, y: 300, width: 600, height: 400)
        var widths: [Double] = []
        for _ in 0..<4 {
            let step = SnapGeometry.nextStep(for: .leftHalf, current: window, visible: visible, gap: 0)
            window = frame(.leftHalf, step: step)
            widths.append(window.width)
        }
        #expect(widths == [900, 1200, 600, 900])
        #expect(frame(.rightHalf, step: 1) == CGRect(x: 600, y: 39, width: 1200, height: 1053))
        #expect(frame(.bottomRight, step: 2) == CGRect(x: 1200, y: 566, width: 600, height: 526))
        #expect(frame(.topHalf, step: 1).height == 702)
    }

    /// macOS keeps a window reaching the Dock 1 pt short; it still counts.
    @Test func aWindowAPointShortStillCycles() {
        let short = CGRect(x: 0, y: 39, width: 900, height: 1052)
        #expect(SnapGeometry.nextStep(for: .leftHalf, current: short, visible: visible, gap: 0) == 1)
        // A half pressed on the other side starts again.
        #expect(SnapGeometry.nextStep(for: .rightHalf, current: short, visible: visible, gap: 0) == 0)
    }

    @Test func onlyHalvesAndQuartersCycle() {
        let third = frame(.firstThird)
        #expect(SnapGeometry.nextStep(for: .firstThird, current: third, visible: visible, gap: 0) == 0)
        let middle = frame(.centerHalf)
        #expect(SnapGeometry.nextStep(for: .centerHalf, current: middle, visible: visible, gap: 0) == 0)
    }

    @Test func centerAndMaximizeHeightKeepTheWindowsSize() {
        #expect(frame(.center) == CGRect(x: 600, y: 366, width: 600, height: 400))
        #expect(frame(.maximizeHeight) == CGRect(x: 300, y: 39, width: 600, height: 1053))
        // Larger than the screen, it is made to fit.
        #expect(frame(.center, current: CGRect(x: 0, y: 0, width: 3000, height: 2000)) == visible)
        #expect(frame(.almostMaximize) == CGRect(x: 90, y: 92, width: 1620, height: 947))
    }

    @Test func largerGrowsAwayFromTheEdgesItTouches() {
        #expect(frame(.larger) == CGRect(x: 270, y: 270, width: 660, height: 460))
        #expect(frame(.larger, current: frame(.leftHalf)) == CGRect(x: 0, y: 39, width: 960, height: 1053))
        // Not past the screen.
        #expect(frame(.larger, current: CGRect(x: 20, y: 300, width: 600, height: 400)) == CGRect(x: 0, y: 270, width: 650, height: 460))
        #expect(frame(.larger, current: visible) == visible)
    }

    @Test func smallerShrinksAwayFromTheEdgesItTouches() {
        #expect(frame(.smaller) == CGRect(x: 330, y: 330, width: 540, height: 340))
        #expect(frame(.smaller, current: frame(.leftHalf)) == CGRect(x: 0, y: 69, width: 840, height: 993))
        #expect(frame(.smaller, current: visible) == CGRect(x: 30, y: 69, width: 1740, height: 993))
        let small = CGRect(x: 300, y: 300, width: 170, height: 170)
        #expect(frame(.smaller, current: small) == small)
    }

    @Test func movingKeepsTheSizeAndStopsAtTheEdge() {
        #expect(frame(.moveLeft) == CGRect(x: 0, y: 300, width: 600, height: 400))
        #expect(frame(.moveRight) == CGRect(x: 1200, y: 300, width: 600, height: 400))
        #expect(frame(.moveUp) == CGRect(x: 300, y: 39, width: 600, height: 400))
        #expect(frame(.moveDown) == CGRect(x: 300, y: 692, width: 600, height: 400))
        #expect(frame(.moveLeft, gap: 10).minX == 10)
        #expect(frame(.moveLeft, current: CGRect(x: 100, y: 0, width: 500, height: 2000)) == CGRect(x: 0, y: 39, width: 500, height: 1053))
    }

    /// The app wouldn't go below its minimum size.
    @Test func aWindowLargerThanAskedStaysOnItsSideAndOnScreen() {
        let right = frame(.rightHalf)
        #expect(SnapGeometry.origin(for: CGSize(width: 1000, height: 1053), target: right, visible: visible) == CGPoint(x: 800, y: 39))
        let left = frame(.leftHalf)
        #expect(SnapGeometry.origin(for: CGSize(width: 1000, height: 1053), target: left, visible: visible) == CGPoint(x: 0, y: 39))
        let middle = frame(.centerThird)
        #expect(SnapGeometry.origin(for: CGSize(width: 700, height: 1053), target: middle, visible: visible) == CGPoint(x: 550, y: 39))
        // TextEdit kept 115 pt for a 100 pt window at the right edge.
        let tiny = CGRect(x: 1700, y: 39, width: 100, height: 100)
        #expect(SnapGeometry.origin(for: CGSize(width: 115, height: 100), target: tiny, visible: visible) == CGPoint(x: 1685, y: 39))
        #expect(SnapGeometry.origin(for: CGSize(width: 2000, height: 1053), target: right, visible: visible).x == 0)
        #expect(SnapGeometry.origin(for: right.size, target: right, visible: visible) == right.origin)
        let bottom = frame(.bottomHalf)
        #expect(SnapGeometry.origin(for: CGSize(width: 1800, height: 600), target: bottom, visible: visible) == CGPoint(x: 0, y: 492))
    }

    @Test func movingToAnotherScreenKeepsTheProportions() {
        let other = CGRect(x: 1800, y: -300, width: 2560, height: 1415)
        #expect(SnapGeometry.move(frame(.leftHalf), from: visible, to: other) == CGRect(x: 1800, y: -300, width: 1280, height: 1415))
        let back = SnapGeometry.move(CGRect(x: 3000, y: 100, width: 1000, height: 800), from: other, to: visible)
        #expect(visible.contains(back))
        #expect(back == CGRect(x: 844, y: 337, width: 703, height: 595))
        // Hanging off its screen, it lands on the next one whole.
        let hanging = SnapGeometry.move(CGRect(x: 1500, y: 39, width: 600, height: 400), from: visible, to: other)
        #expect(other.contains(hanging))
    }
}

@Suite struct SnapScreensTests {
    private let main = SnapScreen(id: "main", frame: CGRect(x: 0, y: 0, width: 1800, height: 1169), visibleFrame: visible)
    private let right = SnapScreen(id: "right", frame: CGRect(x: 1800, y: -411, width: 1920, height: 1080),
                                   visibleFrame: CGRect(x: 1800, y: -386, width: 1920, height: 1055))
    private let left = SnapScreen(id: "left", frame: CGRect(x: -1366, y: 200, width: 1366, height: 768),
                                  visibleFrame: CGRect(x: -1366, y: 200, width: 1366, height: 768))

    @Test func appKitRectsTurnIntoAccessibilityOnes() {
        let main = SnapScreens.accessibilityRect(fromAppKit: CGRect(x: 0, y: 77, width: 1800, height: 1053), mainScreenHeight: 1169)
        #expect(main == visible)
        let above = SnapScreens.accessibilityRect(fromAppKit: CGRect(x: 1800, y: 500, width: 1920, height: 1080), mainScreenHeight: 1169)
        #expect(above == CGRect(x: 1800, y: -411, width: 1920, height: 1080))
    }

    @Test func aWindowBelongsToTheScreenHoldingMostOfIt() {
        let screens = [main, right]
        #expect(SnapScreens.index(of: CGRect(x: 1600, y: 100, width: 800, height: 400), in: screens) == 1)
        #expect(SnapScreens.index(of: CGRect(x: 1400, y: 100, width: 600, height: 400), in: screens) == 0)
        #expect(SnapScreens.index(of: CGRect(x: 5000, y: -400, width: 100, height: 100), in: screens) == 1)
        #expect(SnapScreens.index(of: CGRect(x: -900, y: 300, width: 100, height: 100), in: screens) == 0)
        #expect(SnapScreens.index(of: .zero, in: []) == nil)
    }

    @Test func screensGoRoundLeftToRight() {
        let screens = [main, right, left]
        #expect(SnapScreens.neighbor(of: 0, in: screens, forward: true) == 1)
        #expect(SnapScreens.neighbor(of: 1, in: screens, forward: true) == 2)
        #expect(SnapScreens.neighbor(of: 2, in: screens, forward: true) == 0)
        #expect(SnapScreens.neighbor(of: 0, in: screens, forward: false) == 2)
        #expect(SnapScreens.neighbor(of: 0, in: [main], forward: true) == 0)
    }

    @Test func thePointerFindsItsScreen() {
        #expect(SnapScreens.index(containing: CGPoint(x: 2000, y: 0), in: [main, right]) == 1)
        #expect(SnapScreens.index(containing: CGPoint(x: 9000, y: 0), in: [main, right]) == nil)
    }
}

@Suite struct SnapZonesTests {
    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)

    private func zone(_ x: Double, _ y: Double, others: [CGRect] = []) -> SnapZone? {
        SnapZones.zone(at: CGPoint(x: x, y: y), screen: screen, otherScreens: others)
    }

    @Test func edgesAndCorners() {
        #expect(zone(0, 500) == .left)
        #expect(zone(4, 500) == .left)
        #expect(zone(5, 500) == nil)
        #expect(zone(1799, 500) == .right)
        #expect(zone(900, 0) == .top)
        #expect(zone(0, 0) == .topLeft)
        #expect(zone(24, 0) == .topLeft)
        #expect(zone(30, 0) == .top)
        #expect(zone(0, 20) == .topLeft)
        #expect(zone(0, 30) == .left)
        #expect(zone(1799, 0) == .topRight)
        #expect(zone(0, 1168) == .bottomLeft)
        #expect(zone(1799, 1168) == .bottomRight)
        #expect(zone(900, 500) == nil)
        #expect(zone(-50, 500) == nil)
    }

    @Test func theBottomEdgeIsSplitInThirds() {
        #expect(zone(300, 1168) == .bottomLeftThird)
        #expect(zone(900, 1168) == .bottomCenterThird)
        #expect(zone(1500, 1168) == .bottomRightThird)
    }

    /// Dragging a window across to the next screen must not snap it.
    @Test func anEdgeSharedWithAnotherScreenHasNoZone() {
        let besides = CGRect(x: 1800, y: 0, width: 1920, height: 1080)
        #expect(zone(1799, 500, others: [besides]) == nil)
        // Below the other screen, the edge is open again.
        #expect(zone(1799, 1100, others: [besides]) == .right)
        let above = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        #expect(zone(900, 0, others: [above]) == nil)
        #expect(zone(0, 0, others: [above]) == .topLeft)
    }

    @Test func zonesSurviveARoundTripWithOnesEmptied() {
        var map = SnapZones.defaults
        map[.top] = nil
        map[.left] = .action(.firstTwoThirds)
        #expect(SnapZones.decode(SnapZones.encode(map)) == map)
        #expect(SnapZones.decode("") == SnapZones.defaults)
        // A zone the text doesn't mention, or an unreadable line, keeps its default.
        #expect(SnapZones.decode("left=lastThird\nnonsense\nbogus=leftHalf")[.left] == .action(.lastThird))
        #expect(SnapZones.decode("left=lastThird")[.right] == .action(.rightHalf))
    }

    @Test func targetsReadBackWhatTheyStore() {
        let id = UUID()
        #expect(SnapTarget(stored: SnapTarget.custom(id).stored) == .custom(id))
        #expect(SnapTarget(stored: "maximize") == .action(.maximize))
        #expect(SnapTarget(stored: "custom:not-a-uuid") == nil)
        #expect(SnapTarget(stored: "none") == nil)
    }
}

@Suite struct SnapLibraryTests {
    @Test func aCustomSizeMustBeNamedAndOnTheScreen() {
        #expect(CustomSnapSize(name: "Writing", x: 10, y: 0, width: 80, height: 100).isValid)
        #expect(!CustomSnapSize(name: "  ", x: 0, y: 0, width: 50, height: 50).isValid)
        #expect(!CustomSnapSize(name: "Wide", x: 60, y: 0, width: 50, height: 50).isValid)
        #expect(!CustomSnapSize(name: "Flat", x: 0, y: 0, width: 50, height: 0).isValid)
        #expect(!CustomSnapSize(name: "Off", x: -5, y: 0, width: 50, height: 50).isValid)
    }

    @Test func aCustomSizeIsPlacedLikeTheBuiltInOnes() {
        let half = CustomSnapSize(name: "Half", x: 0, y: 0, width: 50, height: 100)
        #expect(SnapGeometry.region(half.unitRect, in: visible, gap: 6) == frame(.leftHalf, gap: 6))
        let writing = CustomSnapSize(name: "Writing", x: 20, y: 10, width: 60, height: 80)
        #expect(SnapGeometry.region(writing.unitRect, in: visible, gap: 0) == CGRect(x: 360, y: 144, width: 1080, height: 843))
    }

    @Test func aLayoutFrameComesBackOnTheSameScreen() {
        let window = CGRect(x: 100, y: 139, width: 800, height: 600)
        let unit = WindowLayout.unitRect(of: window, in: visible)
        #expect(WindowLayout.frame(of: unit, in: visible) == window)
        // On a bigger screen it keeps its share of it.
        let wide = CGRect(x: 0, y: 25, width: 3600, height: 2106)
        #expect(WindowLayout.frame(of: unit, in: wide) == CGRect(x: 200, y: 225, width: 1600, height: 1200))
    }

    private func saved(_ title: String, _ index: Int) -> WindowLayout.Window {
        WindowLayout.Window(bundleID: "com.example.app", title: title, index: index, screenID: "main", frame: UnitRect(x0: 0, y0: 0, x1: 1, y1: 1))
    }

    @Test func windowsAreMatchedByTitleThenByOrder() {
        let pairs = WindowLayout.match(saved: [saved("Report", 0), saved("Budget", 1), saved("", 2)],
                                       openTitles: ["Budget", "Notes", "Report"])
        #expect(pairs.map { [$0.saved, $0.open] } == [[0, 2], [1, 0], [2, 1]])
        // Two open windows with the same title are each used once.
        let twins = WindowLayout.match(saved: [saved("Untitled", 0), saved("Untitled", 1)], openTitles: ["Untitled", "Untitled"])
        #expect(twins.map { [$0.saved, $0.open] } == [[0, 0], [1, 1]])
        // More saved than open: the rest are left out.
        #expect(WindowLayout.match(saved: [saved("A", 1), saved("B", 0)], openTitles: ["C"]).map { [$0.saved, $0.open] } == [[1, 0]])
        #expect(WindowLayout.match(saved: [saved("A", 0)], openTitles: []).isEmpty)
    }

    @Test func aMissingScreenFallsBackToTheMainOne() {
        let screens = [SnapScreen(id: "main", frame: .zero, visibleFrame: .zero), SnapScreen(id: "tv", frame: .zero, visibleFrame: .zero)]
        #expect(WindowLayout.screenIndex(for: "tv", in: screens) == 1)
        #expect(WindowLayout.screenIndex(for: "gone", in: screens) == 0)
        #expect(WindowLayout.screenIndex(for: "gone", in: []) == nil)
    }

    @Test func sizesAndLayoutsAreSaved() throws {
        let store = SnapStore(dbQueue: try AppDatabase(inMemory: DatabaseQueue()).dbQueue)
        #expect(try store.loadSizes().isEmpty)
        #expect(try store.loadLayouts().isEmpty)
        let sizes = [CustomSnapSize(name: "Writing", x: 20, y: 0, width: 60, height: 100)]
        let layouts = [WindowLayout(name: "Work", windows: [saved("Report", 0)])]
        try store.saveSizes(sizes)
        try store.saveLayouts(layouts)
        #expect(try store.loadSizes() == sizes)
        #expect(try store.loadLayouts() == layouts)
    }
}
