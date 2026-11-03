import AppKit
import EasyDockCore
import ImageIO
import UniformTypeIdentifiers

/// Notices copies. macOS sends no notification when the clipboard changes,
/// so its change count is read twice a second — a fraction of a millisecond
/// each time.
@MainActor
final class PasteboardWatcher {
    struct Copy {
        var content: ClipboardContent
        var preview: ClipboardPreview
        var sourceApp: String?
    }

    /// Larger images are not kept.
    static let maxImageBytes = 10 * 1024 * 1024
    /// Above these the copy is not read at all: decoding happens on the main
    /// thread, and a select-all in a huge log or a giant image would freeze
    /// the app, and with it the switcher's hold on the keyboard.
    static let maxTextBytes = 1024 * 1024
    static let maxRichBytes = 4 * 1024 * 1024
    static let maxImageSourceBytes = 64 * 1024 * 1024
    static let maxImagePixels = 40_000_000
    private static let thumbnailSide = 240

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    /// Every app in front since the last check: a copy is judged by all of
    /// them, since the user can copy in a password manager and switch away
    /// before the next check.
    private var frontSinceLastCheck: Set<String> = []
    private var activationObserver: NSObjectProtocol?
    private var shouldRead: ((Set<String>) -> Bool)?
    private var onCopy: ((Copy) -> Void)?

    /// `shouldRead` gets the apps in front since the last check and decides
    /// before anything is read; `onCopy` gets what was read.
    func start(shouldRead: @escaping (Set<String>) -> Bool, onCopy: @escaping (Copy) -> Void) {
        self.shouldRead = shouldRead
        self.onCopy = onCopy
        lastChangeCount = NSPasteboard.general.changeCount
        frontSinceLastCheck = Self.frontmost.map { [$0] } ?? []
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            MainActor.assumeIsolated { _ = self.frontSinceLastCheck.insert(id) }
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { self.check() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    private static var frontmost: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    private func check() {
        let sources = frontSinceLastCheck
        frontSinceLastCheck = Self.frontmost.map { [$0] } ?? []
        let pasteboard = NSPasteboard.general
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        let types = (pasteboard.types ?? []).map(\.rawValue)
        // Password managers mark what they copy; it is not even read.
        guard !PasteboardMarkers.shouldSkip(types: types), shouldRead?(sources) == true,
              let copy = Self.read(pasteboard),
              // Read in several calls: a copy made in between is a different one.
              pasteboard.changeCount == changeCount
        else { return }
        onCopy?(Copy(content: copy.content, preview: copy.preview, sourceApp: Self.frontmost))
    }

    /// Files, then text, then an image. Text before the image: spreadsheets
    /// and office apps put a picture of the cells next to their text, and
    /// the text is what the user copied.
    private static func read(_ pasteboard: NSPasteboard) -> (content: ClipboardContent, preview: ClipboardPreview)? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path)
            return (ClipboardContent(filePaths: paths), ClipboardPreview(text: urls.map(\.lastPathComponent).joined(separator: ", ")))
        }
        if let data = pasteboard.data(forType: .string) {
            guard data.count <= maxTextBytes, let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
            let rich = { (type: NSPasteboard.PasteboardType) in pasteboard.data(forType: type).flatMap { $0.count <= maxRichBytes ? $0 : nil } }
            return (ClipboardContent(text: text, rtf: rich(.rtf), html: rich(.html)), ClipboardPreview(text: text))
        }
        if let type = pasteboard.availableType(from: [.png, .tiff]), let data = pasteboard.data(forType: type),
           data.count <= maxImageSourceBytes,
           let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           width * height <= maxImagePixels,
           let png = type == .png ? data : CGImageSourceCreateImageAtIndex(source, 0, nil).flatMap(pngData),
           png.count <= maxImageBytes {
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailSide,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary).flatMap(pngData)
            return (ClipboardContent(png: png), ClipboardPreview(text: "\(width) × \(height)", thumbnail: thumbnail))
        }
        return nil
    }

    private static func pngData(of image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
