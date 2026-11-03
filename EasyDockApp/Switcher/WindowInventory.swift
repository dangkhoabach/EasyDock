import AppKit
import EasyDockCore

/// The switcher's tiles, from one window server listing (about 15 ms for
/// 140 windows). The window server, unlike Accessibility, also lists windows
/// on other Spaces and in Stage Manager's strip; the Spaces each window is
/// on tell real windows from apps' offscreen helpers.
@MainActor
enum WindowInventory {
    static func items(scope: SwitcherScope) -> [SwitcherItem] {
        let apps = AppActivationHistory.shared.appsByRecency()
        let offered = Set(apps.map(\.processIdentifier))
        let info = (CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []

        var records: [WindowRecord] = []
        for window in info where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, offered.contains(pid),
                  let id = window[kCGWindowNumber as String] as? CGWindowID else { continue }
            let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            records.append(WindowRecord(
                windowID: id,
                pid: pid,
                title: window[kCGWindowName as String] as? String ?? "",
                size: CGSize(width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0),
                spaces: []
            ))
        }

        let activeSpace: UInt64
        if let spaces = PrivateAPIs.spaces(of: records.map(\.windowID)), let active = PrivateAPIs.activeSpace() {
            for index in records.indices { records[index].spaces = spaces[records[index].windowID] ?? [] }
            activeSpace = active
        } else {
            // Without the Spaces calls: only what is on screen now, as one Space.
            let onScreen = Set(info.filter { $0[kCGWindowIsOnscreen as String] as? Bool == true }
                .compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
            for index in records.indices where onScreen.contains(records[index].windowID) { records[index].spaces = [1] }
            activeSpace = 1
        }

        // Without the displays' Spaces, the active one is the best guess.
        let shownSpaces = scope == .currentDesktop ? DesktopHistory.shownSpaces() ?? [activeSpace] : nil
        return SwitcherList.make(
            windows: records,
            activeSpace: activeSpace,
            apps: apps.map { (pid: $0.processIdentifier, name: $0.localizedName ?? "") },
            recentWindows: WindowFocusHistory.shared.order,
            shownSpaces: shownSpaces
        )
    }
}

/// The desktop each display showed last, so that from a full-screen app the
/// switcher still lists the desktop the user came from.
@MainActor
enum DesktopHistory {
    private static var lastDesktops: [String: UInt64] = [:]
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        record(PrivateAPIs.displaySpaces())
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { record(PrivateAPIs.displaySpaces()) }
        }
    }

    /// Nil when the window server doesn't say which Spaces the displays show.
    static func shownSpaces() -> Set<UInt64>? {
        guard let displays = PrivateAPIs.displaySpaces() else { return nil }
        record(displays)
        return SwitcherSpaces.shown(displays, lastDesktops: lastDesktops)
    }

    private static func record(_ displays: [DisplaySpaces]?) {
        for display in displays ?? [] where display.spaces.contains(where: { $0.id == display.current && !$0.isFullScreen }) {
            lastDesktops[display.display] = display.current
        }
    }
}

/// Brings the chosen tile's window, or app, to the front.
@MainActor
enum WindowFocuser {
    static func focus(_ item: SwitcherItem) {
        guard let app = NSRunningApplication(processIdentifier: item.pid) else { return }
        if app.isHidden { app.unhide() }
        switch item.kind {
        case .app:
            AX.makeFrontmost(item.pid)
        case .window(let windowID):
            let listed: [AXUIElement] = AX.value(AX.application(item.pid), kAXWindowsAttribute) ?? []
            let element = listed.first { PrivateAPIs.windowID(of: $0) == windowID }
                ?? PrivateAPIs.windowElement(pid: item.pid, windowID: windowID)
            if let element, AX.isMinimized(element) {
                AX.setMinimized(element, false)
            }
            // Recorded now rather than when the app's notification arrives,
            // so a quick second ⌘Tab already sees this as the latest window.
            WindowFocusHistory.shared.record(windowID)
            if !PrivateAPIs.focusWindow(pid: item.pid, windowID: windowID) {
                AX.makeFrontmost(item.pid)
            }
            // Raising the element is also what makes macOS switch to the
            // window's Space when it is on another one.
            if let element { AX.raise(element) }
        }
    }
}
