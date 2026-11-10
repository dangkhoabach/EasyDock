import AppKit
import EasyDockCore
import Observation
import os
import SwiftUI

/// Compress: files and folders into ZIP, 7z or a compressed tar, from
/// Finder's right-click menu or the Drop Zone. A small window shows the
/// choices, then each archive's progress. When everything went well the
/// window closes and Finder shows the archives.
@MainActor
@Observable
final class CompressController: NSObject, NSWindowDelegate {
    static let shared = CompressController()

    enum State: Equatable {
        case waiting
        case working(Int, String?)
        /// The archive or its parts, their bytes, and the files that couldn't be read.
        case done([URL], size: Int64, leftOut: [String])
        case failed(String)
        case stopped
    }

    struct Job: Identifiable {
        let id = UUID()
        let items: [URL]
        let fileName: String
        var state: State
    }

    /// What is being set up: the items, and the name the user may change.
    private(set) var items: [URL] = []
    var name = ""
    /// Never kept: gone with the window.
    var password = ""
    var confirmation = ""
    private(set) var jobs: [Job] = []
    /// Bytes in the items, once counted.
    private(set) var totalSize: Int64?

    var isRunning: Bool { task != nil }
    /// A run went through: show the results instead of the choices.
    var isFinished: Bool { !isRunning && !jobs.isEmpty }

    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var fromShelf = false
    /// Items sent while a run was going, set up once it is over.
    @ObservationIgnored private var queued: [(urls: [URL], fromShelf: Bool)] = []
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.easydock", category: "compress")

    private override init() {}

    var hasWindow: Bool { window?.isVisible == true }

