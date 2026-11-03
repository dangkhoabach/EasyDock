import CoreGraphics
import Testing
@testable import EasyDockCore

@Suite struct SwitcherListTests {
    private let normal = CGSize(width: 800, height: 600)

    private func window(_ id: UInt32, pid: Int32, _ title: String = "", spaces: [UInt64] = [1], size: CGSize? = nil) -> WindowRecord {
        WindowRecord(windowID: id, pid: pid, title: title, size: size ?? normal, spaces: spaces)
    }

    private func ids(_ items: [SwitcherItem]) -> [String] { items.map(\.id) }

    /// On the active Space the window server's front-to-back order is the
    /// order of use, so it is kept even across apps.
    @Test func activeSpaceWindowsKeepTheWindowServerOrder() {
        let items = SwitcherList.make(
            windows: [window(10, pid: 2), window(11, pid: 1), window(12, pid: 2)],
            activeSpace: 1,
            apps: [(1, "One"), (2, "Two")]
        )
        #expect(ids(items) == ["w10", "w11", "w12"])
    }

    /// Windows EasyDock saw being focused go first, in that order, whatever
    /// the window server's order says (Stage Manager's strip counts as on
    /// screen, so its order is not the order of use).
    @Test func recentlyFocusedWindowsComeFirst() {
        let items = SwitcherList.make(
            windows: [window(10, pid: 1), window(11, pid: 2), window(12, pid: 2, spaces: [9]), window(13, pid: 1)],
            activeSpace: 1,
            apps: [(1, "One"), (2, "Two")],
            recentWindows: [12, 13]
        )
        #expect(ids(items) == ["w12", "w13", "w10", "w11"])
    }

    @Test func windowsElsewhereFollowByHowRecentlyTheirAppWasUsed() {
        let items = SwitcherList.make(
            windows: [window(20, pid: 2, spaces: [9]), window(21, pid: 1, spaces: [9]), window(22, pid: 3)],
            activeSpace: 1,
            apps: [(1, "One"), (2, "Two"), (3, "Three")]
        )
        #expect(ids(items) == ["w22", "w21", "w20"])
        #expect(items.map(\.isOnActiveSpace) == [true, false, false])
    }

    @Test func helperWindowsTinyWindowsAndUnlistedAppsAreLeftOut() {
        let items = SwitcherList.make(
            windows: [
                window(30, pid: 1, spaces: []),                                 // helper window, on no Space
                window(31, pid: 1, size: CGSize(width: 1800, height: 39)),       // a strip
                window(32, pid: 9),                                              // app not offered (EasyDock, agents)
                window(33, pid: 1),
            ],
            activeSpace: 1,
            apps: [(1, "One")]
        )
        #expect(ids(items) == ["w33"])
    }

    @Test func appsWithoutWindowsComeLastAsOneTile() {
        let items = SwitcherList.make(windows: [window(40, pid: 1)], activeSpace: 1, apps: [(2, "Two"), (1, "One")])
        #expect(ids(items) == ["w40", "a2"])
        #expect(items.last?.title == "Two")
    }

    @Test func anUntitledWindowShowsItsAppName() {
        let items = SwitcherList.make(windows: [window(50, pid: 1)], activeSpace: 1, apps: [(1, "One")])
        #expect(items.first?.title == "One")
    }

    @Test func selectionStartsOnThePreviousWindowAndWraps() {
        var selection = SwitcherSelection(count: 3)
        #expect(selection.index == 1)
        selection.next(); #expect(selection.index == 2)
        selection.next(); #expect(selection.index == 0)
        selection.previous(); #expect(selection.index == 2)
        selection.select(7); #expect(selection.index == 2)
    }

    @Test func aSingleTileStaysSelected() {
        var selection = SwitcherSelection(count: 1)
        #expect(selection.index == 0)
        selection.next(); #expect(selection.index == 0)
        var empty = SwitcherSelection(count: 0)
        empty.next(); #expect(empty.index == 0)
    }
}
