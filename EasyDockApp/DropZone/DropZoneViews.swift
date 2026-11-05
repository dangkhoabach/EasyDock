import AppKit
import EasyDockCore
import os
import SwiftUI

/// The shelf's window: above other windows on every desktop, without
/// making EasyDock active. Its title bar is hidden and doesn't move the
/// window, so clicks on the header reach the header (as in the menu bar
/// panel); the header's empty space moves it instead.
final class DropZonePanel: NSPanel {
    var onClose: (() -> Void)?

    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: true)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .utilityWindow

        // Drops land anywhere on the panel; the content sits inside the view that takes them.
        let target = DropTargetView(frame: NSRect(origin: .zero, size: size))
        let background = NSVisualEffectView(frame: target.bounds)
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.autoresizingMask = [.width, .height]
        let hosting = NSHostingView(rootView: DropZoneRoot())
        // No inset for the hidden title bar.
        hosting.safeAreaRegions = []
        hosting.frame = background.bounds
        hosting.autoresizingMask = [.width, .height]
        background.addSubview(hosting)
        target.addSubview(background)
        contentView = target
    }

    override var canBecomeKey: Bool { true }

    /// Esc.
    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }
}

/// Empty space that moves its window when dragged.
struct WindowMoveArea: NSViewRepresentable {
    final class MoveView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> MoveView { MoveView() }
    func updateNSView(_ view: MoveView, context: Context) {}
}

/// The panel's content view: takes drops anywhere on the panel.
final class DropTargetView: NSView {
    private static let types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .tiff, .png, .string] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Self.types)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // An item dragged off the shelf isn't taken back by it.
        guard !(sender.draggingSource is ShelfDragView) else { return [] }
        DropZoneController.shared.isTargeted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        DropZoneController.shared.isTargeted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DropZoneController.shared.isTargeted = false
        guard !(sender.draggingSource is ShelfDragView) else { return false }
        return DropZoneController.shared.accept(sender.draggingPasteboard)
    }
}

/// Drags items off the shelf. Finder copies what comes from another app and
/// moves it with Command held; a move takes the item off the shelf. Copy
/// stays allowed so browsers and mail take the file. A double-click opens
/// an item, a right-click shows its menu.
///
/// The view sits inside SwiftUI, whose own gesture recognizers higher up
/// keep plain `mouseDown` from reaching it; recognizers of its own still
/// see every click and drag.
final class ShelfDragView: NSView, NSDraggingSource {
    var items: [ShelfItem] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(dragged(_:))))
        let open = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked))
        open.numberOfClicksRequired = 2
        addGestureRecognizer(open)
        let menu = NSClickGestureRecognizer(target: self, action: #selector(rightClicked(_:)))
        menu.buttonMask = 0x2
        addGestureRecognizer(menu)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    /// The shelf belongs to an app in the background: the first click
    /// already counts instead of only bringing the panel forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func dragged(_ recognizer: NSPanGestureRecognizer) {
        guard recognizer.state == .began, !items.isEmpty, let event = NSApp.currentEvent else { return }
        let draggingItems = items.enumerated().compactMap { index, item -> NSDraggingItem? in
            let writer: NSPasteboardWriting
            let image: NSImage
            switch item {
            case .file(let path):
                writer = URL(fileURLWithPath: path) as NSURL
                image = DropZoneController.shared.thumbnails[path] ?? NSWorkspace.shared.icon(forFile: path)
            case .link(let link):
                guard let url = URL(string: link) else { return nil }
                writer = url as NSURL
                image = NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage()
            case .text(let text):
                writer = text as NSString
                image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil) ?? NSImage()
            }
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            let origin = convert(event.locationInWindow, from: nil)
            let offset = CGFloat(min(index, 4)) * 6
            draggingItem.setDraggingFrame(NSRect(x: origin.x - 24 + offset, y: origin.y - 24 - offset, width: 48, height: 48), contents: image)
            return draggingItem
        }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    @objc private func doubleClicked() {
        DropZoneController.shared.open(items)
    }

    @objc private func rightClicked(_ recognizer: NSClickGestureRecognizer) {
        guard !items.isEmpty else { return }
        DropZoneController.shared.menu(for: items).popUp(positioning: nil, at: recognizer.location(in: self), in: self)
    }

    /// The same menu for VoiceOver and other assistive apps.
    override func accessibilityPerformShowMenu() -> Bool {
        guard !items.isEmpty else { return false }
        DropZoneController.shared.menu(for: items).popUp(positioning: nil, at: NSPoint(x: bounds.midX, y: bounds.midY), in: self)
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Logger(subsystem: "com.dangkhoabach.easydock", category: "drop-zone").info("dragged \(self.items.count, privacy: .public) item(s) out, operation \(operation.rawValue, privacy: .public)")
        // Finder moves the files only after the drag ends, so the answer
        // is taken as it is rather than checked on the disk.
        if operation.contains(.move) {
            DropZoneController.shared.didMove(items)
        } else {
            DropZoneController.shared.refreshFiles()
        }
    }
}

