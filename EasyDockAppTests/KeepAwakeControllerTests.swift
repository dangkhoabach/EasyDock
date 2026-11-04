import Foundation
import IOKit.pwr_mgt
import Testing
@testable import EasyDockCore
@testable import EasyDock

/// Against the real power management: the assertion has to be there while a
/// session runs and gone as soon as it stops.
@MainActor
@Suite(.serialized) struct KeepAwakeControllerTests {
    private static func assertionNames() -> [String] {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
              let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }
        return (all[NSNumber(value: getpid())] ?? []).compactMap { $0[kIOPMAssertionNameKey] as? String }
    }

    @Test func aSessionHoldsTheMacAwakeUntilItIsStopped() {
        let keepAwake = KeepAwakeController.shared
        keepAwake.startSession(minutes: 0)
        #expect(keepAwake.reason == .session)
        #expect(Self.assertionNames().contains("EasyDock Keep Awake"))

        keepAwake.stopSession()
        #expect(keepAwake.session == nil)
        #expect(!Self.assertionNames().contains("EasyDock Keep Awake"))
    }

    /// Finder is always running. The list is put back afterwards: the test
    /// host saves settings to the app's database.
    @Test func anAppFromTheListKeepsTheMacAwakeWithoutASession() async throws {
        let model = SettingsViewModel.shared
        let before = model.settings.keepAwakeApps
        defer { model.settings.keepAwakeApps = before }
        model.settings.keepAwakeApps = ["com.apple.finder"]

        let keepAwake = KeepAwakeController.shared
        for _ in 0..<50 where keepAwake.reason != .app("com.apple.finder") {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(keepAwake.session == nil)
        #expect(keepAwake.reason == .app("com.apple.finder"))
        #expect(Self.assertionNames().contains("EasyDock Keep Awake"))
    }

    @Test func aTimedSessionCountsDownFromItsLength() throws {
        let keepAwake = KeepAwakeController.shared
        keepAwake.startSession(minutes: 15)
        defer { keepAwake.stopSession() }
        let remaining = try #require(keepAwake.session?.remaining(at: Date()))
        #expect(remaining > 890 && remaining <= 900)
    }
}
