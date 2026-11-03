import AppKit
import EasyDockCore
import Foundation
import Observation

/// Drives the Cleanup pane's two halves — junk locations and the large-file
/// scan. One view model for both because they share the pane, the "freed
/// space" message, and nothing else; splitting them would mean two objects
/// that always appear together.
@MainActor
@Observable
final class CleanupViewModel {
    static let shared = CleanupViewModel()

    private let cleaner = JunkCleanerService()
    private let scanner = LargeFileScanner()

    // MARK: - Junk

    var junkTargets: [JunkTarget] = []
    /// Measured size per target path. Absent while a measurement is still
    /// running, which is what the row's placeholder keys off.
    var junkSizes: [String: Int64] = [:]
    var junkSelection: Set<String> = []
    var isMeasuring = false
    var statusMessage: String?

    /// Nested targets are excluded from both totals: the Homebrew, pip and
    /// Yarn caches live inside `~/Library/Caches`, so adding every measured
    /// target together counted those bytes twice.
    var totalJunkBytes: Int64 {
        JunkTarget.withoutNested(junkTargets).reduce(0) { $0 + (junkSizes[$1.path] ?? 0) }
    }

    var selectedJunkBytes: Int64 {
        JunkTarget.withoutNested(junkTargets.filter { junkSelection.contains($0.path) })
            .reduce(0) { $0 + (junkSizes[$1.path] ?? 0) }
    }

    func loadTargets() async {
        guard junkTargets.isEmpty else { return }
        junkTargets = await cleaner.targets
    }

    func measureJunk() async {
        guard !isMeasuring else { return }
        isMeasuring = true
        statusMessage = nil
        for await measurement in await cleaner.measureAll() {
            junkSizes[measurement.path] = measurement.bytes
        }
        isMeasuring = false
    }

    /// Called only after the view's confirmation dialog is accepted.
    func cleanSelected() async {
        let paths = junkSelection
        guard !paths.isEmpty else { return }
        let result = await cleaner.clean(paths: paths, knownSizes: junkSizes)

        // "Freed" only fits the Trash, which is emptied outright. Everything
        // else moves to the Trash, where it still occupies the disk until the
        // user empties it — claiming the space was freed would be a lie the
        // Finder immediately contradicts.
        let emptiedTheTrash = junkTargets.contains { paths.contains($0.path) && $0.deletesPermanently }
        let moved = Self.formatBytes(result.freedBytes)
        let headline = emptiedTheTrash
            ? String(localized: "Freed \(moved).", bundle: AppLocale.bundle)
            : String(localized: "Moved \(moved) to the Trash.", bundle: AppLocale.bundle)

        junkSelection.removeAll()
        // Deliberately not "no permission": a target can also be skipped for
        // being a relocated symlink, or partly cleaned with a few locked
        // files left behind. Naming a cause the app didn't establish sent
        // people to check permissions that were never the problem.
        statusMessage = result.skipped.isEmpty
            ? headline
            : headline + " " + String(localized: "Not fully cleared: \(result.skipped.joined(separator: ", ")).", bundle: AppLocale.bundle)

        await measureJunk()
    }

    // MARK: - Large files

    var scanRoots: [ScanRoot] = []
    var selectedRootPath: String = ""
    /// Threshold in MB. 100 MB is a useful default: low enough to catch old
    /// installers and video files, high enough that `~` doesn't return
    /// thousands of rows.
    var minimumMB: Int = 100
    var includeHidden = false

    var scanResults: [LargeFileEntry] = []
    var fileSelection: Set<String> = []
    var isScanning = false
    var scannedFiles = 0
    var currentFolder = ""
    var matchedBytes: Int64 = 0
    var scanErrorMessage: String?
    var hasScanned = false

    private var scanTask: Task<Void, Never>?
    /// Bumped per scan so a progress callback still in flight from a cancelled
    /// walk can't write its (much larger) file count over the new scan's
    /// freshly reset counter.
    private var scanGeneration = 0