/// A transparent `ShelfDragView` over a SwiftUI view.
private struct ShelfDragArea: NSViewRepresentable {
    let items: [ShelfItem]
    let label: String

    func makeNSView(context: Context) -> ShelfDragView {
        let view = ShelfDragView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        return view
    }

    func updateNSView(_ view: ShelfDragView, context: Context) {
        view.items = items
        view.setAccessibilityLabel(label)
    }
}

/// The in-app language for a panel that isn't part of a SwiftUI scene.
struct DropZoneRoot: View {
    @AppStorage("languagePreference") private var languageRaw = AppLocale.systemDefault.rawValue

    var body: some View {
        DropZoneView()
            .environment(\.locale, (AppLocale(rawValue: languageRaw) ?? .systemDefault).locale)
    }
}

/// The shelf: a header with a handle that drags everything, and the items.
struct DropZoneView: View {
    private let controller = DropZoneController.shared
    private let columns = [GridItem(.adaptive(minimum: 84, maximum: 96), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if controller.shelf.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(controller.shelf.items, id: \.self) { item in
                            tile(item)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(width: 320, height: 340)
        .overlay {
            if controller.isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(3)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Drop Zone", systemImage: "tray.and.arrow.down")
                .font(.headline)
            Spacer()
            if controller.shelf.items.count > 1 {
                Label("Drag All (\(controller.shelf.items.count))", systemImage: "square.stack.3d.up")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .overlay(ShelfDragArea(items: controller.shelf.items, label: String(localized: "Drag all items", bundle: AppLocale.bundle)))
                    .help("Drag everything on the shelf at once; right-click for more")
            }
            Button {
                controller.hide()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide the Drop Zone; what's on it stays")
            .accessibilityLabel(Text("Hide the Drop Zone"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(WindowMoveArea())
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop files, pictures, links or text here")
                .font(.callout.weight(.medium))
            Text("They wait here while you go to where they belong, then drag them out. Files stay where they are until you move them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tile(_ item: ShelfItem) -> some View {
        VStack(spacing: 4) {
            icon(item)
                .frame(width: 52, height: 52)
            Text(verbatim: title(item))
                .font(.caption2)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .frame(height: 86)
        .contentShape(Rectangle())
        .overlay(ShelfDragArea(items: [item], label: title(item)))
        .help(help(item))
    }

    @ViewBuilder
    private func icon(_ item: ShelfItem) -> some View {
        switch item {
        case .file(let path):
            Image(nsImage: controller.thumbnails[path] ?? NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        case .link:
            Image(systemName: "link").font(.system(size: 28)).foregroundStyle(.secondary)
        case .text:
            Image(systemName: "text.alignleft").font(.system(size: 28)).foregroundStyle(.secondary)
        }
    }

    private func title(_ item: ShelfItem) -> String {
        switch item {
        case .file(let path): FileManager.default.displayName(atPath: path)
        case .link(let link): URL(string: link)?.host() ?? link
        case .text(let text): String(text.prefix(60))
        }
    }

    private func help(_ item: ShelfItem) -> String {
        switch item {
        case .file(let path): path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        case .link(let link): link
        case .text(let text): String(text.prefix(300))
        }
    }
}
