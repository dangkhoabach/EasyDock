import Testing
@testable import EasyDock

@MainActor
@Suite struct MenuBarPreferencesTests {
    @Test func clipboardComesFirstByDefault() {
        #expect(MenuBarPreferences.normalized([]) == [.clipboard, .overview, .cleanup, .system])
    }

    @Test func aStoredOrderIsKept() {
        let order: [MenuBarTab] = [.system, .cleanup, .overview, .clipboard]
        #expect(MenuBarPreferences.normalized(order) == order)
    }

    /// A stored order from before a tab existed, or a corrupted one, still
    /// gives every tab exactly once.
    @Test func missingTabsAreAppendedAndDuplicatesDropped() {
        #expect(MenuBarPreferences.normalized([.system, .system]) == [.system, .clipboard, .overview, .cleanup])
    }
}
