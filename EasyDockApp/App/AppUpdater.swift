import Sparkle

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController`, which reads
/// `SUFeedURL` and `SUPublicEDKey` from Info.plist. Same as the sibling apps.
///
/// Whether it checks on its own is the user's answer, not a build setting:
/// Info.plist does not pin `SUEnableAutomaticChecks`, so Sparkle asks on the
/// first launch and stores the reply, which Settings › Updates reads and
/// writes through `automaticallyChecksForUpdates`.
///
/// `shared` is lazy, so `AppDelegate` touches it at launch; otherwise the
/// scheduled check never starts.
@MainActor
enum AppUpdater {
    static let shared = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    /// Sparkle's own preference, not a copy in `@AppStorage` that could drift
    /// from the answer Sparkle acts on.
    static var automaticallyChecksForUpdates: Bool {
        get { shared.updater.automaticallyChecksForUpdates }
        set { shared.updater.automaticallyChecksForUpdates = newValue }
    }

    static func checkForUpdates() {
        shared.checkForUpdates(nil)
    }
}