    /// While a run is going, the items wait their turn and the window comes forward.
    func open(_ urls: [URL], fromShelf: Bool = false) {
        var seen = Set<String>()
        let urls = urls.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
        guard !urls.isEmpty else { return }
        if isRunning {
            queued.append((urls, fromShelf))
        } else {
            setUp(urls, fromShelf: fromShelf)
        }
        let window = self.window ?? makeWindow()
        // In the language chosen now, which may have changed since it was made.
        window.title = String(localized: "Compress", bundle: AppLocale.bundle)
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func setUp(_ urls: [URL], fromShelf: Bool) {
        items = urls
        self.fromShelf = fromShelf
        jobs = []
        password = ""
        confirmation = ""
        name = CompressNaming.defaultName(for: urls.map(\.path), several: Self.severalName) { Self.isFolder(URL(fileURLWithPath: $0)) }
        totalSize = nil
        let paths = urls.map(\.path)
        Task {
            let size = await Task.detached(priority: .userInitiated) { ArchiveCompressor.size(of: paths) }.value
            if self.items.map(\.path) == paths { self.totalSize = size }
        }
    }

    private static var severalName: String { String(localized: "Archive", bundle: AppLocale.bundle) }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: CompressRoot()))
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }

    func close() {
        window?.close()
    }

    /// Closing the window stops the run and forgets everything, the
    /// password and what was waiting included.
    func windowWillClose(_ notification: Notification) {
        stop()
        queued.removeAll()
        items = []
        jobs = []
        password = ""
        confirmation = ""
    }

    func stop() {
        task?.cancel()
    }

    // MARK: - Choices

    private var settings: AppSettings { SettingsViewModel.shared.settings }

    /// Several items, each to its own archive.
    var makesOneEach: Bool { items.count > 1 && settings.compressEachItem }

    /// Why the choices can't go ahead yet, as a sentence; nil when they can.
    var problem: String? {
        let format = settings.compressFormat
        let clashes = makesOneEach ? [] : CompressNaming.clashingNames(items.map(\.path))
        if !clashes.isEmpty {
            return String(localized: "More than one item is named \(clashes.joined(separator: ", ")). Rename one, or make one archive for each item.", bundle: AppLocale.bundle)
        }
        if format.takesPassword, !password.isEmpty {
            if !format.accepts(password: password) {
                return String(localized: "A ZIP password can only have letters without accents, digits and symbols. Choose 7z for a password with accents.", bundle: AppLocale.bundle)
            }
            if confirmation != password {
                return String(localized: "The two passwords are not the same.", bundle: AppLocale.bundle)
            }
        }
        return nil
    }

    // MARK: - Running

    func compress() {
        guard !isRunning, !items.isEmpty, problem == nil else { return }
        let format = settings.compressFormat
        let options = ArchiveCompressor.Options(format: format, level: settings.compressLevel,
                                                password: format.takesPassword ? password : "", partSize: settings.compressPartSize)
        if makesOneEach {
            jobs = items.map { item in
                let base = CompressNaming.defaultName(for: [item.path], several: Self.severalName) { _ in Self.isFolder(item) }
                return Job(items: [item], fileName: CompressNaming.fileName(base, format: format, fallback: Self.severalName), state: .waiting)
            }
        } else {
            jobs = [Job(items: items, fileName: CompressNaming.fileName(name, format: format, fallback: Self.severalName), state: .waiting)]
        }
        // Once used, the password is gone from the window.
        password = ""
        confirmation = ""
        log.info("compressing \(self.items.count, privacy: .public) item(s) to \(format.rawValue, privacy: .public), \(self.jobs.count, privacy: .public) archive(s)")
        task = Task {
            var chosenFolder: URL?
            for job in jobs {
                guard !Task.isCancelled else { break }
                chosenFolder = await run(job, options: options, chosenFolder: chosenFolder)
            }
            for index in jobs.indices where jobs[index].state == .waiting {
                jobs[index].state = .stopped
            }
            task = nil
            finish()
        }
    }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Runs one archive; returns the folder the user chose when EasyDock
    /// couldn't write next to the items, kept for the archives after it.
    private func run(_ job: Job, options: ArchiveCompressor.Options, chosenFolder: URL?) async -> URL? {
        var destination = chosenFolder ?? job.items[0].deletingLastPathComponent()
        var chosen = chosenFolder
        let id = job.id
        while true {
            update(id, .working(0, nil))
            do {
                let result = try await ArchiveCompressor.compress(job.items, fileName: job.fileName, into: destination, options: options) { percent, name in
                    Task { @MainActor in CompressController.shared.progress(percent, name, for: id) }
                }
                let size = result.parts.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                update(id, .done(result.parts, size: size, leftOut: result.leftOut))
                return chosen
            } catch {
                switch error {
                case .cannotWrite:
                    // Asked once; a folder chosen that can't be written either fails.
                    guard destination != chosen, let folder = chooseFolder(for: job.fileName) else {
                        update(id, .failed(String(localized: "EasyDock can't write to this folder.", bundle: AppLocale.bundle)))
                        return chosen
                    }
                    chosen = folder
                    destination = folder
                case .cancelled:
                    update(id, .stopped)
                    return chosen
                case .sevenZip(let failure):
                    log.error("compressing failed: \(String(describing: failure), privacy: .private)")
                    update(id, .failed(Self.message(for: failure)))
                    return chosen
                }
            }
        }
    }

    // MARK: - Results

    private func finish() {
        let made = results
        log.info("made \(made.count, privacy: .public) file(s) for \(self.jobs.count, privacy: .public) archive(s)")
        if fromShelf, !made.isEmpty { DropZoneController.shared.add(made.map { .file($0.path) }) }
        // Everything went well: nothing left to read in the window.
        let clean = jobs.allSatisfy { if case .done(_, _, let leftOut) = $0.state { leftOut.isEmpty } else { false } }
        if clean {
            let revealed = fromShelf ? [] : made
            if queued.isEmpty {
                close()
            } else {
                let next = queued.removeFirst()
                setUp(next.urls, fromShelf: next.fromShelf)
            }
            if !revealed.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(revealed) }
        }
    }

    /// From the finished window: the next items that were waiting, if any.
    func done() {
        if queued.isEmpty {
            close()
        } else {
            let next = queued.removeFirst()
            setUp(next.urls, fromShelf: next.fromShelf)
        }
    }

    var results: [URL] {
        jobs.flatMap { job -> [URL] in
            if case .done(let parts, _, _) = job.state { return parts }
            return []
        }
    }

    func showResultsInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(results)
    }

    /// Asked when EasyDock can't write next to the items, as on a disk
    /// image or a locked folder.
    private func chooseFolder(for fileName: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Save Here", bundle: AppLocale.bundle)
        panel.message = String(localized: "EasyDock can't write next to these items. Choose where to save \(fileName).", bundle: AppLocale.bundle)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func message(for failure: CompressFailure) -> String {
        let bundle = AppLocale.bundle
        switch failure {
        case .noSpace: return String(localized: "There isn't enough free space on the disk.", bundle: bundle)
        case .clashingNames(let names):
            return String(localized: "More than one item is named \(names.joined(separator: ", ")). Rename one, or make one archive for each item.", bundle: bundle)
        case .other(let message):
            return message.isEmpty ? String(localized: "The archive couldn't be made.", bundle: bundle) : message
        }
    }

    // MARK: - Jobs

    private func update(_ id: UUID, _ state: State) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
    }

    private func progress(_ percent: Int, _ name: String?, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), case .working = jobs[index].state else { return }
        jobs[index].state = .working(percent, name)
    }
}

/// Finder's Services item for files and folders; the same provider as Quick Convert.
extension ServicesProvider {
    @objc func compressFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        MainActor.assumeIsolated { CompressController.shared.open(urls) }
    }
}
