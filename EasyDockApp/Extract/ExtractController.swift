import AppKit
import EasyDockCore
import Observation
import os
import SwiftUI

/// Extract: RAR, 7z, ZIP and the other archives macOS can't open, from a
/// double-click in Finder, its right-click menu or the Drop Zone. Each one
/// starts at once, one after another, on a small window that shows its
/// progress and asks for a password when one is needed. When everything
/// went well the window closes and Finder shows the results.
@MainActor
@Observable
final class ExtractController: NSObject, NSWindowDelegate {
    static let shared = ExtractController()

    enum State: Equatable {
        case waiting
        case working(Int, String?)
        /// `wrong`: the password typed last time was not the right one.
        case needsPassword(wrong: Bool)
        case done(URL?, damaged: Bool)
        case failed(String)
        case stopped
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var state: State
        /// Results go on the Drop Zone when the archive came from it.
        let fromShelf: Bool
    }

    private(set) var items: [Item] = []
    var isRunning: Bool { task != nil }

    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The password that opened the last archive of this batch: the parts
    /// of a set, or archives sent together, usually share one.
    @ObservationIgnored private var lastPassword: String?
    @ObservationIgnored private var passwordRequest: (id: UUID, reply: CheckedContinuation<String?, Never>)?
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.easydock", category: "extract")

    private override init() {}

    /// Adds the archives to the queue, once each: several parts of one set
    /// are one archive.
    func open(_ urls: [URL], fromShelf: Bool = false) {
        let known = Set(items.filter { !$0.isFinished }.map { Self.firstPart(of: $0.url) })
        var added = Set<String>()
        for url in urls {
            let first = Self.firstPart(of: url)
            guard !known.contains(first), added.insert(first).inserted else { continue }
            items.append(Item(url: url, state: .waiting, fromShelf: fromShelf))
        }
        let window = self.window ?? makeWindow()
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        startIfNeeded()
    }

    /// Whether a window is up for extracting: launched by a double-click
    /// on an archive, EasyDock shows only that.
    var hasWindow: Bool { window?.isVisible == true }

