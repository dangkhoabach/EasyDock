import AppKit
import EasyDockCore
import IOKit.ps
import IOKit.pwr_mgt
import Observation
import os

/// Keep Awake: holds a power assertion while a session the user started
/// runs, or while an app from their list is open. macOS drops the assertion
/// as soon as EasyDock exits, however it exits, so a crash never leaves the
/// Mac awake.
///
/// Nothing polls: it looks again when a session starts, stops or runs out,
/// when an app opens or quits, when the power source changes, and when the
/// settings change.
///
/// A running session is written down. When EasyDock starts again in the same
/// boot without the user having quit it (an update relaunching it, a crash,
/// another app quitting it), the session carries on. Quitting EasyDock from
/// its own menus, logging out or restarting the Mac ends it.
@MainActor
@Observable
final class KeepAwakeController {
    static let shared = KeepAwakeController()

    /// The session the user started; an app from the list keeps the Mac
    /// awake independently of it.
    private(set) var session: KeepAwakeSession? {
        didSet { if session != oldValue { remember() } }
    }
    private(set) var reason: KeepAwakeReason?
    var isActive: Bool { reason != nil }

    @ObservationIgnored private var assertion: (id: IOPMAssertionID, allowsDisplaySleep: Bool)?
    @ObservationIgnored private var endTask: Task<Void, Never>?
    @ObservationIgnored private var scheduledEnd: Date?
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.easydock", category: "keep-awake")
    @ObservationIgnored private var store: KeepAwakeSessionStore?

    /// A test host runs as EasyDock on the user's database: it neither picks
    /// up nor writes down the user's session.
    private static let keepsRecord = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil

    private static let bootTime: Int = {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &boot, &size, nil, 0)
        return boot.tv_sec
    }()

    private var settings: AppSettings { SettingsViewModel.shared.settings }

    private init() {}

    func start() {
        SettingsViewModel.shared.loadIfNeeded()
        if Self.keepsRecord, let database = AppDatabase.shared {
            resume(from: KeepAwakeSessionStore(dbQueue: database.dbQueue))
        }
        let center = NSWorkspace.shared.notificationCenter
        // Logging out, restarting or shutting down: the session ends with it.
        center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { KeepAwakeController.shared.stopSession() }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { KeepAwakeController.shared.update() }
            }
        }
        // Added to the main run loop, so the callback runs on the main thread.
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { KeepAwakeController.shared.update() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        trackSettings()
    }

    /// `minutes` 0 is until turned off.
    func startSession(minutes: Int) {
        session = .starting(minutes: minutes, at: Date())
        log.info("session started for \(minutes) min")
        update()
    }

    func stopSession() {
        guard session != nil else { return }
        session = nil
        log.info("session stopped")
        update()
    }

    /// The menu bar switch and the shortcut: a session of the default length, or off.
    func toggleSession() {
        session == nil ? startSession(minutes: settings.keepAwakeMinutes) : stopSession()
    }

    /// Picks up the session written down in this boot, if it still runs,
    /// and keeps writing down the session from then on.
    func resume(from store: KeepAwakeSessionStore) {
        self.store = store
        if let record = try? store.load(), let restored = KeepAwakeSessionRecord.decode(record, bootTime: Self.bootTime, now: Date()) {
            session = restored
            log.info("session carried on after EasyDock started again")
            update()
        } else {
            try? store.save("")
        }
    }

    private func remember() {
        try? store?.save(session.map { KeepAwakeSessionRecord.encode($0, bootTime: Self.bootTime) } ?? "")
    }

    // MARK: - Deciding

    private func trackSettings() {
        withObservationTracking {
            _ = settings
        } onChange: {
            Task { @MainActor in KeepAwakeController.shared.trackSettings() }
        }
        update()
    }

    private func update() {
        let now = Date()
        let minimum = settings.keepAwakeBatteryMinimumPercent
        let battery = Self.battery()
        if let session, KeepAwakePolicy.sessionShouldEnd(session, at: now, battery: battery, minimumPercent: minimum) {
            self.session = nil
            log.info("session ended: \(session.endsAt.map { $0 <= now } == true ? "time is up" : "battery low", privacy: .public)")
        }
        let running = settings.keepAwakeApps.isEmpty
            ? [] : Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let reason = KeepAwakePolicy.reason(session: session, runningApps: running, triggerApps: settings.keepAwakeApps,
                                            battery: battery, minimumPercent: minimum)
        if reason != self.reason { self.reason = reason }
        reason == nil ? release() : hold(allowingDisplaySleep: settings.keepAwakeAllowDisplaySleep)
        scheduleEnd(session?.endsAt)
    }

    /// One wait until the session's end. `Task.sleep` counts on the
    /// continuous clock, which keeps running while the Mac sleeps, so a
    /// session that ran out during a sleep ends right after the wake.
    private func scheduleEnd(_ end: Date?) {
        guard end != scheduledEnd else { return }
        scheduledEnd = end
        endTask?.cancel()
        endTask = end.map { end in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
                guard !Task.isCancelled else { return }
                self?.scheduledEnd = nil
                self?.update()
            }
        }
    }

    // MARK: - Power assertion

    private func hold(allowingDisplaySleep: Bool) {
        if let assertion, assertion.allowsDisplaySleep == allowingDisplaySleep { return }
        release()
        let type = allowingDisplaySleep ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
        var id: IOPMAssertionID = 0
        guard IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                          "EasyDock Keep Awake" as CFString, &id) == kIOReturnSuccess
        else {
            log.error("power assertion refused")
            return
        }
        assertion = (id, allowingDisplaySleep)
        log.info("holding \(allowingDisplaySleep ? "system" : "display", privacy: .public) awake")
    }

    private func release() {
        guard let assertion else { return }
        IOPMAssertionRelease(assertion.id)
        self.assertion = nil
        log.info("released")
    }

    // MARK: - Battery

    /// The internal battery; nil on a Mac without one.
    private static func battery() -> BatteryLevel? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maxCapacity = description[kIOPSMaxCapacityKey] as? Int, maxCapacity > 0
            else { continue }
            return BatteryLevel(percent: Double(capacity) / Double(maxCapacity) * 100,
                                onBattery: description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue)
        }
        return nil
    }
}
