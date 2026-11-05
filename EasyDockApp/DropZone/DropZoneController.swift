import AppKit
import EasyDockCore
import Observation
import os
import QuickLookThumbnailing

/// Drop Zone: a shelf that floats above every window and holds files,
/// links and text while the user goes to where they belong.
///
/// It opens by shaking the pointer while dragging a file, by dragging a file
/// onto the notch (or the middle of a screen's top edge), or with its
/// shortcut. Files stay where they are: the shelf keeps their place, and
/// what arrives without a file (a picture from a web page, a promised file)
/// is written to EasyDock's cache. Nothing on it outlasts EasyDock.
@MainActor
@Observable
final class DropZoneController {
    static let shared = DropZoneController()

    private(set) var shelf = DropShelf()
    /// A drag is over the shelf.
    var isTargeted = false
    private(set) var thumbnails: [String: NSImage] = [:]

    @ObservationIgnored private var panel: DropZonePanel?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var bookmarks: [String: Data] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.easydock", category: "drop-zone")

    // The drag in progress.
    @ObservationIgnored private let dragPasteboard = NSPasteboard(name: .drag)
    @ObservationIgnored private var changeCountAtMouseDown = 0
    @ObservationIgnored private var dragEvents = 0
    @ObservationIgnored private var isFileDrag = false
    @ObservationIgnored private var shake = ShakeDetector()
    @ObservationIgnored private var openedByDrag = false

