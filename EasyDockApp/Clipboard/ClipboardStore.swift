import AppKit
import Carbon.HIToolbox
import EasyDockCore
import Observation
import os

/// The clipboard history as the app uses it: the list the panels show, and
/// what choosing, pinning and deleting an item do.
@MainActor
@Observable
final class ClipboardStore {
    static let shared = ClipboardStore()

    private(set) var items: [ClipboardItem] = []
    /// Why the history isn't available, when it isn't (no key in the Keychain).
    private(set) var failure: String?

    @ObservationIgnored private var repository: ClipboardRepository?
    @ObservationIgnored private let watcher = PasteboardWatcher()
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.easydock", category: "clipboard")

    private var settings: AppSettings { SettingsViewModel.shared.settings }

    /// The key is read off the main thread: if macOS asks before handing
    /// out a Keychain item, that wait must not freeze the app, which it did
    /// when a build signed differently had made the item.
    func start() {
        guard repository == nil, let database = AppDatabase.shared else { return }
        Task {
            let key = await Task.detached { Result { try ClipboardKeyStore.loadOrCreate() } }.value
            switch key {
            case .success(let key):
                repository = ClipboardRepository(dbQueue: database.dbQueue, crypto: ClipboardCrypto(key: key))
                failure = nil
            case .failure(let error):
                failure = error.localizedDescription
                log.error("clipboard key unavailable: \(error.localizedDescription, privacy: .public)")
                return
            }
            prune()
            reload()
            watcher.start { copy in ClipboardStore.shared.record(copy) }
            log.info("clipboard history ready: \(self.items.count) items")
        }
    }

    // MARK: - Recording

    private func record(_ copy: PasteboardWatcher.Copy) {
        let source = copy.sourceApp ?? "?"
        guard settings.clipboardEnabled, let repository else {
            log.info("copy from \(source, privacy: .public) not recorded: recording is off")
            return
        }
        if settings.clipboardExcludedApps.contains(source) {
            log.info("copy from \(source, privacy: .public) not recorded: excluded app")
            return
        }
        do {
            try repository.add(copy.content, preview: copy.preview, sourceApp: copy.sourceApp)
            prune()
            reload()
            log.info("recorded \(copy.content.kind.rawValue, privacy: .public) from \(source, privacy: .public); \(self.items.count) items")
        } catch {
            log.error("could not record a copy: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func prune() {
        try? repository?.prune(maxItems: settings.clipboardMaxItems, maxDays: settings.clipboardMaxDays)
    }

    private func reload() {
        items = (try? repository?.items()) ?? []
    }

    // MARK: - Actions

    /// Puts the item back on the clipboard and, unless the user turned it
    /// off, pastes it into the app in front. `close` hides the panel first:
    /// while it is the key window, ⌘V would go to it.
    func choose(_ item: ClipboardItem, plainText: Bool = false, close: () -> Void) {
        guard let content = try? repository?.content(of: item.id) else { return }
        Self.write(content, plainText: plainText)
        try? repository?.markUsed(item.id)
        reload()
        close()
        guard settings.clipboardPasteDirectly else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Self.pressCommandV() }
    }

    /// Back on the clipboard without pasting.
    func copy(_ item: ClipboardItem) {
        guard let content = try? repository?.content(of: item.id) else { return }
        Self.write(content, plainText: false)
        try? repository?.markUsed(item.id)
        reload()
    }

    func togglePin(_ item: ClipboardItem) {
        try? repository?.setPinned(item.id, !item.isPinned)
        reload()
    }

    func delete(_ item: ClipboardItem) {
        try? repository?.delete(item.id)
        reload()
    }

    /// Everything goes, and so does the key: whatever a backup of the old
    /// database still holds can't be read any more.
    func clearHistory() {
        try? repository?.deleteAll()
        ClipboardKeyStore.delete()
        repository = nil
        items = []
        watcher.stop()
        start()
    }

    // MARK: - Pasteboard

    private static func write(_ content: ClipboardContent, plainText: Bool) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch content.kind {
        case .files:
            pasteboard.writeObjects((content.filePaths ?? []).map { NSURL(fileURLWithPath: $0) })
        case .image:
            if let png = content.png { pasteboard.setData(png, forType: .png) }
        case .text:
            if let text = content.text { pasteboard.setString(text, forType: .string) }
            if !plainText {
                if let rtf = content.rtf { pasteboard.setData(rtf, forType: .rtf) }
                if let html = content.html { pasteboard.setData(html, forType: .html) }
            }
        }
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType(PasteboardMarkers.fromHistory))
    }

    /// Posting ⌘V needs Accessibility, which EasyDock already holds.
    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
