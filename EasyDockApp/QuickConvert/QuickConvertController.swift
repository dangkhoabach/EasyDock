import AppKit
import EasyDockCore
import Observation
import os
import SwiftUI

/// Quick Convert: pictures to WebP, AVIF, HEIC, JPEG or PNG at a chosen
/// size, videos to MP4 or their sound to M4A. Opened from Finder's
/// right-click menu (a Services item) or from the Drop Zone, on a small
/// window that shows the choices, then each file's progress.
@MainActor
@Observable
final class QuickConvertController: NSObject, NSWindowDelegate {
    static let shared = QuickConvertController()

    enum State: Equatable {
        case waiting
        case working(Double?)
        case done(URL)
        case failed(String)
        case unsupported
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let kind: QuickConverter.Kind?
        var state: State
    }

    private(set) var items: [Item] = []
    private(set) var isRunning = false
    var hasImages: Bool { items.contains { $0.kind == .image } }
    var hasVideos: Bool { items.contains { $0.kind == .video } }
    var outputs: [URL] { items.compactMap { if case .done(let url) = $0.state { url } else { nil } } }
    /// A run went through: show the results instead of the choices.
    var isFinished: Bool {
        !isRunning && items.contains {
            switch $0.state {
            case .done, .failed: true
            default: false
            }
        }
    }

    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Results go on the Drop Zone when the files came from it.
    @ObservationIgnored private var addsToShelf = false
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.easydock", category: "quick-convert")

    private override init() {}

    /// Finder's Services item. The pasteboard holds the selected files.
    func start() {
        NSApp.servicesProvider = ServicesProvider()
        NSUpdateDynamicServices()
    }

    /// While a run is going, its window just comes forward.
    func open(_ urls: [URL], fromShelf: Bool = false) {
        if !isRunning {
            items = urls.map { url in
                let kind = QuickConverter.kind(of: url)
                return Item(url: url, kind: kind, state: kind == nil ? .unsupported : .waiting)
            }
            addsToShelf = fromShelf
        }
        let window = self.window ?? makeWindow()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: QuickConvertRoot()))
        window.styleMask = [.titled, .closable]
        window.title = String(localized: "Quick Convert", bundle: AppLocale.bundle)
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }

    // MARK: - Running

    func convert() {
        guard !isRunning else { return }
        let settings = SettingsViewModel.shared.settings
        let options = QuickConverter.ImageOptions(format: settings.convertImageFormat, maxDimension: settings.convertMaxDimension,
                                                  quality: settings.convertQuality, keepMetadata: settings.convertKeepMetadata)
        let preset = settings.convertVideoPreset
        for index in items.indices where items[index].kind != nil { items[index].state = .waiting }
        isRunning = true
        task = Task {
            await convertImages(options)
            await convertVideos(preset)
            finish()
        }
    }

    func cancel() {
        task?.cancel()
    }

    /// As many pictures at a time as the Mac has cores; each runs off the main thread.
    private func convertImages(_ options: QuickConverter.ImageOptions) async {
        var pending = items.indices.filter { items[$0].kind == .image }.makeIterator()
        await withTaskGroup(of: (Int, Result<URL, Error>).self) { group in
            for _ in 0..<max(1, ProcessInfo.processInfo.activeProcessorCount) {
                guard let index = pending.next() else { break }
                start(index, options, in: &group)
            }
            while let (index, result) = await group.next() {
                record(result, at: index)
                if !Task.isCancelled, let next = pending.next() { start(next, options, in: &group) }
            }
        }
    }

    private func start(_ index: Int, _ options: QuickConverter.ImageOptions, in group: inout TaskGroup<(Int, Result<URL, Error>)>) {
        items[index].state = .working(nil)
        let url = items[index].url
        group.addTask { (index, Result { try QuickConverter.convert(image: url, options: options) }) }
    }

    /// One video at a time: the encoder already uses the whole chip.
    private func convertVideos(_ preset: VideoPreset) async {
        for index in items.indices where items[index].kind == .video {
            guard !Task.isCancelled else { break }
            items[index].state = .working(0)
            let url = items[index].url
            let id = items[index].id
            do {
                let output = try await QuickConverter.convert(video: url, preset: preset) { fraction in
                    Task { @MainActor in QuickConvertController.shared.updateProgress(fraction, for: id) }
                }
                record(.success(output), at: index)
            } catch {
                record(.failure(error), at: index)
            }
        }
    }

    private func updateProgress(_ fraction: Double, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .working = items[index].state else { return }
        items[index].state = .working(fraction)
    }

    private func record(_ result: Result<URL, Error>, at index: Int) {
        switch result {
        case .success(let url): items[index].state = .done(url)
        case .failure(let error): items[index].state = .failed(error.localizedDescription)
        }
    }

    private func finish() {
        // A file a stop interrupted says so; the ones never started stay waiting.
        for index in items.indices {
            if case .working = items[index].state { items[index].state = .failed(QuickConverter.Failure.cancelled.localizedDescription) }
        }
        isRunning = false
        task = nil
        log.info("converted \(self.outputs.count, privacy: .public) of \(self.items.count, privacy: .public) file(s)")
        if addsToShelf, !outputs.isEmpty {
            DropZoneController.shared.add(outputs.map { .file($0.path) })
        }
    }

    func showOutputsInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
    }
}

/// The object Finder's Services menu talks to; named in Info.plist's `NSServices`.
final class ServicesProvider: NSObject {
    @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        MainActor.assumeIsolated { QuickConvertController.shared.open(urls) }
    }
}
