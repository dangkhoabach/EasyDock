import AppKit
import Darwin
import EasyDockCore
import Observation
import os
import UserNotifications

/// Memory: when macOS says it is running short, a notification names the
/// heaviest apps the user isn't using; and the user's rules quit an app once
/// it has gone unused for a while.
///
/// Nothing polls. macOS reports memory pressure itself, and the rules wait
/// on one timer set for the next app to fall due, recomputed when an app
/// comes forward, opens or quits, or the rules change. With no rules there
/// is no timer.
@MainActor
final class MemoryReliefController {
    static let shared = MemoryReliefController()

    private var pressureSource: DispatchSourceMemoryPressure?
    private var lastNotified: Date?
    /// When each app was last the one in front, or opened if it never was.
    private var lastUsed: [String: Date] = [:]
    /// Asked to quit and still open: not asked again until it is used.
    private var asked: Set<String> = []
    private var timer: Task<Void, Never>?
    private let log = Logger(subsystem: "com.dangkhoabach.easydock", category: "memory")

    private var settings: AppSettings { SettingsViewModel.shared.settings }

    private init() {}

    func start() {
        SettingsViewModel.shared.loadIfNeeded()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { Task { await MemoryReliefController.shared.memoryRanShort() } }
        }
        source.resume()
        pressureSource = source

        // Apps already open count as unused from now: EasyDock can't know before.
        let now = Date()
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let id = app.bundleIdentifier, id != front { lastUsed[id] = now }
        }
        let center = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, @MainActor (String) -> Void)] = [
            (NSWorkspace.didActivateApplicationNotification, { MemoryReliefController.shared.asked.remove($0) }),
            (NSWorkspace.didDeactivateApplicationNotification, { MemoryReliefController.shared.lastUsed[$0] = Date() }),
            (NSWorkspace.didLaunchApplicationNotification, { MemoryReliefController.shared.lastUsed[$0] = Date() }),
            (NSWorkspace.didTerminateApplicationNotification, {
                MemoryReliefController.shared.lastUsed[$0] = nil
                MemoryReliefController.shared.asked.remove($0)
            }),
        ]
        for (name, handle) in events {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
                MainActor.assumeIsolated {
                    handle(id)
                    MemoryReliefController.shared.schedule()
                }
            }
        }
        trackRules()
    }

    // MARK: - Running short

    private func memoryRanShort() async {
        guard settings.memoryPressureAlerts else { return }
        if let lastNotified, Date().timeIntervalSince(lastNotified) < MemoryRelief.quietPeriod { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .compactMap { app -> (pid_t, String, String, String?)? in
                guard let id = app.bundleIdentifier else { return nil }
                return (app.processIdentifier, id, app.localizedName ?? id, app.bundleURL?.path)
            }
        let usage = await Task.detached(priority: .utility) { Self.memory(of: apps) }.value
        let picked = MemoryRelief.suggestions(usage, frontmost: front)
        log.info("memory ran short; \(picked.count, privacy: .public) app(s) to suggest")
        guard !picked.isEmpty else { return }
        lastNotified = Date()

        if await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined {
            guard await NotificationManager.shared.requestAuthorization() else { return }
        }
        let list = picked.map { "\($0.name) \(CleanupViewModel.formatBytes(Int64($0.bytes)))" }.joined(separator: ", ")
        // English is the source language and has no table of its own.
        let english = AppLocale.selected == .en
        let title = english ? "Your Mac is running short of memory" : String(localized: "Your Mac is running short of memory", bundle: AppLocale.bundle)
        let body = english
            ? "Taking the most while you're not using them: \(list). Click to see them and quit what you don't need."
            : String(localized: "Taking the most while you're not using them: \(list). Click to see them and quit what you don't need.", bundle: AppLocale.bundle)
        await NotificationManager.shared.notify(title: title, body: body, route: "/system")
    }

    /// Each app with its helpers: a process counts for the app that is
    /// responsible for it (what Activity Monitor groups by), or else the app
    /// its program sits in. About 20 ms for a thousand processes.
    nonisolated private static func memory(of apps: [(pid: pid_t, id: String, name: String, path: String?)]) -> [AppMemory] {
        var totals: [pid_t: UInt64] = [:]
        let count = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let listed = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let byPID = Set(apps.map(\.pid))
        let bundles = apps.compactMap { app in app.path.map { (app.pid, $0 + "/") } }
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(max(0, listed)) where pid > 0 {
            var info = rusage_info_v4()
            let read = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard read == 0 else { continue }
            let responsible = PrivateAPIs.responsibleProcess(of: pid) ?? pid
            if byPID.contains(responsible) {
                totals[responsible, default: 0] += info.ri_phys_footprint
            } else if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
                let path = String(cString: pathBuffer)
                if let owner = bundles.first(where: { path.hasPrefix($0.1) }) { totals[owner.0, default: 0] += info.ri_phys_footprint }
            }
        }
        return apps.map { AppMemory(bundleID: $0.id, name: $0.name, bytes: totals[$0.pid] ?? 0) }
    }

    // MARK: - Quitting unused apps

    private func trackRules() {
        withObservationTracking {
            _ = settings.quitIdleApps
        } onChange: {
            Task { @MainActor in MemoryReliefController.shared.trackRules() }
        }
        schedule()
    }

    private func schedule() {
        timer?.cancel()
        timer = nil
        let rules = settings.quitIdleApps
        guard !rules.isEmpty, let next = IdleQuit.nextDeadline(rules: rules, lastUsed: lastUsed, running: runningIDs(),
                                                                frontmost: frontmost(), asked: asked) else { return }
        timer = Task {
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            MemoryReliefController.shared.quitDueApps()
        }
    }

    /// A normal quit, as from the Dock: an app with unsaved work asks about
    /// it, and EasyDock never forces it.
    private func quitDueApps() {
        let due = IdleQuit.due(rules: settings.quitIdleApps, lastUsed: lastUsed, running: runningIDs(),
                               frontmost: frontmost(), asked: asked, now: Date())
        for id in due {
            NSRunningApplication.runningApplications(withBundleIdentifier: id).forEach { $0.terminate() }
            asked.insert(id)
            log.info("quit an app unused for its set time")
        }
        schedule()
    }

    private func runningIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    private func frontmost() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
