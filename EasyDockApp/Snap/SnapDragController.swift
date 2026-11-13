import AppKit
import ApplicationServices
import EasyDockCore
import os

/// Dropping a window at a screen's edge snaps it to that zone's size, with
/// a preview while it is held there; dragging a snapped window away gives
/// it back its earlier size.
///
/// The event tap only listens, like the Dock click's: it never holds or
/// changes an event. The callback copies the pointer's position and the
/// Accessibility work runs on the next turn of the main loop, so a slow app
/// can't make macOS turn the tap off.
@MainActor
final class SnapDragController {
    static let shared = SnapDragController()

    private struct Drag {
        let window: AXUIElement
        let pid: pid_t
        let windowID: CGWindowID?
        let startFrame: CGRect
        /// The frame to go back to when this drag ends snapped: the one before
        /// an earlier snap if the window was given its size back.
        var originalFrame: CGRect
        var moving = false
        var lastRead: TimeInterval = 0
        var zone: (screen: SnapScreen, target: SnapTarget, frame: CGRect)?
    }

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var pressID = 0
    private var drag: Drag?
    private var preview: SnapPreviewWindow?
    private let log = Logger(subsystem: "com.dangkhoabach.easydock", category: "snap")

    /// Window positions are read at most this often while dragging.
    private static let readInterval: TimeInterval = 1.0 / 60
    /// After the button is let go, the app finishes its own drag first: a
    /// frame set sooner was moved again by the end of the drag.
    private static let dropDelay: TimeInterval = 0.05

    func start() {
        trackSettings()
    }

    private func trackSettings() {
        withObservationTracking {
            let settings = SettingsViewModel.shared.settings
            let wanted = settings.snapEnabled && settings.snapDragEnabled && Permissions.shared.accessibility
            wanted ? installTap() : removeTap()
        } onChange: {
            Task { @MainActor in SnapDragController.shared.trackSettings() }
        }
    }

