import AppKit

/// The order apps were last brought forward in, to find the one to switch to
/// when the app in front is minimized — the way Windows hands the focus to
/// the window that was behind.
@MainActor
final class AppActivationHistory {
    /// Most recent first.
    private var order: [pid_t] = []
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        order = Self.onScreenOrder()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated { self.moveToFront(pid) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated { self.order.removeAll { $0 == pid } }
        })
    }

    /// The most recently used app other than `pid` that can take the front:
    /// a regular app that is running and not hidden. Finder when there is none.
    /// Never EasyDock itself, whose window being open says nothing about
    /// what the user was working in.
    func nextApp(excluding pid: pid_t) -> NSRunningApplication? {
        let own = ProcessInfo.processInfo.processIdentifier
        let candidate = order.lazy
            .filter { $0 != pid && $0 != own }
            .compactMap(NSRunningApplication.init(processIdentifier:))
            .first { $0.activationPolicy == .regular && !$0.isHidden && !$0.isTerminated }
        return candidate ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
    }

    private func moveToFront(_ pid: pid_t) {
        order.removeAll { $0 == pid }
        order.insert(pid, at: 0)
    }

    /// Before any activation has been seen, the apps' windows on screen,
    /// front to back, are the best guess at their order.
    private static func onScreenOrder() -> [pid_t] {
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var pids: [pid_t] = []
        for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = window[kCGWindowOwnerPID as String] as? pid_t, !pids.contains(pid) {
                pids.append(pid)
            }
        }
        return pids
    }
}
