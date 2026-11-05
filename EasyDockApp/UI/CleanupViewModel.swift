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
    /// One clean at a time: a second confirmed run would empty caches the
    /// first one had just moved to the Trash.
    var isCleaning = false
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
        guard !paths.isEmpty, !isCleaning else { return }
        isCleaning = true
        defer { isCleaning = false }
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

    /// The other tabs move things to the Trash; its figure is measured
    /// again so the confirmation for emptying it says what is really there.
    private func remeasureTrash() async {
        guard let trash = junkTargets.first(where: \.deletesPermanently)?.path else { return }
        junkSizes[trash] = await Task.detached(priority: .utility) { JunkCleanerService.directorySize(at: trash) }.value
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
        await remeasureTrash()
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
        await remeasureTrash()
    }

    // MARK: - Uninstall

    struct UninstallApp {
        let url: URL
        let bundleID: String
        let name: String
        let version: String?
        let icon: NSImage
        /// Already gone from the disk: only what it left is listed.
        var isRemoved = false
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
        clearOrphans()
        uninstallItems = []
        uninstallSelection = []
        uninstallRefusal = nil
        // A link to an app: trashing it would leave the app installed and
        // only its settings gone. An app inside another one is part of it.
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
        let isLink = values?.isSymbolicLink == true || values?.isAliasFile == true
        let isNested = url.deletingLastPathComponent().pathComponents.contains { $0.hasSuffix(".app") }
        guard !isLink, !isNested else {
            uninstallApp = nil
            uninstallRefusal = String(localized: "\(url.deletingPathExtension().lastPathComponent) is a link or sits inside another app, so it isn't removed here.", bundle: AppLocale.bundle)
            return
        }
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
        uninstallSelection = Set(uninstallItems.filter { !$0.matchedByName }.map(\.path))
        isFindingLeftovers = false
    }

    /// Set by a click on a removed-app notification, so the Cleanup page
    /// opens on its Uninstall tab.
    var opensUninstallTab = false

    /// What an app the watcher saw removed left behind, from its notification.
    func showLeftovers(ofRemoved bundleID: String) async {
        guard let (app, path) = AppRemovalWatcher.shared.removed[bundleID] else { return }
        clearOrphans()
        opensUninstallTab = true
        uninstallItems = []
        uninstallSelection = []
        uninstallRefusal = nil
        uninstallApp = UninstallApp(
            url: URL(fileURLWithPath: path),
            bundleID: app.bundleID,
            name: app.name,
            version: nil,
            icon: NSWorkspace.shared.icon(for: .application),
            isRemoved: true
        )
        refreshUninstallAppIsRunning()
        isFindingLeftovers = true
        uninstallItems = await uninstaller.leftovers(bundleID: app.bundleID, name: app.name)
        uninstallSelection = Set(uninstallItems.filter { !$0.matchedByName }.map(\.path))
        isFindingLeftovers = false
    }

    // MARK: - Installed apps

    enum AppSort: String, CaseIterable, Identifiable {
        case name = "Name"
        case size = "Size"
        case lastUsed = "Last Opened"
        var id: Self { self }
    }

    private(set) var installedApps: [AppUninstaller.InstalledApp] = []
    private(set) var isLoadingApps = false
    private var isMeasuringApps = false
    private(set) var isUninstallingApps = false
    var appQuery = ""
    var appSort: AppSort = .name
    /// App paths ticked for removal.
    var appSelection: Set<String> = []

    /// Filtered by the search, then sorted: by name; largest first; or the
    /// apps opened longest ago first, those never opened before them.
    var shownApps: [AppUninstaller.InstalledApp] {
        let query = appQuery.trimmingCharacters(in: .whitespaces)
        let found = query.isEmpty ? installedApps : installedApps.filter { $0.name.localizedCaseInsensitiveContains(query) }
        switch appSort {
        case .name:
            return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            return found.sorted { ($0.totalBytes ?? -1) > ($1.totalBytes ?? -1) }
        case .lastUsed:
            return found.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        }
    }

    var selectedAppsBytes: Int64 {
        installedApps.filter { appSelection.contains($0.path) }.reduce(0) { $0 + ($1.totalBytes ?? 0) }
    }

    /// The list shows from the apps' Info.plist; sizes fill in as each app
    /// is measured. Sizes already known are kept, so opening the tab again
    /// only measures apps that weren't there before.
    func loadInstalledApps() async {
        guard !isLoadingApps else { return }
        isLoadingApps = true
        let known = Dictionary(installedApps.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        installedApps = await uninstaller.installedApps().map { app in
            var app = app
            app.appBytes = known[app.path]?.appBytes
            app.leftoverBytes = known[app.path]?.leftoverBytes
            return app
        }
        appSelection.formIntersection(installedApps.map(\.path))
        isLoadingApps = false
        guard !isMeasuringApps else { return }
        isMeasuringApps = true
        await uninstaller.measure(installedApps.filter { $0.appBytes == nil }) { path, appBytes, leftoverBytes in
            await CleanupViewModel.shared.setSize(appBytes, leftoverBytes, for: path)
        }
        isMeasuringApps = false
    }

    private func setSize(_ appBytes: Int64, _ leftoverBytes: Int64, for path: String) {
        guard let index = installedApps.firstIndex(where: { $0.path == path }) else { return }
        installedApps[index].appBytes = appBytes
        installedApps[index].leftoverBytes = leftoverBytes
    }

    /// Called only after the view's confirmation dialog is accepted. Each
    /// app goes with what it left under its bundle identifier; an app that
    /// is open is skipped, so it can't write its files back.
    func uninstallSelectedApps() async {
        let apps = installedApps.filter { appSelection.contains($0.path) }
        guard !apps.isEmpty else { return }
        isUninstallingApps = true
        var moved: Int64 = 0
        var failed: [String] = []
        var open: [String] = []
        for app in apps {
            guard NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty else {
                open.append(app.name)
                continue
            }
            let items = await uninstaller.items(forAppAt: URL(fileURLWithPath: app.path), bundleID: app.bundleID, name: app.name)
                .filter { !$0.matchedByName }
            let result = await uninstaller.moveToTrash(items)
            moved += result.movedBytes
            failed += result.failedPaths
        }
        var message = String(localized: "Moved \(Self.formatBytes(moved)) to the Trash.", bundle: AppLocale.bundle)
        if !open.isEmpty {
            message += " " + String(localized: "Skipped because open: \(open.joined(separator: ", ")).", bundle: AppLocale.bundle)
        }
        if !failed.isEmpty {
            message += " " + String(localized: "Could not move: \(failed.prefix(3).joined(separator: ", "))", bundle: AppLocale.bundle)
        }
        statusMessage = message
        appSelection = []
        isUninstallingApps = false
        await remeasureTrash()
        await loadInstalledApps()
    }

    // MARK: - Files left by removed apps

    /// Nil while the list isn't shown.
    var orphanGroups: [AppUninstaller.OrphanGroup]?
    /// Paths; nothing is ticked at first, since some files can belong to a
    /// command-line tool or a helper that isn't an app.
    var orphanSelection: Set<String> = []
    var isFindingOrphans = false

    var selectedOrphanBytes: Int64 {
        (orphanGroups ?? []).flatMap(\.items).filter { orphanSelection.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }

    func findOrphans() async {
        clearUninstall()
        orphanSelection = []
        orphanGroups = []
        isFindingOrphans = true
        orphanGroups = await uninstaller.orphans()
        isFindingOrphans = false
    }

    func clearOrphans() {
        orphanGroups = nil
        orphanSelection = []
    }

    /// Called only after the view's confirmation dialog is accepted.
    func trashSelectedOrphans() async {
        let items = (orphanGroups ?? []).flatMap(\.items).filter { orphanSelection.contains($0.path) }
        guard !items.isEmpty else { return }
        let result = await uninstaller.moveToTrash(items)
        statusMessage = result.failedPaths.isEmpty
            ? String(localized: "Moved \(Self.formatBytes(result.movedBytes)) to the Trash.", bundle: AppLocale.bundle)
            : String(localized: "Moved \(Self.formatBytes(result.movedBytes)) to the Trash. Could not move: \(result.failedPaths.prefix(3).joined(separator: ", "))", bundle: AppLocale.bundle)
        await findOrphans()
        await remeasureTrash()
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
        await remeasureTrash()
        await loadInstalledApps()
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
