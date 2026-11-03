import AppKit
import ApplicationServices

/// The windows the user has focused, most recent first — the switcher's
/// order. Neither the window server's front-to-back order nor the apps'
/// order of activation is it: with Stage Manager on the strip's windows
/// count as on screen, and a switch between two windows of one app doesn't
/// activate anything.
///
/// Fed by app activations, by each app's focused-window notifications, and
/// by the switcher itself when it brings a window forward.
@MainActor
final class WindowFocusHistory {
    static let shared = WindowFocusHistory()

    /// Most recent first.
    private(set) var order: [CGWindowID] = []
    private var observers: [pid_t: AXObserver] = [:]
    private static let limit = 300

    func start() {
        guard observers.isEmpty else { return }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observe(app.processIdentifier)
        }
        if let front = NSWorkspace.shared.frontmostApplication { recordFocusedWindow(of: front.processIdentifier) }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { WindowFocusHistory.shared.observe(pid) }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated { WindowFocusHistory.shared.stopObserving(pid) }
        }
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            // Read a moment later: at activation the app still reports the
            // window that was focused before, not the one just clicked, which
            // would put a window the user never touched at the front.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                WindowFocusHistory.shared.recordFocusedWindow(of: pid)
            }
        }
    }

    func record(_ windowID: CGWindowID) {
        order.removeAll { $0 == windowID }
        order.insert(windowID, at: 0)
        if order.count > Self.limit { order.removeLast(order.count - Self.limit) }
    }

    private func recordFocusedWindow(of pid: pid_t) {
        if let window = AX.focusedWindow(of: pid), let id = PrivateAPIs.windowID(of: window) {
            record(id)
        }
    }

    private func observe(_ pid: pid_t) {
        guard observers[pid] == nil, pid != ProcessInfo.processInfo.processIdentifier else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, focusCallback, &observer) == .success, let observer else { return }
        let app = AX.application(pid)
        AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, nil)
        AXObserverAddNotification(observer, app, kAXMainWindowChangedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func stopObserving(_ pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }
}

/// Delivered on the main run loop; the element is the window that took the focus.
private let focusCallback: AXObserverCallback = { _, element, _, _ in
    guard let id = PrivateAPIs.windowID(of: element) else { return }
    MainActor.assumeIsolated { WindowFocusHistory.shared.record(id) }
}
