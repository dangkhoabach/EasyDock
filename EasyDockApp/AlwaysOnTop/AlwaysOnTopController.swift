import AppKit
import ApplicationServices
import EasyDockCore
import Observation
import os

/// Always on Top: the windows the user pinned, and their live copies. A copy
/// is shown above every window whenever its window isn't the one in use, and
/// a click on it brings the window forward. It is looked at again when an
/// app comes forward, hides or shows, a window takes the focus, or the
/// desktop changes; nothing polls.
@MainActor
@Observable
final class AlwaysOnTopController {
    static let shared = AlwaysOnTopController()

    struct Pin: Identifiable {
        let windowID: CGWindowID
        let pid: pid_t
        let element: AXUIElement
        let title: String
        var id: CGWindowID { windowID }
    }

    /// Oldest first; the newest copy is drawn on top.
    private(set) var pins: [Pin] = []
    @ObservationIgnored private var mirrors: [CGWindowID: WindowMirror] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.easydock", category: "always-on-top")

    private init() {}

    /// Pinning needs both: Accessibility to find and focus the window,
    /// Screen Recording to show it.
    var hasPermissions: Bool { Permissions.shared.accessibility && Permissions.shared.screenRecording }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                     NSWorkspace.didUnhideApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { AlwaysOnTopController.shared.update() }
            }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated {
                for pin in AlwaysOnTopController.shared.pins where pin.pid == pid { AlwaysOnTopController.shared.unpin(pin.windowID) }
            }
        }
        WindowFocusHistory.shared.onRecord = { AlwaysOnTopController.shared.update() }
    }

    /// The shortcut, the panel and the right-click menu: the focused window
    /// of the app in front.
    func toggleFrontWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let element = AX.focusedWindow(of: app.processIdentifier),
              let windowID = PrivateAPIs.windowID(of: element)
        else {
            NSSound.beep()
            return
        }
        let isPinned = pins.contains { $0.windowID == windowID }
        guard isPinned || hasPermissions else {
            NSSound.beep()
            WindowPresenter.showMainWindow()
            AppNavigationState.shared.sidebarSelection = .tools
            return
        }
        switch AlwaysOnTop.toggle(windowID, in: pins.map(\.windowID)).1 {
        case .pinned:
            AXUIElementSetMessagingTimeout(element, AX.messagingTimeout)
            let title = (AX.value(element, kAXTitleAttribute) as String?).flatMap { $0.isEmpty ? nil : $0 } ?? app.localizedName ?? ""
            pins.append(Pin(windowID: windowID, pid: app.processIdentifier, element: element, title: title))
            log.info("pinned a window of \(app.bundleIdentifier ?? "?", privacy: .public)")
            update()
        case .unpinned:
            unpin(windowID)
        case .full:
            NSSound.beep()
        }
    }

    func unpin(_ windowID: CGWindowID) {
        mirrors.removeValue(forKey: windowID)?.close()
        pins.removeAll { $0.windowID == windowID }
        log.info("unpinned; \(self.pins.count) left")
    }

    // MARK: - Copies

    private func update() {
        guard !pins.isEmpty else { return }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focused = WindowFocusHistory.shared.order.first
        // The Spaces on screen now; a desktop behind a full-screen app is not.
        let shown = PrivateAPIs.displaySpaces().map { Set($0.map(\.current)) }
        let spaces = PrivateAPIs.spaces(of: pins.map(\.windowID))
        let stageManager = StageManager.shared.refresh()
        for pin in pins {
            guard Self.exists(pin.windowID), let app = NSRunningApplication(processIdentifier: pin.pid) else {
                unpin(pin.windowID)
                continue
            }
            // Unknown desktops count as shown: better a copy too many than a pinned window gone.
            let onShownDesktop = shown.map { shown in spaces?[pin.windowID].map { !shown.isDisjoint(with: $0) } ?? true } ?? true
            let showsCopy = AlwaysOnTop.showsCopy(
                windowID: pin.windowID, pid: pin.pid, frontPID: frontPID, focusedWindowID: focused,
                isHidden: app.isHidden, isMinimized: AX.isMinimized(pin.element), isOnShownDesktop: onShownDesktop
            )
            let mirror = mirror(for: pin)
            let frame = Self.frame(of: pin.element)
            if showsCopy, let frame {
                mirror.show(at: frame)
            } else {
                // In use under Stage Manager: keep streaming, so the copy has
                // the window as it was when it goes to the strip.
                let inUse = frontPID == pin.pid && focused == pin.windowID
                mirror.hide(keepingStream: stageManager && inUse, size: frame?.size)
            }
        }
    }

    private func mirror(for pin: Pin) -> WindowMirror {
        if let mirror = mirrors[pin.windowID] { return mirror }
        let windowID = pin.windowID, pid = pin.pid
        let mirror = WindowMirror(
            windowID: windowID,
            onClick: {
                WindowFocuser.focus(SwitcherItem(kind: .window(windowID), pid: pid, title: "", isOnActiveSpace: true))
            },
            onWindowGone: { AlwaysOnTopController.shared.unpin(windowID) }
        )
        mirrors[windowID] = mirror
        return mirror
    }

    private static func exists(_ windowID: CGWindowID) -> Bool {
        (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.isEmpty == false
    }

    /// From Accessibility rather than the window server, which reports the
    /// small picture in Stage Manager's strip instead of the window.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = AX.value(element, kAXPositionAttribute),
              let size: AXValue = AX.value(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &origin)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }
}
