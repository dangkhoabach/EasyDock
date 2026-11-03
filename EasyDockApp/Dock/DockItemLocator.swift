import AppKit
import ApplicationServices

/// Finds the app whose Dock icon is under a point, through the Dock's own
/// Accessibility tree (about 0.4 ms). Asking the Dock is what stays right
/// with magnification, auto-hide, and the Dock on any edge.
enum DockItemLocator {
    /// The running app whose icon is at `point` (global, top-left origin), or
    /// nil for anything else: another app, a folder or the Trash in the Dock,
    /// an app that isn't running.
    @MainActor
    static func runningApp(at point: CGPoint) -> NSRunningApplication? {
        guard let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, AX.messagingTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid == dockPID else { return nil }

        var element: AXUIElement? = hit
        while let current = element, (AX.value(current, kAXRoleAttribute) as String?) != "AXDockItem" {
            element = AX.value(current, kAXParentAttribute)
        }
        guard let item = element,
              (AX.value(item, kAXSubroleAttribute) as String?) == "AXApplicationDockItem",
              let url: URL = AX.value(item, kAXURLAttribute)
        else { return nil }
        let target = url.standardizedFileURL
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == target }
    }
}
