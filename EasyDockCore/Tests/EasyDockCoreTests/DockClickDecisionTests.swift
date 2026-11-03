import Testing
@testable import EasyDockCore

@Suite struct DockClickDecisionTests {
    private func click(
        front: Bool = true, visible: Int = 2, ours: Bool = false,
        travel: Double = 0, held: Double = 0.1, excluded: Bool = false
    ) -> DockClick {
        DockClick(appWasInFront: front, visibleWindows: visible, hasWindowsMinimizedByEasyDock: ours,
                  travel: travel, heldSeconds: held, isExcluded: excluded)
    }

    private func decide(_ click: DockClick, _ preference: DockClickPreference = .minimize, stageManager: Bool = false) -> DockClickAction {
        DockClickDecision.decide(click, preference: preference, stageManager: stageManager)
    }

    @Test func theAppInFrontWithWindowsIsMinimized() {
        #expect(decide(click()) == .minimizeWindows)
    }

    /// Stage Manager ignores minimizing through Accessibility, so EasyDock
    /// stays out of its way entirely, restores included.
    @Test func underStageManagerEveryClickIsLeftToMacOS() {
        #expect(decide(click(), stageManager: true) == .none)
        #expect(decide(click(), .hide, stageManager: true) == .none)
        #expect(decide(click(front: false, visible: 0, ours: true), stageManager: true) == .none)
    }

    @Test func theHidePreferenceHides() {
        #expect(decide(click(), .hide) == .hide)
    }

    /// The Dock activates an app that wasn't in front; that is all a click
    /// should do there.
    @Test func anAppNotInFrontIsLeftToTheDock() {
        #expect(decide(click(front: false)) == .none)
    }

    /// No windows to hide: the Dock's reopen opens a new one, as it should.
    @Test func anAppWithoutVisibleWindowsIsLeftToTheDock() {
        #expect(decide(click(visible: 0)) == .none)
    }

    @Test func dragsLongPressesAndExcludedAppsAreLeftToTheDock() {
        #expect(decide(click(travel: 4.5)) == .none)
        #expect(decide(click(held: 0.5)) == .none)
        #expect(decide(click(excluded: true)) == .none)
    }

    /// A pixel or two of movement is a plain click on a trackpad.
    @Test func aSmallWobbleIsStillAClick() {
        #expect(decide(click(travel: 3)) == .minimizeWindows)
    }

    /// The second click: whether the app is still in front with nothing
    /// visible, or another app took over meanwhile, the windows come back.
    @Test func minimizedWindowsComeBackOnTheNextClick() {
        #expect(decide(click(front: true, visible: 0, ours: true)) == .restoreMinimized)
        #expect(decide(click(front: false, visible: 0, ours: true)) == .restoreMinimized)
    }

    /// The user brought a window back by hand and the app is in front with it
    /// showing: this click minimizes again rather than restoring the rest.
    @Test func aVisibleWindowInFrontMeansMinimizeEvenWithLeftovers() {
        #expect(decide(click(front: true, visible: 1, ours: true)) == .minimizeWindows)
    }

    @Test func aDragNeverRestores() {
        #expect(decide(click(front: false, visible: 0, ours: true, travel: 20)) == .none)
    }
}
