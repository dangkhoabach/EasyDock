import CoreGraphics
import Testing
@testable import EasyDockCore

@Suite struct AlwaysOnTopTests {
    @Test func pinningTwiceUnpins() {
        let (pinned, first) = AlwaysOnTop.toggle(7, in: [3])
        #expect(first == .pinned)
        #expect(pinned == [3, 7])
        let (after, second) = AlwaysOnTop.toggle(7, in: pinned)
        #expect(second == .unpinned)
        #expect(after == [3])
    }

    @Test func aFullListIsLeftAlone() {
        let full = Array(UInt32(1)...UInt32(AlwaysOnTop.limit))
        let (pinned, result) = AlwaysOnTop.toggle(99, in: full)
        #expect(result == .full)
        #expect(pinned == full)
        // Unpinning still works at the limit.
        #expect(AlwaysOnTop.toggle(1, in: full).1 == .unpinned)
    }

    private func shows(front: Int32? = 2, focused: UInt32? = 50, hidden: Bool = false,
                       minimized: Bool = false, shown: Bool = true) -> Bool {
        AlwaysOnTop.showsCopy(windowID: 10, pid: 1, frontPID: front, focusedWindowID: focused,
                              isHidden: hidden, isMinimized: minimized, isOnShownDesktop: shown)
    }

    @Test func theCopyShowsWhileAnotherAppIsInFront() {
        #expect(shows())
        #expect(shows(front: nil, focused: nil))
    }

    @Test func theCopyHidesWhileTheWindowItselfIsInUse() {
        #expect(!shows(front: 1, focused: 10))
    }

    /// Another window of the same app in front of the pinned one.
    @Test func theCopyShowsOverTheAppsOtherWindows() {
        #expect(shows(front: 1, focused: 11))
    }

    @Test func nothingToShowForAHiddenAppAMinimizedWindowOrAnotherDesktop() {
        #expect(!shows(hidden: true))
        #expect(!shows(minimized: true))
        #expect(!shows(shown: false))
    }

    @Test func framesFlipToAppKit() {
        let frame = AlwaysOnTop.appKitFrame(CGRect(x: 100, y: 50, width: 800, height: 600), mainDisplayHeight: 1117)
        #expect(frame == CGRect(x: 100, y: 467, width: 800, height: 600))
    }
}
