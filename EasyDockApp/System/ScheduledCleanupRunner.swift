import EasyDockCore
import Foundation

/// Lets the scheduler run the Cleanup tab's work unattended.
///
/// Thin on purpose: every safety rule already lives elsewhere — the scheduler
/// decides *when* and re-filters *what* through
/// `JunkTarget.scheduledCleaningTargets`, and `JunkCleanerService` owns the
/// deleting, including the one path allowed to bypass the Trash. Re-deriving
/// any of that here would give an unattended run its own second opinion about
/// which files may be destroyed, which is exactly what must not exist.
struct ScheduledCleanupRunner: CleanupRunning {
    private let service: JunkCleanerService

    init(service: JunkCleanerService) {
        self.service = service
    }

    func availableTargets() async -> [JunkTarget] {
        await service.targets
    }

    func clean(_ targets: [JunkTarget]) async -> (bytes: Int64, skipped: [String]) {
        // The cleaner measures each item as it moves it, so the figure is
        // what went. An open app's caches are left without counting as
        // skipped: the next run takes them.
        let result = await service.clean(paths: Set(targets.map(\.path)))
        return (result.freedBytes, result.skipped)
    }
}