    func loadScanRoots() {
        guard scanRoots.isEmpty else { return }
        let fileManager = FileManager.default
        scanRoots = ScanRoot.presets(homeDirectory: NSHomeDirectory())
            .filter { fileManager.fileExists(atPath: $0.path) }
        selectedRootPath = scanRoots.first { $0.title == "Downloads" }?.path ?? scanRoots.first?.path ?? ""
    }

    func startScan() {
        guard !selectedRootPath.isEmpty else { return }
        cancelScan()

        scanResults = []
        fileSelection = []
        scannedFiles = 0
        matchedBytes = 0
        scanErrorMessage = nil
        currentFolder = selectedRootPath
        isScanning = true

        let root = selectedRootPath
        let minimumBytes = Int64(minimumMB) * 1_048_576
        let includeHidden = includeHidden
        scanGeneration += 1
        let generation = scanGeneration

        scanTask = Task { [weak self] in
            // Bound strongly up front so the `@Sendable` progress closure
            // below captures an immutable reference — capturing the outer
            // optional `self` directly is a mutable capture and won't compile.
            guard let self else { return }
            let outcome = await self.scanner.scan(
                root: root, minimumBytes: minimumBytes, includeHidden: includeHidden
            ) { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.scanGeneration == generation else { return }
                    self.scannedFiles = progress.scannedFiles
                    self.currentFolder = progress.currentFolder
                }
            }
            guard !Task.isCancelled else { return }
            self.scanResults = outcome.entries
            self.scannedFiles = outcome.scannedFiles
            self.matchedBytes = outcome.matchedBytes
            self.scanErrorMessage = outcome.errorMessage
            self.currentFolder = ""
            self.isScanning = false
            self.hasScanned = true
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        currentFolder = ""
    }

