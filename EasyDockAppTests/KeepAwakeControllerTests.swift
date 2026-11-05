import Foundation
import GRDB
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

    /// What EasyDock does when it starts again in the same boot: the
    /// written-down session comes back and holds the Mac awake; stopping it
    /// clears the record. An in-memory database, never the user's.
    @Test func aWrittenDownSessionCarriesOn() throws {
        let store = KeepAwakeSessionStore(dbQueue: try AppDatabase(inMemory: DatabaseQueue()).dbQueue)
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        let endsAt = Date().addingTimeInterval(600)
        try store.save(KeepAwakeSessionRecord.encode(KeepAwakeSession(endsAt: endsAt), bootTime: boot.tv_sec))

        let keepAwake = KeepAwakeController.shared
        keepAwake.resume(from: store)
        defer { keepAwake.stopSession() }
        let remaining = try #require(keepAwake.session?.remaining(at: Date()))
        #expect(remaining > 590 && remaining <= 601)
        #expect(Self.assertionNames().contains("EasyDock Keep Awake"))

        keepAwake.stopSession()
        #expect(try store.load() == "")
        #expect(!Self.assertionNames().contains("EasyDock Keep Awake"))
    }

    @Test func aTimedSessionCountsDownFromItsLength() throws {
        let keepAwake = KeepAwakeController.shared
        keepAwake.startSession(minutes: 15)
        defer { keepAwake.stopSession() }
        let remaining = try #require(keepAwake.session?.remaining(at: Date()))
        #expect(remaining > 890 && remaining <= 900)
    }
}
