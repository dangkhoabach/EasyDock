import AppKit
import CoreMedia
import EasyDockCore
@preconcurrency import ScreenCaptureKit

/// A pinned window's live copy: a floating panel over the window's frame
/// that shows what ScreenCaptureKit streams of it. The stream runs while the
/// copy is on screen, and while the window is in use only when asked: with
/// Stage Manager on, a window moved to the strip is no longer drawn, so the
/// copy can only keep the last frame streamed before that.
@MainActor
final class WindowMirror: NSObject, SCStreamDelegate {
    let windowID: CGWindowID
    private let panel: MirrorPanel
    private let sink: FrameSink
    private var filter: SCContentFilter?
    private var stream: SCStream?
    private var isStarting = false
    private var wantsStream = false
    private var wantsVisible = false
    private var size = CGSize.zero
    /// The window is gone: its stream stopped on its own.
    private let onWindowGone: () -> Void

    init(windowID: CGWindowID, onClick: @escaping () -> Void, onWindowGone: @escaping () -> Void) {
        self.windowID = windowID
        self.onWindowGone = onWindowGone
        panel = MirrorPanel(onClick: onClick)
        sink = FrameSink(layer: panel.mirrorLayer)
        super.init()
        sink.onFirstFrame = { [weak self] in
            // Shown only once there is a picture, never as an empty pane.
            if let self, self.wantsVisible { self.panel.orderFrontRegardless() }
        }
    }

    /// `frame` as Accessibility reports it, from the top left of the main display.
    func show(at frame: CGRect) {
        let appKitFrame = AlwaysOnTop.appKitFrame(frame, mainDisplayHeight: NSScreen.screens.first?.frame.height ?? 0)
        if panel.frame != appKitFrame { panel.setFrame(appKitFrame, display: false) }
        wantsVisible = true
        if sink.hasFrame { panel.orderFrontRegardless() }
        setStreaming(true, size: frame.size)
    }

    func hide(keepingStream: Bool, size: CGSize?) {
        wantsVisible = false
        panel.orderOut(nil)
        setStreaming(keepingStream, size: size ?? self.size)
    }

    func close() {
        hide(keepingStream: false, size: nil)
        panel.close()
    }

    // MARK: - Stream

    private func setStreaming(_ on: Bool, size: CGSize) {
        wantsStream = on
        if on {
            // A window resized since the stream started gets a new one at its size.
            if stream != nil, size != self.size { stopStream() }
            self.size = size
            startStream(size: size)
        } else {
            stopStream()
        }
    }

    private func startStream(size: CGSize) {
        guard stream == nil, !isStarting else { return }
        isStarting = true
        let scale = panel.screen?.backingScaleFactor ?? 2
        Task {
            defer { isStarting = false }
            if filter == nil {
                let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let window = content?.windows.first(where: { $0.windowID == windowID }) else {
                    onWindowGone()
                    return
                }
                filter = SCContentFilter(desktopIndependentWindow: window)
            }
            guard let filter, wantsStream else { return }
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(size.width * scale))
            configuration.height = max(1, Int(size.height * scale))
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            configuration.queueDepth = 3
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            do {
                try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: FrameSink.queue)
                try await stream.startCapture()
            } catch {
                return
            }
            // No longer wanted by the time it started.
            guard wantsStream else {
                try? await stream.stopCapture()
                return
            }
            self.stream = stream
        }
    }

    private func stopStream() {
        guard let stream else { return }
        self.stream = nil
        Task { try? await stream.stopCapture() }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.stream = nil
            self.onWindowGone()
        }
    }
}

/// Puts each new frame on the layer; ScreenCaptureKit calls it on its own queue.
private final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    static let queue = DispatchQueue(label: "com.dangkhoabach.easydock.mirror")
    private let layer: CALayer
    /// Read and set on the main thread only.
    private(set) var hasFrame = false
    var onFirstFrame: (@MainActor () -> Void)?

    init(layer: CALayer) {
        self.layer = layer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Frames that only say nothing changed carry no picture.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frame = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        else { return }
        // An IOSurface is safe to hand between threads; it isn't marked Sendable.
        nonisolated(unsafe) let surface = frame
        let layer = layer
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contents = surface
            CATransaction.commit()
            if !self.hasFrame {
                self.hasFrame = true
                MainActor.assumeIsolated { self.onFirstFrame?() }
            }
        }
    }
}

/// Floats above other apps' windows without ever taking the focus; a click
/// on it brings the real window forward instead.
private final class MirrorPanel: NSPanel {
    var mirrorLayer: CALayer { mirrorView.picture.layer! }
    private let mirrorView: MirrorView

    init(onClick: @escaping () -> Void) {
        mirrorView = MirrorView(onClick: onClick)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.ignoresCycle]
        let view = mirrorView
        contentView = view

        let badge = NSImageView(image: NSImage(systemSymbolName: "pin.circle.fill", accessibilityDescription: nil) ?? NSImage())
        badge.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .controlAccentColor]))
        badge.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            badge.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
        ])
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The picture fills it; every click lands on the view itself, badge included.
private final class MirrorView: NSView {
    /// Its layer's contents are set from the stream, never drawn.
    let picture = NSView()
    private let onClick: () -> Void

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        picture.wantsLayer = true
        picture.layerContentsRedrawPolicy = .never
        picture.layer?.contentsGravity = .resize
        picture.autoresizingMask = [.width, .height]
        addSubview(picture)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }
}
