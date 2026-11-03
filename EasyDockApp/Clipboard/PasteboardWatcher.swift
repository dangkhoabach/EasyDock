import AppKit
import EasyDockCore

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
    private static let thumbnailSide: CGFloat = 240

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var onCopy: ((Copy) -> Void)?

    func start(onCopy: @escaping (Copy) -> Void) {
        self.onCopy = onCopy
        lastChangeCount = NSPasteboard.general.changeCount
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
    }

    private func check() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        let types = (pasteboard.types ?? []).map(\.rawValue)
        // Password managers mark what they copy; it is not even read.
        guard !PasteboardMarkers.shouldSkip(types: types), let copy = Self.read(pasteboard) else { return }
        onCopy?(Copy(content: copy.content, preview: copy.preview,
                     sourceApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier))
    }

    private static func read(_ pasteboard: NSPasteboard) -> (content: ClipboardContent, preview: ClipboardPreview)? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path)
            return (ClipboardContent(filePaths: paths), ClipboardPreview(text: urls.map(\.lastPathComponent).joined(separator: ", ")))
        }
        if let image = NSImage(pasteboard: pasteboard), pasteboard.availableType(from: [.png, .tiff]) != nil,
           let png = pngData(of: image), png.count <= maxImageBytes {
            let size = image.size
            return (ClipboardContent(png: png),
                    ClipboardPreview(text: "\(Int(size.width)) × \(Int(size.height))", thumbnail: thumbnail(of: image)))
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return (ClipboardContent(text: text, rtf: pasteboard.data(forType: .rtf), html: pasteboard.data(forType: .html)),
                    ClipboardPreview(text: text))
        }
        return nil
    }

    private static func pngData(of image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func thumbnail(of image: NSImage) -> Data? {
        let scale = min(1, thumbnailSide / max(image.size.width, image.size.height, 1))
        let size = NSSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let small = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        return pngData(of: small)
    }
}
