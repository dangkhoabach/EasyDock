import CoreGraphics
import Testing
@testable import EasyDockCore

/// "Current desktop only": which Spaces count, and what the switcher lists then.
@Suite struct SwitcherScopeTests {
    private func display(_ name: String, current: UInt64, desktops: [UInt64], fullScreen: [UInt64] = []) -> DisplaySpaces {
        DisplaySpaces(
            display: name,
            current: current,
            spaces: desktops.map { .init(id: $0, isFullScreen: false) } + fullScreen.map { .init(id: $0, isFullScreen: true) }
        )
    }

    private func window(_ id: UInt32, pid: Int32, spaces: [UInt64]) -> WindowRecord {
        WindowRecord(windowID: id, pid: pid, title: "", size: CGSize(width: 800, height: 600), spaces: spaces)
    }

    @Test func theDesktopOnScreenAndEveryFullScreenAppCount() {
        let shown = SwitcherSpaces.shown([display("A", current: 2, desktops: [1, 2, 3], fullScreen: [7])], lastDesktops: [:])
        #expect(shown == [2, 7])
    }

    @Test func everyDisplaysDesktopCounts() {
        let shown = SwitcherSpaces.shown(
            [display("A", current: 1, desktops: [1, 2]), display("B", current: 5, desktops: [4, 5])],
            lastDesktops: [:]
        )
        #expect(shown == [1, 5])
    }

    /// In a full-screen app the desktop is the one shown on that display
    /// just before, or its first one when none was seen.
    @Test func fromAFullScreenAppTheLastDesktopCounts() {
        let displays = [display("A", current: 7, desktops: [1, 2, 3], fullScreen: [7, 8])]
        #expect(SwitcherSpaces.shown(displays, lastDesktops: ["A": 3]) == [3, 7, 8])
        #expect(SwitcherSpaces.shown(displays, lastDesktops: [:]) == [1, 7, 8])
        // A desktop since removed doesn't count.
        #expect(SwitcherSpaces.shown(displays, lastDesktops: ["A": 99]) == [1, 7, 8])
    }

    @Test func onlyWindowsOnShownSpacesAreListed() {
        let windows = [
            window(10, pid: 1, spaces: [1]),
            window(11, pid: 2, spaces: [2]),       // another desktop
            window(12, pid: 3, spaces: [7]),       // full-screen
            window(13, pid: 4, spaces: [1, 2]),    // on every desktop
        ]
        let apps: [(pid: Int32, name: String)] = [(1, "One"), (2, "Two"), (3, "Three"), (4, "Four")]
        let all = SwitcherList.make(windows: windows, activeSpace: 1, apps: apps)
        let current = SwitcherList.make(windows: windows, activeSpace: 1, apps: apps, shownSpaces: [1, 7])
        #expect(Set(all.map(\.id)) == ["w10", "w11", "w12", "w13"])
        #expect(Set(current.map(\.id)) == ["w10", "w12", "w13"])
    }

    /// An app with no window anywhere keeps its tile; one whose windows are
    /// all on another desktop doesn't get one in their place.
    @Test func onlyAppsWithNoWindowAnywhereGetAnAppTile() {
        let items = SwitcherList.make(
            windows: [window(10, pid: 1, spaces: [1]), window(11, pid: 2, spaces: [2])],
            activeSpace: 1,
            apps: [(1, "One"), (2, "Two"), (3, "Three")],
            shownSpaces: [1]
        )
        #expect(items.map(\.id) == ["w10", "a3"])
    }
}
