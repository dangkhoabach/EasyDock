import AppKit
import ServiceManagement

/// Registers/unregisters this app bundle as a Login Item via `SMAppService`.
/// Same logic as SignalBar and FoldAway.
@MainActor
final class LoginItemManager {
    static let shared = LoginItemManager()

    private var service: SMAppService { .mainApp }

    var isEnabled: Bool {
        switch service.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    /// `true` while macOS requires the user to approve the item in System
    /// Settings before it will actually run (common on first registration).
    var requiresApproval: Bool {
        service.status == .requiresApproval
    }

    /// Only calls `register()` when the service isn't already
    /// Enabled/RequiresApproval — `SMAppService`'s own docs warn that
    /// re-registering an already-registered service isn't guaranteed to be a
    /// safe no-op; doing so produced a duplicate entry in System Settings >
    /// Login Items in SignalBar's Rust version. Returns whether the item
    /// now needs the user's approval.
    @discardableResult
    func enable() throws -> Bool {
        if service.status != .enabled, service.status != .requiresApproval {
            try service.register()
        }
        let needsApproval = service.status == .requiresApproval
        if needsApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        return needsApproval
    }

    func disable() throws {
        guard service.status != .notRegistered else { return }
        try service.unregister()
    }

    /// Whether macOS opened the app as a login item, read once at launch.
    /// The open event says so when macOS sets it, which it doesn't always do
    /// for an `SMAppService` item; a launch within two minutes of the
    /// console login counts too.
    static func wasOpenedAtLogin(now: Date = Date()) -> Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        if event?.eventID == kAEOpenApplication,
           event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            return true
        }
        guard let login = consoleLoginDate() else { return false }
        return now.timeIntervalSince(login) < 120
    }

    /// When this user logged in at the Mac itself, from the login records.
    private static func consoleLoginDate() -> Date? {
        setutxent()
        defer { endutxent() }
        let user = NSUserName()
        while let entry = getutxent() {
            var record = entry.pointee
            guard record.ut_type == USER_PROCESS else { continue }
            let line = withUnsafeBytes(of: &record.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let name = withUnsafeBytes(of: &record.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if line == "console", name == user {
                return Date(timeIntervalSince1970: TimeInterval(record.ut_tv.tv_sec))
            }
        }
        return nil
    }
}
