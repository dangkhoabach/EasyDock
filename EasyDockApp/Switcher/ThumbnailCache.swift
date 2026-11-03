import CoreGraphics
import Observation
@preconcurrency import ScreenCaptureKit

/// Small pictures of windows for the switcher, kept between openings so it
/// shows them at once and refreshes them behind. Taken with ScreenCaptureKit,
/// about 17 ms a window; nothing is written to disk.
@MainActor
@Observable
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private(set) var images: [CGWindowID: CGImage] = [:]
    @ObservationIgnored private var inFlight: Set<CGWindowID> = []

    /// Pictures of these windows, taken in the background.
    func refresh(_ windowIDs: [CGWindowID]) {
        guard CGPreflightScreenCaptureAccess() else { return }
        let wanted = windowIDs.filter { !inFlight.contains($0) }
        guard !wanted.isEmpty else { return }
        inFlight.formUnion(wanted)
        Task {
            let taken = await Self.capture(wanted)
            for (id, image) in taken { images[id] = image }
            inFlight.subtract(wanted)
        }
    }

    /// Drops pictures of windows that no longer exist.
    func keepOnly(_ windowIDs: Set<CGWindowID>) {
        images = images.filter { windowIDs.contains($0.key) }
    }

    private nonisolated static func capture(_ windowIDs: [CGWindowID]) async -> [CGWindowID: CGImage] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return [:] }
        let wanted = Set(windowIDs)
        let windows = content.windows.filter { wanted.contains($0.windowID) }
        return await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
            for window in windows {
                group.addTask {
                    let configuration = SCStreamConfiguration()
                    let scale = 360 / max(window.frame.width, 1)
                    configuration.width = 360
                    configuration.height = max(1, Int(window.frame.height * scale))
                    configuration.showsCursor = false
                    let image = try? await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
                    return (window.windowID, image)
                }
            }
            var result: [CGWindowID: CGImage] = [:]
            for await (id, image) in group { if let image { result[id] = image } }
            return result
        }
    }
}