    func revealSelectedFiles() {
        let urls = scanResults.filter { fileSelection.contains($0.path) }.map { URL(fileURLWithPath: $0.path) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Called only after the view's confirmation dialog is accepted.
    func trashSelectedFiles() async {
        let entries = scanResults.filter { fileSelection.contains($0.path) }
        guard !entries.isEmpty else { return }
        let result = await scanner.moveToTrash(entries)

        scanResults.removeAll { result.trashedPaths.contains($0.path) }
        fileSelection.removeAll()
        matchedBytes = scanResults.reduce(0) { $0 + $1.sizeBytes }
        statusMessage = result.failedNames.isEmpty
            ? String(localized: "Moved \(Self.formatBytes(result.freedBytes)) to the Trash.", bundle: AppLocale.bundle)
            : String(localized: "Moved \(Self.formatBytes(result.freedBytes)) to the Trash. Could not move: \(result.failedNames.prefix(3).joined(separator: ", "))", bundle: AppLocale.bundle)
    }

    // MARK: - Developer tools

    enum DeveloperTool { case simulators, homebrew }

    private let developerTools = DeveloperToolsCleaner()
    var developerStatus: DeveloperToolsCleaner.Status?
    /// The tool running now, if any; one at a time.
    var runningDeveloperTool: DeveloperTool?

    func checkDeveloperTools() async {
        developerStatus = await developerTools.status()
    }

    /// Called only after the view's confirmation dialog is accepted.
    func run(_ tool: DeveloperTool) async {
        guard runningDeveloperTool == nil else { return }
        runningDeveloperTool = tool
        let succeeded: Bool
        switch tool {
        case .simulators: succeeded = await developerTools.deleteUnavailableSimulators()
        case .homebrew: succeeded = await developerTools.cleanUpHomebrew()
        }
        statusMessage = succeeded ? String(localized: "Done.", bundle: AppLocale.bundle) : String(localized: "The tool reported an error; nothing may have changed.", bundle: AppLocale.bundle)
        developerStatus = await developerTools.status()
        runningDeveloperTool = nil
    }

    // MARK: - Old downloads

    var downloadsAge = 30
    var oldDownloads: [LargeFileEntry] = []
    var downloadSelection: Set<String> = []
    var isScanningDownloads = false
    var hasScannedDownloads = false
    var downloadsError: String?

    var downloadsFolder: String { NSHomeDirectory() + "/Downloads" }

    var selectedDownloadBytes: Int64 {
        oldDownloads.filter { downloadSelection.contains($0.path) }.reduce(0) { $0 + $1.sizeBytes }
    }

    func scanDownloads() async {
        isScanningDownloads = true
        let outcome = await scanner.oldItems(in: downloadsFolder, olderThanDays: downloadsAge)
        oldDownloads = outcome.entries
        downloadSelection = []
        downloadsError = outcome.errorMessage
        isScanningDownloads = false
        hasScannedDownloads = true
    }

    /// Called only after the view's confirmation dialog is accepted.
    func trashSelectedDownloads() async {
        let entries = oldDownloads.filter { downloadSelection.contains($0.path) }
        guard !entries.isEmpty else { return }
        let result = await scanner.moveToTrash(entries)
        oldDownloads.removeAll { result.trashedPaths.contains($0.path) }
        downloadSelection.removeAll()
        statusMessage = result.failedNames.isEmpty
            ? String(localized: "Moved \(Self.formatBytes(result.freedBytes)) to the Trash.", bundle: AppLocale.bundle)
            : String(localized: "Moved \(Self.formatBytes(result.freedBytes)) to the Trash. Could not move: \(result.failedNames.prefix(3).joined(separator: ", "))", bundle: AppLocale.bundle)
    }

    // MARK: - Uninstall

    struct UninstallApp {
        let url: URL
        let bundleID: String
        let name: String
        let version: String?
        let icon: NSImage
    }

    private let uninstaller = AppUninstaller()
    var uninstallApp: UninstallApp?
    var uninstallItems: [AppUninstaller.Item] = []
    var uninstallSelection: Set<String> = []
    var isFindingLeftovers = false
    /// Why the chosen app can't be removed here.
    var uninstallRefusal: String?

    var selectedUninstallBytes: Int64 {
        uninstallItems.filter { uninstallSelection.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }

    /// While the app is open it could write its files back, so nothing moves.
    private(set) var uninstallAppIsRunning = false

    func refreshUninstallAppIsRunning() {
        uninstallAppIsRunning = uninstallApp.map {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
        } ?? false
    }

    func chooseAppToUninstall() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await prepareUninstall(url) }
    }

    func prepareUninstall(_ url: URL) async {
        uninstallItems = []
        uninstallSelection = []
        uninstallRefusal = nil
        let bundle = Bundle(url: url)
        let bundleID = bundle?.bundleIdentifier
        guard !AppLeftovers.isProtected(bundleID: bundleID, path: url.path), let bundleID else {
            uninstallApp = nil
            uninstallRefusal = String(localized: "\(url.deletingPathExtension().lastPathComponent) is part of macOS or is EasyDock itself, so it isn't removed here.", bundle: AppLocale.bundle)
            return
        }
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
        uninstallApp = UninstallApp(
            url: url,
            bundleID: bundleID,
            name: name,
            version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            icon: NSWorkspace.shared.icon(forFile: url.path)
        )
        refreshUninstallAppIsRunning()
        isFindingLeftovers = true
        uninstallItems = await uninstaller.items(forAppAt: url, bundleID: bundleID, name: name)
        uninstallSelection = Set(uninstallItems.map(\.path))
        isFindingLeftovers = false
    }

    func quitUninstallApp() {
        guard let uninstallApp else { return }
        NSRunningApplication.runningApplications(withBundleIdentifier: uninstallApp.bundleID).forEach { $0.terminate() }
    }

    func clearUninstall() {
        uninstallApp = nil
        uninstallItems = []
        uninstallSelection = []
        uninstallRefusal = nil
    }

    /// Called only after the view's confirmation dialog is accepted.
    func uninstallSelected() async {
        let items = uninstallItems.filter { uninstallSelection.contains($0.path) }
        guard !items.isEmpty else { return }
        let result = await uninstaller.moveToTrash(items)
        statusMessage = result.failedPaths.isEmpty
            ? String(localized: "Moved \(Self.formatBytes(result.movedBytes)) to the Trash.", bundle: AppLocale.bundle)
            : String(localized: "Moved \(Self.formatBytes(result.movedBytes)) to the Trash. Could not move: \(result.failedPaths.prefix(3).joined(separator: ", "))", bundle: AppLocale.bundle)
        clearUninstall()
    }

    // MARK: - Formatting

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
