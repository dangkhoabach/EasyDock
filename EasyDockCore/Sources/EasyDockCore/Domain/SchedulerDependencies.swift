import Foundation

/// Implemented by the app target using `UNUserNotificationCenter`.
/// `route` is an app-internal path to navigate to if the user clicks through.
public protocol NotificationSending: Sendable {
    func notify(title: String, body: String, route: String?) async
}

/// Runs a scheduled cleanup. Implemented by the app target, since moving
/// items to the Trash needs AppKit — the same split as `JunkCleanerService`.
public protocol CleanupRunning: Sendable {
    /// Every target this build knows how to clean, so the scheduler can
    /// intersect the user's saved paths against what actually exists rather
    /// than trusting stored strings.
    func availableTargets() async -> [JunkTarget]
    /// Returns bytes moved to the Trash, and the names of anything that could
    /// not be fully cleared.
    func clean(_ targets: [JunkTarget]) async -> (bytes: Int64, skipped: [String])
}