    /// Internal for the tests, which drag without turning the setting on.
    func installTap() {
        guard tap == nil else { return }
        let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: snapDragTapCallback, userInfo: nil)
        else { return }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tap = port
        tapSource = source
    }

    func removeTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        tapSource = nil
        endDrag()
    }

    // MARK: - Events

    func handle(_ type: CGEventType, at location: CGPoint) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            endDrag()
            pressID += 1
            let id = pressID
            DispatchQueue.main.async { self.beginDrag(at: location, pressID: id) }
        case .leftMouseDragged:
            let id = pressID
            DispatchQueue.main.async { if id == self.pressID { self.dragged(to: location) } }
        case .leftMouseUp:
            let id = pressID
            DispatchQueue.main.async { if id == self.pressID { self.dropped(at: location) } }
        default:
            break
        }
    }

    /// The window under the pointer, if it is one EasyDock may move. Only
    /// read once per press.
    private func beginDrag(at point: CGPoint, pressID id: Int) {
        guard id == pressID else { return }
        guard let (window, pid) = WindowMover.window(at: point),
              let app = NSRunningApplication(processIdentifier: pid), !SnapController.shared.isExcluded(app),
              let frame = WindowMover.frame(of: window)
        else { return }
        drag = Drag(window: window, pid: pid, windowID: PrivateAPIs.windowID(of: window), startFrame: frame, originalFrame: frame)
    }

    private func dragged(to point: CGPoint) {
        guard var current = drag else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - current.lastRead >= Self.readInterval else { return }
        current.lastRead = now
        if !current.moving {
            // The window itself is moving, not being resized, nor text
            // selected inside it.
            guard let frame = WindowMover.frame(of: current.window),
                  frame.origin != current.startFrame.origin, frame.size == current.startFrame.size
            else {
                drag = current
                return
            }
            current.moving = true
            if SettingsViewModel.shared.settings.snapRestoreOnDrag { giveBackSize(&current, frame: frame, pointer: point) }
        }
        current.zone = zone(at: point, for: current)
        drag = current
        if let zone = current.zone {
            showPreview(zone.frame, below: current.windowID)
        } else {
            preview?.hide()
        }
    }

    /// A window EasyDock snapped gets its earlier size back as soon as it is
    /// dragged, the pointer keeping the same place along its title bar.
    private func giveBackSize(_ current: inout Drag, frame: CGRect, pointer: CGPoint) {
        guard let id = current.windowID, let saved = SnapController.shared.snapped(id, at: current.startFrame) else { return }
        SnapController.shared.forget(id)
        let along = (pointer.x - frame.minX) / max(frame.width, 1)
        let restored = CGRect(x: (pointer.x - along * saved.original.width).rounded(), y: frame.minY,
                              width: saved.original.width, height: saved.original.height)
        let screens = WindowMover.screens()
        let visible = SnapScreens.index(containing: pointer, in: screens).map { screens[$0].frame } ?? restored
        WindowMover.setFrame(restored, of: current.window, pid: current.pid, visible: visible)
        current.originalFrame = saved.original
    }

    private func zone(at point: CGPoint, for current: Drag) -> (screen: SnapScreen, target: SnapTarget, frame: CGRect)? {
        let screens = WindowMover.screens()
        guard let index = SnapScreens.index(containing: point, in: screens) else { return nil }
        let screen = screens[index]
        let others = screens.indices.filter { $0 != index }.map { screens[$0].frame }
        guard let zone = SnapZones.zone(at: point, screen: screen.frame, otherScreens: others),
              let target = SettingsViewModel.shared.settings.snapZones[zone],
              let frame = SnapController.shared.frame(for: target, step: 0, current: current.startFrame, visible: screen.visibleFrame,
                                                      gap: Double(SettingsViewModel.shared.settings.snapGap))
        else { return nil }
        return (screen, target, frame)
    }

    /// The zone is looked at again where the button was let go: the last
    /// drag event read may be up to a sixtieth of a second older.
    private func dropped(at point: CGPoint) {
        guard let current = drag else { return }
        endDrag()
        guard current.moving, let zone = zone(at: point, for: current) else { return }
        log.info("dropped on \(zone.target.stored, privacy: .public)")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dropDelay) {
            SnapController.shared.snap(current.window, pid: current.pid, to: zone.target, cycling: false,
                                       screen: zone.screen, originalFrame: current.originalFrame)
        }
    }

    private func endDrag() {
        drag = nil
        preview?.hide()
    }

    /// Where the preview is, while it shows.
    var previewFrame: CGRect? { preview?.shownFrame }
    var previewWindowNumber: Int? { preview?.windowNumber }

    private func showPreview(_ frame: CGRect, below windowID: CGWindowID?) {
        let preview = self.preview ?? SnapPreviewWindow()
        self.preview = preview
        preview.show(frame, below: windowID)
    }
}

/// The tap is added to the main run loop, so this runs on the main thread.
/// Only the location crosses over; the event itself is handed straight back.
private let snapDragTapCallback: CGEventTapCallBack = { _, type, event, _ in
    let location = event.location
    MainActor.assumeIsolated { SnapDragController.shared.handle(type, at: location) }
    return Unmanaged.passUnretained(event)
}

/// The translucent rectangle showing where a dropped window will go, just
/// behind the window being dragged.
@MainActor
final class SnapPreviewWindow {
    private let panel: NSPanel
    private var shown: CGRect?
    var shownFrame: CGRect? { shown }
    var windowNumber: Int { panel.windowNumber }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.animationBehavior = .none
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.borderWidth = 2
        panel.contentView = view
        updateColors()
    }

    private func updateColors() {
        // The accent color, read when shown so a change in System Settings counts.
        panel.contentView?.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        panel.contentView?.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.75).cgColor
    }

    /// `frame` in Accessibility coordinates.
    func show(_ frame: CGRect, below windowID: CGWindowID?) {
        guard frame != shown else { return }
        shown = frame
        guard let mainHeight = NSScreen.screens.first?.frame.height else { return }
        updateColors()
        panel.setFrame(SnapScreens.accessibilityRect(fromAppKit: frame, mainScreenHeight: mainHeight), display: true)
        if let windowID {
            panel.order(.below, relativeTo: Int(windowID))
        } else {
            panel.orderFront(nil)
        }
    }

    func hide() {
        guard shown != nil else { return }
        shown = nil
        panel.orderOut(nil)
    }
}
