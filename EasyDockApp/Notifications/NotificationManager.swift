import AppKit
import EasyDockCore
import UserNotifications

/// Native `UNUserNotificationCenter` notifications with click-through to the
/// System or Cleanup tab.
///
/// `@MainActor`-isolated because everything it touches after a click
/// (`NSApp`, windows, `onRouteSelected`) must run on the main thread; the two
/// `UNUserNotificationCenterDelegate` methods are `nonisolated` because the
/// system calls them on an arbitrary thread (a hard requirement of the
/// `@objc` delegate protocol), and immediately hop back via `Task { @MainActor
/// in ... }` — extracting only the `Sendable` primitives (action identifier,
/// route string) first, to avoid `sending` data-race errors.
@MainActor
final class NotificationManager: NSObject, NotificationSending, @unchecked Sendable {
    static let shared = NotificationManager()

    /// Set by whatever wires up real navigation. Until then, a click-through
    /// still brings the app forward — it just has nowhere in-app to
    /// navigate to yet.
    var onRouteSelected: ((String) -> Void)?

    // `nonisolated`: read from the two nonisolated delegate methods below,
    // which the system calls off the main actor.
    nonisolated private static let categoryIdentifier = "EASYDOCK_ALERT"
    nonisolated private static let viewDetailsActionIdentifier = "VIEW_DETAILS"
    nonisolated private static let routeUserInfoKey = "route"

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategory()
    }

    private func registerCategory() {
        let viewDetails = UNNotificationAction(
            identifier: Self.viewDetailsActionIdentifier,
            title: String(localized: "View Details", bundle: AppLocale.bundle),
            options: [.foreground]
        )
        let category = UNNotificationCategory(identifier: Self.categoryIdentifier, actions: [viewDetails], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Only call this at the moment the user actually opts in (turning on
    /// the schedule or setting an alert threshold), never at app launch, so
    /// the permission prompt has context instead of appearing out of
    /// nowhere. macOS asks once; later calls return the stored answer.
    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// Posted unconditionally: without permission macOS drops it, which is
    /// the only on/off switch notifications have here.
    func notify(title: String, body: String, route: String?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.categoryIdentifier
        if let route {
            content.userInfo = [Self.routeUserInfoKey: route]
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Shows the banner even while the app is frontmost — otherwise
    /// foreground-delivered notifications are silently suppressed by default.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let route = response.notification.request.content.userInfo[NotificationManager.routeUserInfoKey] as? String

        guard actionIdentifier == UNNotificationDefaultActionIdentifier || actionIdentifier == NotificationManager.viewDetailsActionIdentifier else {
            completionHandler()
            return
        }

        Task { @MainActor in
            WindowPresenter.showMainWindow()
            if let route {
                NotificationManager.shared.onRouteSelected?(route)
            }
        }
        completionHandler()
    }
}

/// The scheduler's alerts in the language picked in Settings. Core only
/// knows the English text.
struct LocalizedAlertText: AlertTextLocalizing {
    func text(for message: AlertMessage) -> (title: String, body: String) {
        // English is the source language and has no table of its own.
        guard AppLocale.selected != .en else { return EnglishAlertText().text(for: message) }
        let bundle = AppLocale.bundle
        switch message {
        case .cleanupFinished(let freed, let locations, let skipped):
            var body = String(localized: "Moved \(freed) to the Trash from \(locations) locations.", bundle: bundle)
            if !skipped.isEmpty {
                body += " " + String(localized: "Not fully cleared: \(skipped.joined(separator: ", ")).", bundle: bundle)
            }
            return (String(localized: "Scheduled cleanup finished", bundle: bundle), body)
        case .systemHot(let celsius, let thresholdCelsius):
            return (String(localized: "Your Mac is running hot", bundle: bundle),
                    String(localized: "\(celsius)°C (threshold \(thresholdCelsius)°C)", bundle: bundle))
        case .batteryLow(let percent):
            return (String(localized: "Battery low", bundle: bundle),
                    String(localized: "\(percent)% left — plug in the charger", bundle: bundle))
        }
    }
}
