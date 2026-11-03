import Foundation
import Testing
@testable import EasyDockCore

/// The uninstaller's matching, the developer tools' output and the age of a
/// download.
@Suite struct CleanupExtrasTests {
    private func matches(_ entry: String, _ folder: String, id: String = "com.example.Notes", name: String = "Notes") -> Bool {
        AppLeftovers.match(entry, in: folder, bundleID: id, appName: name) != nil
    }

    @Test func theAppsOwnFilesAreFound() {
        #expect(matches("com.example.Notes", "Containers"))
        #expect(matches("com.example.notes.plist", "Preferences"))
        #expect(matches("com.example.Notes.savedState", "Saved Application State"))
        #expect(matches("com.example.Notes.binarycookies", "Cookies"))
        #expect(matches("com.example.Notes.0A1B2C3D-1111-2222-3333-444455556666.plist", "Preferences/ByHost"))
        #expect(matches("com.example.Notes.001122aabbcc.plist", "Preferences/ByHost"))
        #expect(matches("com.example.Notes.plist", "LaunchAgents"))
        #expect(matches("ABCDE12345.com.example.Notes", "Group Containers"))
        #expect(matches("Notes", "Application Support"))
    }

    @Test func anotherAppSharingThePrefixOrTheNameIsLeftAlone() {
        #expect(!matches("com.example.Notes.canary", "Application Support"))
        #expect(!matches("com.example.Notes.canary.plist", "Preferences"))
        #expect(!matches("com.example.NotesPro", "Containers"))
        #expect(!matches("Notes", "Preferences"))
        #expect(!matches("com.example.Notes.canary.0A1B2C3D-1111-2222-3333-444455556666.plist", "Preferences/ByHost"))
        #expect(!matches("com.example.Notes.helper.plist", "LaunchAgents"))
        #expect(!matches("Go", "Caches", name: "Go"))
        #expect(!matches("anything", "Caches", id: ""))
    }

    /// A folder named after the app may be shared with another edition of
    /// it, so it is told apart from the app's own files.
    @Test func aMatchByNameIsMarkedAsSuch() {
        #expect(AppLeftovers.match("Notes", in: "Application Support", bundleID: "com.example.Notes", appName: "Notes") == .name)
        #expect(AppLeftovers.match("com.example.Notes", in: "Caches", bundleID: "com.example.Notes", appName: "Notes") == .identifier)
    }

    @Test func systemAppsAndEasyDockAreNeverOffered() {
        #expect(AppLeftovers.isProtected(bundleID: "com.apple.Safari", path: "/Applications/Safari.app"))
        #expect(AppLeftovers.isProtected(bundleID: "com.example.Tool", path: "/System/Applications/Tool.app"))
        #expect(AppLeftovers.isProtected(bundleID: "com.dangkhoabach.easydock", path: "/Applications/EasyDock.app"))
        #expect(AppLeftovers.isProtected(bundleID: nil, path: "/Applications/Broken.app"))
        #expect(!AppLeftovers.isProtected(bundleID: "com.example.Notes", path: "/Applications/Notes.app"))
    }

    @Test func unavailableSimulatorsAreCounted() {
        let json = #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-17-0":[{"name":"iPhone 15"},{"name":"iPad"}],"com.apple.CoreSimulator.SimRuntime.iOS-16-4":[{"name":"iPhone 14"}]}}"#
        #expect(DeveloperCleanup.unavailableSimulatorCount(fromJSON: Data(json.utf8)) == 3)
        #expect(DeveloperCleanup.unavailableSimulatorCount(fromJSON: Data(#"{"devices":{}}"#.utf8)) == 0)
        #expect(DeveloperCleanup.unavailableSimulatorCount(fromJSON: Data("not json".utf8)) == nil)
    }

    @Test func homebrewsDryRunSizeIsRead() {
        let output = """
            Would remove: /Users/me/Library/Caches/Homebrew/wget--1.21.bottle.tar.gz (1.5MB)
            ==> This operation would free approximately 312.4MB of disk space.
            """
        #expect(DeveloperCleanup.brewReclaimable(fromDryRun: output) == "312.4MB")
        #expect(DeveloperCleanup.brewReclaimable(fromDryRun: "") == nil)
    }

    @Test func aDownloadIsOldOnlyPastTheChosenAge() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(OldDownloads.isOld(addedAt: now - 31 * 86_400, olderThanDays: 30, now: now))
        #expect(!OldDownloads.isOld(addedAt: now - 29 * 86_400, olderThanDays: 30, now: now))
    }
}
