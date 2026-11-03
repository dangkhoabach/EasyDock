import AppKit
import Observation

/// Whether Stage Manager is on. The Dock click stands aside while it is, and
/// says so; the setting can change in Control Center at any time, so it is
/// read again whenever EasyDock becomes active, the panel opens, or a Dock
/// click arrives.
@MainActor
@Observable
final class StageManager {
    static let shared = StageManager()

    private(set) var isOn = false

    private init() {
        refresh()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { _ = StageManager.shared.refresh() }
        }
    }

    @discardableResult
    func refresh() -> Bool {
        let domain = "com.apple.WindowManager" as CFString
        CFPreferencesAppSynchronize(domain)
        let value = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, domain) as? Bool ?? false
        if value != isOn { isOn = value }
        return value
    }
}
