import Testing
@testable import EasyDock

@MainActor @Suite struct AppDisplayNameTests {
    /// What macOS 27 returned for MediaRemoteUIService: one U+200E.
    @Test func anInvisibleNameFallsBackToTheBundleThenTheProcess() {
        #expect(SystemViewModel.displayName(localizedName: "\u{200E}", bundleName: "MediaRemoteUIService", processName: "MediaRemoteUIS") == "MediaRemoteUIService")
        #expect(SystemViewModel.displayName(localizedName: " ", bundleName: nil, processName: "helper") == "helper")
        #expect(SystemViewModel.displayName(localizedName: nil, bundleName: nil, processName: "helper") == "helper")
        #expect(SystemViewModel.displayName(localizedName: "Finder", bundleName: "Finder", processName: "Finder") == "Finder")
    }

    @Test func aSharedNameTakesTheBundlesWhereThatTellsThemApart() {
        let names = SystemViewModel.disambiguated([
            ("Siri", "Siri AI"), ("Siri", "Siri"), ("Web Content", nil), ("Web Content", nil), ("Mail", "Mail"),
        ])
        #expect(names == ["Siri AI", "Siri", "Web Content", "Web Content", "Mail"])
    }
}
