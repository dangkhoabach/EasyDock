import Foundation
import Testing
@testable import EasyDockCore

@Suite struct KeepAwakePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aTimedSessionEndsAfterItsMinutes() {
        let session = KeepAwakeSession.starting(minutes: 30, at: now)
        #expect(session.remaining(at: now.addingTimeInterval(600)) == 1200)
        #expect(!KeepAwakePolicy.sessionShouldEnd(session, at: now.addingTimeInterval(1799), battery: nil, minimumPercent: 20))
        #expect(KeepAwakePolicy.sessionShouldEnd(session, at: now.addingTimeInterval(1800), battery: nil, minimumPercent: 20))
    }

    @Test func zeroMinutesLastsUntilTurnedOff() {
        let session = KeepAwakeSession.starting(minutes: 0, at: now)
        #expect(session.endsAt == nil)
        #expect(session.remaining(at: now) == nil)
        #expect(!KeepAwakePolicy.sessionShouldEnd(session, at: now.addingTimeInterval(86_400 * 30), battery: nil, minimumPercent: 20))
    }

    /// Only unplugged counts, and a limit of 0 never stops anything.
    @Test func theBatteryLimitAppliesOnlyOnBattery() {
        #expect(KeepAwakePolicy.batteryIsLow(BatteryLevel(percent: 20, onBattery: true), minimumPercent: 20))
        #expect(!KeepAwakePolicy.batteryIsLow(BatteryLevel(percent: 21, onBattery: true), minimumPercent: 20))
        #expect(!KeepAwakePolicy.batteryIsLow(BatteryLevel(percent: 5, onBattery: false), minimumPercent: 20))
        #expect(!KeepAwakePolicy.batteryIsLow(BatteryLevel(percent: 5, onBattery: true), minimumPercent: 0))
        #expect(!KeepAwakePolicy.batteryIsLow(nil, minimumPercent: 20))
    }

    @Test func aLowBatteryEndsTheSession() {
        let session = KeepAwakeSession.starting(minutes: 0, at: now)
        #expect(KeepAwakePolicy.sessionShouldEnd(session, at: now, battery: BatteryLevel(percent: 12, onBattery: true), minimumPercent: 20))
    }

    @Test func aRunningAppFromTheListKeepsTheMacAwake() {
        let reason = KeepAwakePolicy.reason(session: nil, runningApps: ["com.apple.Safari", "com.example.render"],
                                            triggerApps: ["com.example.other", "com.example.render"], battery: nil, minimumPercent: 20)
        #expect(reason == .app("com.example.render"))
        #expect(KeepAwakePolicy.reason(session: nil, runningApps: ["com.apple.Safari"], triggerApps: ["com.example.render"],
                                       battery: nil, minimumPercent: 20) == nil)
    }

    @Test func aSessionComesBeforeAnApp() {
        #expect(KeepAwakePolicy.reason(session: KeepAwakeSession(endsAt: nil), runningApps: ["com.example.render"],
                                       triggerApps: ["com.example.render"], battery: nil, minimumPercent: 20) == .session)
    }

    /// The app is still running when the Mac is plugged back in, so it keeps
    /// it awake again; nothing has to be turned back on.
    @Test func aLowBatteryPausesAppsUntilPluggedIn() {
        func reason(_ battery: BatteryLevel) -> KeepAwakeReason? {
            KeepAwakePolicy.reason(session: nil, runningApps: ["com.example.render"], triggerApps: ["com.example.render"],
                                   battery: battery, minimumPercent: 20)
        }
        #expect(reason(BatteryLevel(percent: 15, onBattery: true)) == nil)
        #expect(reason(BatteryLevel(percent: 15, onBattery: false)) == .app("com.example.render"))
    }
}

@Suite struct KeepAwakeSessionRecordTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let boot = 1_799_990_000

    @Test func aSessionComesBackInTheSameBoot() {
        let timed = KeepAwakeSession.starting(minutes: 30, at: now)
        let record = KeepAwakeSessionRecord.encode(timed, bootTime: boot)
        #expect(record == "1799990000|1800001800")
        #expect(KeepAwakeSessionRecord.decode(record, bootTime: boot, now: now.addingTimeInterval(60)) == timed)
        let untilOff = KeepAwakeSessionRecord.encode(KeepAwakeSession(endsAt: nil), bootTime: boot)
        #expect(KeepAwakeSessionRecord.decode(untilOff, bootTime: boot, now: now) == KeepAwakeSession(endsAt: nil))
    }

    /// After a restart of the Mac the boot time differs: no session, as before.
    @Test func notAfterARestart() {
        let record = KeepAwakeSessionRecord.encode(KeepAwakeSession(endsAt: nil), bootTime: boot)
        #expect(KeepAwakeSessionRecord.decode(record, bootTime: boot + 3600, now: now) == nil)
    }

    @Test func notOnceItRanOut() {
        let record = KeepAwakeSessionRecord.encode(KeepAwakeSession.starting(minutes: 15, at: now), bootTime: boot)
        #expect(KeepAwakeSessionRecord.decode(record, bootTime: boot, now: now.addingTimeInterval(15 * 60)) == nil)
    }

    @Test func nothingFromAnEmptyOrDamagedRecord() {
        for record in ["", "-", "abc|-", "1799990000", "1799990000|soon"] {
            #expect(KeepAwakeSessionRecord.decode(record, bootTime: boot, now: now) == nil)
        }
    }
}