    /// Writing promised files belongs off the main thread.
    @ObservationIgnored private let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }()

    static let cacheFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appending(path: "com.dangkhoabach.easydock/DropZone", directoryHint: .isDirectory)

    /// Finder writes the drag pasteboard 3 events into a drag, Safari 6;
    /// past this many, the drag is something else and isn't looked at again.
    private static let dragEventsToWatch = 20
    private static let draggedTypes: Set<NSPasteboard.PasteboardType> = [
        .fileURL, .URL, .png, .tiff, .string,
        NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
    ]

    private var settings: AppSettings { SettingsViewModel.shared.settings }
    var isShown: Bool { panel?.isVisible == true }

    private init() {}

    func start() {
        SettingsViewModel.shared.loadIfNeeded()
        // What a previous run wrote is gone with its shelf.
        try? FileManager.default.removeItem(at: Self.cacheFolder)
        trackSettings()
    }

    // MARK: - Opening while dragging

    /// The pointer is watched only while one of the two drag gestures is
    /// on; turned off, nothing runs at all.
    private func trackSettings() {
        withObservationTracking {
            _ = settings.dropZoneShake
            _ = settings.dropZoneTopEdge
        } onChange: {
            Task { @MainActor in DropZoneController.shared.trackSettings() }
        }
        let wanted = settings.dropZoneShake || settings.dropZoneTopEdge
        if wanted, monitor == nil {
            // Mouse events need no permission to watch.
            monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
                MainActor.assumeIsolated { DropZoneController.shared.handle(event) }
            }
        } else if !wanted, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            changeCountAtMouseDown = dragPasteboard.changeCount
            dragEvents = 0
            isFileDrag = false
            shake = ShakeDetector()
        case .leftMouseDragged:
            dragEvents += 1
            if !isFileDrag, dragEvents <= Self.dragEventsToWatch, dragPasteboard.changeCount != changeCountAtMouseDown {
                // Safari fills in the types a few events after the count changes.
                isFileDrag = !Self.draggedTypes.isDisjoint(with: dragPasteboard.types ?? [])
            }
            guard isFileDrag, !isShown else { return }
            let pointer = NSEvent.mouseLocation
            if settings.dropZoneTopEdge, let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) {
                let zone = DropZoneHotZone.rect(screen: screen.frame, notch: Self.notch(of: screen))
                if zone.insetBy(dx: -10, dy: -1).contains(pointer) {
                    show(below: zone, on: screen, byDrag: true)
                    return
                }
            }
            if settings.dropZoneShake, shake.add(x: pointer.x, at: event.timestamp) {
                show(around: pointer, byDrag: true)
            }
        case .leftMouseUp:
            guard openedByDrag else { return }
            openedByDrag = false
            // Opened by a drag that was then dropped elsewhere: put away.
            // The drop on the shelf itself, if any, lands before this runs.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                if DropZoneController.shared.shelf.items.isEmpty { DropZoneController.shared.hide() }
            }
        default:
            break
        }
    }

    private static func notch(of screen: NSScreen) -> CGRect? {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return nil }
        return CGRect(x: left.maxX, y: screen.frame.maxY - screen.safeAreaInsets.top, width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
    }

    // MARK: - The panel

    func toggle() {
        isShown ? hide() : show(around: NSEvent.mouseLocation, byDrag: false)
    }

    func hide() {
        panel?.orderOut(nil)
        isTargeted = false
    }

    /// Centered on the pointer, so a shaken file drops straight onto it.
    private func show(around point: CGPoint, byDrag: Bool) {
        let panel = self.panel ?? makePanel()
        let size = panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        var origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        present(panel, at: origin, byDrag: byDrag)
    }

    /// Hanging from the notch.
    private func show(below zone: CGRect, on screen: NSScreen, byDrag: Bool) {
        let panel = self.panel ?? makePanel()
        let size = panel.frame.size
        let origin = CGPoint(x: zone.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 6)
        present(panel, at: origin, byDrag: byDrag)
    }

    private func present(_ panel: DropZonePanel, at origin: CGPoint, byDrag: Bool) {
        openedByDrag = byDrag
        refreshFiles()
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        log.info("shown")
    }

    private func makePanel() -> DropZonePanel {
        let panel = DropZonePanel(size: CGSize(width: 320, height: 340))
        panel.onClose = { [weak self] in self?.hide() }
        self.panel = panel
        return panel
    }

    // MARK: - Items

    func add(_ items: [ShelfItem]) {
        for case .file(let path) in items where bookmarks[path] == nil {
            bookmarks[path] = try? URL(fileURLWithPath: path).bookmarkData(options: .minimalBookmark)
        }
        let dropped = shelf.add(items)
        forget(dropped)
        items.forEach(loadThumbnail)
        log.info("added \(items.count, privacy: .public) item(s)")
    }

    func remove(_ items: [ShelfItem]) {
        shelf.remove(items)
        forget(items)
        if shelf.items.isEmpty { hide() }
    }

    /// Moved out by a drag: done with.
    func didMove(_ items: [ShelfItem]) {
        remove(items)
    }

    /// Follows files moved since they were dropped, and lets go of the
    /// ones that are gone.
    func refreshFiles() {
        for case .file(let path) in shelf.items {
            var isStale = false
            let resolved = bookmarks[path].flatMap { try? URL(resolvingBookmarkData: $0, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &isStale) }
            guard let resolved, FileManager.default.fileExists(atPath: resolved.path) else {
                remove([.file(path)])
                continue
            }
            if resolved.path != path {
                shelf.replace(.file(path), with: .file(resolved.path))
                bookmarks[resolved.path] = bookmarks.removeValue(forKey: path)
                thumbnails[resolved.path] = thumbnails.removeValue(forKey: path)
            }
        }
    }

    /// Takes in a drop: files as they are, promised files into the cache,
    /// links, pictures without a file, and text.
    func accept(_ pasteboard: NSPasteboard) -> Bool {
        if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
            add(files.map { .file($0.path) })
            return true
        }
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty,
           let folder = newCacheFolder() {
            for promise in promises {
                promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: promiseQueue) { url, error in
                    guard error == nil else { return }
                    Task { @MainActor in DropZoneController.shared.add([.file(url.path)]) }
                }
            }
            return true
        }
        if let links = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !links.isEmpty {
            add(links.map { .link($0.absoluteString) })
            return true
        }
        if let image = NSImage(pasteboard: pasteboard), let folder = newCacheFolder(),
           let png = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]) {
            let url = folder.appending(path: String(localized: "Picture", bundle: AppLocale.bundle) + ".png")
            guard (try? png.write(to: url)) != nil else { return false }
            add([.file(url.path)])
            return true
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            add([.text(text)])
            return true
        }
        return false
    }

    /// A folder of its own for each drop, so two files with the same name
    /// never meet.
    private func newCacheFolder() -> URL? {
        let folder = Self.cacheFolder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        return (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil ? folder : nil
    }

    /// Deletes what EasyDock wrote for these items; the user's own files stay.
    private func forget(_ items: [ShelfItem]) {
        for case .file(let path) in items {
            bookmarks[path] = nil
            thumbnails[path] = nil
            let url = URL(fileURLWithPath: path)
            guard url.path.hasPrefix(Self.cacheFolder.path + "/") else { continue }
            // One drop can bring several files into the same folder.
            try? FileManager.default.removeItem(at: url)
            let folder = url.deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    private func loadThumbnail(_ item: ShelfItem) {
        guard case .file(let path) = item, thumbnails[path] == nil else { return }
        thumbnails[path] = NSWorkspace.shared.icon(forFile: path)
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 64, height: 64),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
            guard let image = thumbnail?.nsImage else { return }
            Task { @MainActor in
                if DropZoneController.shared.thumbnails[path] != nil { DropZoneController.shared.thumbnails[path] = image }
            }
        }
    }

    // MARK: - Actions

    func open(_ items: [ShelfItem]) {
        for item in items {
            switch item {
            case .file(let path): NSWorkspace.shared.open(URL(fileURLWithPath: path))
            case .link(let link): if let url = URL(string: link) { NSWorkspace.shared.open(url) }
            case .text: break
            }
        }
    }

    func showInFinder(_ items: [ShelfItem]) {
        let urls = items.compactMap { item -> URL? in
            if case .file(let path) = item { return URL(fileURLWithPath: path) }
            return nil
        }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /// Paths for files, the address for links, the text itself; one per line.
    func copy(_ items: [ShelfItem]) {
        let lines = items.map { item -> String in
            switch item {
            case .file(let path): path
            case .link(let link): link
            case .text(let text): text
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    /// The right-click menu of one item, or of all of them.
    func menu(for items: [ShelfItem]) -> NSMenu {
        let menu = NSMenu()
        func add(_ key: String.LocalizationValue, _ action: @escaping @MainActor () -> Void) {
            menu.addItem(ClosureMenuItem(title: String(localized: key, bundle: AppLocale.bundle), action: action))
        }
        let hasFiles = items.contains { if case .file = $0 { true } else { false } }
        if items.contains(where: { if case .text = $0 { false } else { true } }) {
            add("Open") { DropZoneController.shared.open(items) }
        }
        if hasFiles {
            add("Show in Finder") { DropZoneController.shared.showInFinder(items) }
        }
        add(items.count == 1 ? "Copy" : "Copy All") { DropZoneController.shared.copy(items) }
        let shareable: [Any] = items.map { item -> Any in
            switch item {
            case .file(let path): URL(fileURLWithPath: path)
            case .link(let link): URL(string: link) ?? link
            case .text(let text): text
            }
        }
        menu.addItem(NSSharingServicePicker(items: shareable).standardShareMenuItem)
        menu.addItem(.separator())
        add(items.count == 1 ? "Remove from Drop Zone" : "Clear Drop Zone") { DropZoneController.shared.remove(items) }
        return menu
    }
}

/// A menu item that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, action handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() {
        handler()
    }
}
