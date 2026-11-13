import AppKit
import ApplicationServices
import EasyDockCore

/// Reads and sets other apps' window frames through Accessibility, in
/// Accessibility coordinates.
@MainActor
enum WindowMover {
    /// The window in front: the focused window of the app in front.
    static func frontWindow() -> (app: NSRunningApplication, window: AXUIElement)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let window = AX.focusedWindow(of: app.processIdentifier),
              canMove(window)
        else { return nil }
        return (app, window)
    }

    /// The window under `point`, if EasyDock may move it.
    ///
    /// Accessibility's hit test is tried first; it is the cheaper of the two.
    /// Over a window filling the screen it can land on an element of macOS's
    /// WindowManager (Stage Manager and tiling) above the title bar instead,
    /// so the window list is asked next: the topmost ordinary window there,
    /// WindowManager's own left out.
    static func window(at point: CGPoint) -> (window: AXUIElement, pid: pid_t)? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, AX.messagingTimeout)
        var element: AXUIElement?
        if AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element) == .success, let element {
            let window: AXUIElement? = (AX.value(element, kAXRoleAttribute) as String?) == kAXWindowRole
                ? element : AX.value(element, kAXWindowAttribute)
            var pid: pid_t = 0
            if let window, AXUIElementGetPid(window, &pid) == .success, canMove(window) { return (window, pid) }
        }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in list {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let number = entry[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = (entry[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.contains(point)
            else { continue }
            if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.WindowManager" { continue }
            // The topmost window there: if it isn't one EasyDock can move,
            // the drag isn't for EasyDock.
            let windows: [AXUIElement] = AX.value(AX.application(pid), kAXWindowsAttribute) ?? []
            guard let window = windows.first(where: { PrivateAPIs.windowID(of: $0) == number }), canMove(window) else { return nil }
            return (window, pid)
        }
        return nil
    }

    /// A window, not a sheet or the desktop, not in full screen, and one the
    /// app lets others move.
    static func canMove(_ window: AXUIElement) -> Bool {
        guard (AX.value(window, kAXRoleAttribute) as String?) == kAXWindowRole,
              (AX.value(window, "AXFullScreen") as Bool?) != true,
              !AX.isMinimized(window)
        else { return false }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &settable) == .success && settable.boolValue
    }

    static func frame(of window: AXUIElement) -> CGRect? {
        guard let position: AXValue = AX.value(window, kAXPositionAttribute),
              let size: AXValue = AX.value(window, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &origin)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    /// Puts `window` at `target` and returns where it ended up.
    ///
    /// Size, position, then size again: macOS keeps a window no bigger than
    /// the screen it is on, so a window going to a larger screen only gets
    /// its full size once it is there. An app that won't go as small as
    /// asked is moved back against the target's side and onto the screen.
    @discardableResult
    static func setFrame(_ target: CGRect, of window: AXUIElement, pid: pid_t, visible: CGRect) -> CGRect? {
        let app = AX.application(pid)
        // With this on, every change is animated and a move right after a
        // resize is dropped: windows landed in the wrong place in TextEdit
        // and Edge. Setting it answers "not implemented" even when it works,
        // so the frame read back is what counts.
        let enhanced = (AX.value(app, "AXEnhancedUserInterface") as Bool?) == true
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }

        setSize(target.size, of: window)
        setPosition(target.origin, of: window)
        setSize(target.size, of: window)
        guard let placed = frame(of: window) else { return nil }
        let origin = SnapGeometry.origin(for: placed.size, target: target, visible: visible)
        guard abs(origin.x - placed.minX) > SnapGeometry.tolerance || abs(origin.y - placed.minY) > SnapGeometry.tolerance else {
            return placed
        }
        setPosition(origin, of: window)
        return frame(of: window)
    }

    private static func setSize(_ size: CGSize, of window: AXUIElement) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    private static func setPosition(_ point: CGPoint, of window: AXUIElement) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    /// Every display, the main one first, in Accessibility coordinates.
    static func screens() -> [SnapScreen] {
        let all = NSScreen.screens
        guard let mainHeight = all.first?.frame.height else { return [] }
        return all.map { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
            let id = uuid.flatMap { CFUUIDCreateString(nil, $0) as String? } ?? String(number)
            return SnapScreen(id: id,
                              frame: SnapScreens.accessibilityRect(fromAppKit: screen.frame, mainScreenHeight: mainHeight),
                              visibleFrame: SnapScreens.accessibilityRect(fromAppKit: screen.visibleFrame, mainScreenHeight: mainHeight))
        }
    }
}