    private static func firstPart(of url: URL) -> String {
        let folder = url.deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return folder.appendingPathComponent(ArchiveVolumes.resolve(url.lastPathComponent, siblings: siblings).first).path
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: ExtractRoot()))
        window.styleMask = [.titled, .closable]
        window.title = String(localized: "Extract", bundle: AppLocale.bundle)
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }

    func close() {
        window?.close()
    }

    /// Closing the window stops the run and forgets the list.
    func windowWillClose(_ notification: Notification) {
        stop()
        items.removeAll()
        lastPassword = nil
    }

    func stop() {
        task?.cancel()
        answerPassword(nil)
    }

    // MARK: - Running

    private func startIfNeeded() {
        guard task == nil else { return }
        task = Task {
            while let index = items.firstIndex(where: { $0.state == .waiting }), !Task.isCancelled {
                await extract(items[index].id)
            }
            for index in items.indices where items[index].state == .waiting {
                items[index].state = .stopped
            }
            task = nil
            finish()
        }
    }

    private func extract(_ id: UUID) async {
        guard let url = item(id)?.url else { return }
        var destination: URL?
        var wrong = false
        var triedLast = false
        while true {
            update(id, .working(0, nil))
            attempt = nil
            let (wasWrong, tryLast) = (wrong, !triedLast)
            do {
                let result = try await ArchiveExtractor.extract(url, into: destination, progress: { percent, name in
                    Task { @MainActor in ExtractController.shared.progress(percent, name, for: id) }
                }, password: {
                    await ExtractController.shared.password(for: id, wrong: wasWrong, tryLast: tryLast)
                })
                update(id, .done(result.item, damaged: result.damaged))
                if let attempt { lastPassword = attempt.password }
                if SettingsViewModel.shared.settings.extractTrashArchives, !result.damaged {
                    await moveToTrash(result.parts)
                }
                return
            } catch {
                switch error {
                case .sevenZip(.wrongPassword):
                    // Asked again; "wrong" only after a password the user
                    // typed, not after the batch's last one tried for them.
                    if attempt?.typed == false {
                        triedLast = true
                    } else {
                        wrong = true
                    }
                case .cannotWrite:
                    guard destination == nil, let chosen = chooseFolder(for: url) else {
                        update(id, .failed(String(localized: "EasyDock can't write to this folder.", bundle: AppLocale.bundle)))
                        return
                    }
                    destination = chosen
                case .cancelled:
                    update(id, .stopped)
                    return
                case .sevenZip(let failure):
                    log.error("extraction failed: \(String(describing: failure), privacy: .public)")
                    update(id, .failed(Self.message(for: failure)))
                    return
                }
            }
        }
    }

    // MARK: - Passwords

    /// The password the running extraction was given, and whether the
    /// user typed it.
    @ObservationIgnored private var attempt: (password: String, typed: Bool)?

    /// The batch's last password first, once; then the user is asked.
    private func password(for id: UUID, wrong: Bool, tryLast: Bool) async -> String? {
        if tryLast, let lastPassword {
            attempt = (lastPassword, false)
            return lastPassword
        }
        update(id, .needsPassword(wrong: wrong))
        let given = await withCheckedContinuation { reply in
            passwordRequest = (id, reply)
        }
        if let given {
            attempt = (given, true)
            update(id, .working(0, nil))
        }
        return given
    }

    /// From the password field; nil skips this archive.
    func answerPassword(_ password: String?) {
        guard let request = passwordRequest else { return }
        passwordRequest = nil
        request.reply.resume(returning: password)
    }

    // MARK: - Results

    private func finish() {
        let done = items.compactMap { item -> URL? in
            if case .done(let url, _) = item.state { return url ?? item.url.deletingLastPathComponent() }
            return nil
        }
        log.info("extracted \(done.count, privacy: .public) of \(self.items.count, privacy: .public) archive(s)")
        let shelved = items.filter { $0.fromShelf }.compactMap { item -> URL? in
            if case .done(let url?, _) = item.state { return url }
            return nil
        }
        if !shelved.isEmpty { DropZoneController.shared.add(shelved.map { .file($0.path) }) }
        // Everything went well: nothing left to read in the window.
        let clean = !items.isEmpty && items.allSatisfy { if case .done(_, false) = $0.state { true } else { false } }
        if clean {
            let revealed = items.filter { !$0.fromShelf }.compactMap { item -> URL? in
                if case .done(let url, _) = item.state { return url ?? item.url }
                return nil
            }
            close()
            if !revealed.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(revealed) }
        }
    }

    var results: [URL] {
        items.compactMap { if case .done(let url?, _) = $0.state { url } else { nil } }
    }

    func showResultsInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(results)
    }

    private func moveToTrash(_ parts: [URL]) async {
        do {
            _ = try await NSWorkspace.shared.recycle(parts)
        } catch {
            log.error("couldn't move an archive to the Trash: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Asked when EasyDock can't write next to the archive, as on a disk
    /// image or a locked folder.
    private func chooseFolder(for archive: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Extract Here", bundle: AppLocale.bundle)
        panel.message = String(localized: "EasyDock can't write next to \(archive.lastPathComponent). Choose where to put its contents.", bundle: AppLocale.bundle)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func message(for failure: ExtractFailure) -> String {
        let bundle = AppLocale.bundle
        switch failure {
        case .wrongPassword: return String(localized: "The password is wrong.", bundle: bundle)
        case .missingPart(let name): return String(localized: "A part is missing: \(name). Put every part in the same folder.", bundle: bundle)
        case .noSpace: return String(localized: "There isn't enough free space on the disk.", bundle: bundle)
        case .notAnArchive: return String(localized: "This isn't an archive EasyDock can open.", bundle: bundle)
        case .damaged: return String(localized: "The archive is damaged.", bundle: bundle)
        case .other(let message):
            return message.isEmpty ? String(localized: "The archive couldn't be extracted.", bundle: bundle) : message
        }
    }

    // MARK: - Items

    private func item(_ id: UUID) -> Item? {
        items.first { $0.id == id }
    }

    private func update(_ id: UUID, _ state: State) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
    }

    private func progress(_ percent: Int, _ name: String?, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .working = items[index].state else { return }
        items[index].state = .working(percent, name)
    }
}

private extension ExtractController.Item {
    var isFinished: Bool {
        switch state {
        case .done, .failed, .stopped: true
        default: false
        }
    }
}

/// Finder's Services item for archives; the same provider as Quick Convert.
extension ServicesProvider {
    @objc func extractFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        MainActor.assumeIsolated { ExtractController.shared.open(urls) }
    }
}
