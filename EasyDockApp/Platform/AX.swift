import ApplicationServices

/// The few Accessibility calls EasyDock makes on other apps' windows.
enum AX {
    /// An app that doesn't answer must not stall EasyDock's main thread for
    /// the system default of six seconds.
    static let messagingTimeout: Float = 0.3

    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? T
    }

    static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return app
    }

    /// Standard windows the user can see: not minimized, not full screen.
    /// A minimized SwiftUI window reports itself as a dialog, so this is only
    /// for windows that are on screen now.
    static func visibleWindows(of pid: pid_t) -> [AXUIElement] {
        let windows: [AXUIElement] = value(application(pid), kAXWindowsAttribute) ?? []
        return windows.filter {
            (value($0, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole
                && !isMinimized($0)
                && (value($0, "AXFullScreen") as Bool?) != true
        }
    }

    static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        value(application(pid), kAXFocusedWindowAttribute)
    }

    static func isMinimized(_ window: AXUIElement) -> Bool {
        (value(window, kAXMinimizedAttribute) as Bool?) == true
    }

    static func setMinimized(_ window: AXUIElement, _ minimized: Bool) {
        // A non-optional `CFBoolean`: an optional one bridged to `CFTypeRef`
        // arrives as an opaque box, and the call then reports success while
        // the window stays as it was.
        let value: CFBoolean = minimized ? kCFBooleanTrue : kCFBooleanFalse
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, value)
    }

    /// Brings an app to the front. `NSRunningApplication.activate()` from an
    /// app in the background is refused since macOS 14 (it returned false
    /// on every Dock click); Accessibility, which EasyDock holds, is not.
    @discardableResult
    static func makeFrontmost(_ pid: pid_t) -> Bool {
        AXUIElementSetAttributeValue(application(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue) == .success
    }

    static func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
}
