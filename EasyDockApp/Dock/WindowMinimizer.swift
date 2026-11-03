import AppKit
import ApplicationServices

/// Minimizes an app's windows and remembers exactly which ones, so the next
/// click brings all of them back — macOS on its own restores only one.
@MainActor
final class WindowMinimizer {
    private struct Minimized {
        var windows: [AXUIElement]
        /// Raised last on restore, so the window the user was in ends up in front.
        var focused: AXUIElement?
    }

    private var minimized: [pid_t: Minimized] = [:]

    /// `done` runs once every window is down (or the attempts ran out).
    func minimize(_ windows: [AXUIElement], focused: AXUIElement?, of pid: pid_t, then done: @escaping () -> Void) {
        minimized[pid] = Minimized(windows: windows, focused: focused)
        settle(windows, minimized: true, then: done)
    }

    /// Some window EasyDock minimized for this app is still minimized; one
    /// the user brought back by hand no longer counts.
    func hasMinimizedWindows(of pid: pid_t) -> Bool {
        minimized[pid]?.windows.contains(where: AX.isMinimized) ?? false
    }

    func restore(_ pid: pid_t) {
        guard let entry = minimized.removeValue(forKey: pid) else { return }
        settle(entry.windows.filter(AX.isMinimized), minimized: false) {
            if let focused = entry.focused { AX.raise(focused) }
        }
    }

    /// Asks again for any window not there yet. While one window plays the
    /// minimize animation, macOS drops a request for the next window of the
    /// same app (two TextEdit documents: one went down, one stayed), so a
    /// single pass is not enough.
    private func settle(_ windows: [AXUIElement], minimized: Bool, attempt: Int = 0, then done: (() -> Void)? = nil) {
        let pending = windows.filter { AX.isMinimized($0) != minimized }
        guard !pending.isEmpty, attempt < Self.maxAttempts else { done?(); return }
        pending.forEach { AX.setMinimized($0, minimized) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) {
            self.settle(pending, minimized: minimized, attempt: attempt + 1, then: done)
        }
    }

    /// Asked again every 0.1 s, so each window goes down as soon as the one
    /// before it has finished its animation; given up after three seconds.
    private static let maxAttempts = 30
    private static let retryInterval = 0.1

    func forget(_ pid: pid_t) {
        minimized[pid] = nil
    }
}
