import ApplicationServices
import EasyDockCore
import Foundation

/// Every undocumented call EasyDock makes, in one place.
///
/// Each one is looked up at run time rather than linked, so if a later macOS
/// removes or renames it, the feature that needs it switches off instead of
/// the app failing to start. All of them are long-standing calls that other
/// window managers and switchers rely on as well.
enum PrivateAPIs {
    private typealias SetSymbolicHotKey = @convention(c) (Int32, Bool) -> Int32
    private typealias IsSymbolicHotKeyEnabled = @convention(c) (Int32) -> Bool
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias GetActiveSpace = @convention(c) (Int32) -> UInt64
    private typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias AXGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private typealias AXFromRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> Int32
    private typealias PostEventRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias ResponsiblePID = @convention(c) (pid_t) -> pid_t

    nonisolated(unsafe) private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        let pointer = skyLight.flatMap { dlsym($0, name) } ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) // RTLD_DEFAULT
        return pointer.map { unsafeBitCast($0, to: type) }
    }

    private static let setSymbolicHotKey = symbol("CGSSetSymbolicHotKeyEnabled", as: SetSymbolicHotKey.self)
    private static let isSymbolicHotKeyEnabled = symbol("CGSIsSymbolicHotKeyEnabled", as: IsSymbolicHotKeyEnabled.self)
    private static let mainConnection = symbol("SLSMainConnectionID", as: MainConnection.self)
    private static let copySpacesForWindows = symbol("SLSCopySpacesForWindows", as: CopySpacesForWindows.self)
    private static let getActiveSpace = symbol("SLSGetActiveSpace", as: GetActiveSpace.self)
    private static let copyManagedDisplaySpaces = symbol("SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpaces.self)
    private static let axGetWindow = symbol("_AXUIElementGetWindow", as: AXGetWindow.self)
    private static let axFromRemoteToken = symbol("_AXUIElementCreateWithRemoteToken", as: AXFromRemoteToken.self)
    private static let getProcessForPID = symbol("GetProcessForPID", as: GetProcessForPID.self)
    private static let setFrontProcess = symbol("_SLPSSetFrontProcessWithOptions", as: SetFrontProcess.self)
    private static let postEventRecord = symbol("SLPSPostEventRecordTo", as: PostEventRecord.self)
    private static let responsiblePID = symbol("responsibility_get_pid_responsible_for_pid", as: ResponsiblePID.self)

    // MARK: - Processes

    /// The process macOS holds responsible for `pid` (an app, for its
    /// helpers), which is how Activity Monitor groups them; nil without the call.
    static func responsibleProcess(of pid: pid_t) -> pid_t? {
        responsiblePID.map { $0(pid) }
    }

    // MARK: - ⌘Tab

    static var canReplaceCommandTab: Bool { setSymbolicHotKey != nil }

    /// Turns the system's ⌘Tab and ⌘⇧Tab (symbolic hotkeys 1 and 2) off or
    /// back on. The state is the window server's, for the whole login
    /// session: it outlives the process that set it, which is why
    /// `HotKeyWatchdog` exists.
    @discardableResult
    static func setSystemCommandTab(enabled: Bool) -> Bool {
        guard let setSymbolicHotKey else { return false }
        return setSymbolicHotKey(1, enabled) == 0 && setSymbolicHotKey(2, enabled) == 0
    }

    /// Whether the system's ⌘Tab is on right now; nil when that can't be read.
    static var systemCommandTabIsOn: Bool? {
        isSymbolicHotKeyEnabled.map { $0(1) }
    }

    // MARK: - Spaces

    static func activeSpace() -> UInt64? {
        guard let mainConnection, let getActiveSpace else { return nil }
        return getActiveSpace(mainConnection())
    }

    /// Each display with the Space it shows and all its Spaces, for the
    /// switcher's "current desktop" scope. Type 4 is a full-screen app's
    /// Space; 0 is a desktop.
    static func displaySpaces() -> [DisplaySpaces]? {
        guard let mainConnection, let copyManagedDisplaySpaces,
              let displays = copyManagedDisplaySpaces(mainConnection())?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        return displays.compactMap { display in
            guard let name = display["Display Identifier"] as? String,
                  let current = (display["Current Space"] as? [String: Any])?["id64"] as? NSNumber,
                  let spaces = display["Spaces"] as? [[String: Any]]
            else { return nil }
            return DisplaySpaces(
                display: name,
                current: current.uint64Value,
                spaces: spaces.compactMap { space in
                    guard let id = space["id64"] as? NSNumber else { return nil }
                    return .init(id: id.uint64Value, isFullScreen: (space["type"] as? NSNumber)?.intValue == 4)
                }
            )
        }
    }

    /// The Spaces each window is on. Real windows are on at least one; the
    /// helper windows apps keep offscreen are on none.
    static func spaces(of windowIDs: [CGWindowID]) -> [CGWindowID: [UInt64]]? {
        guard let mainConnection, let copySpacesForWindows else { return nil }
        let connection = mainConnection()
        var result: [CGWindowID: [UInt64]] = [:]
        for id in windowIDs {
            // 0x7: every kind of Space, current and others.
            let spaces = copySpacesForWindows(connection, 0x7, [NSNumber(value: id)] as CFArray)?.takeRetainedValue() as? [NSNumber]
            result[id] = spaces?.map(\.uint64Value) ?? []
        }
        return result
    }

    // MARK: - Windows

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        guard let axGetWindow, axGetWindow(element, &id) == .success else { return nil }
        return id
    }

    /// The Accessibility element of a window that `kAXWindowsAttribute`
    /// doesn't list — on another Space, or in Stage Manager's strip — found
    /// by trying the element identifiers of the app's remote token in turn.
    /// Finding one took 2.4 ms on a test window.
    static func windowElement(pid: pid_t, windowID: CGWindowID) -> AXUIElement? {
        guard let axFromRemoteToken else { return nil }
        var token = Data(count: 20)
        withUnsafeBytes(of: Int32(pid).littleEndian) { token.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: Int32(0x636f636f).littleEndian) { token.replaceSubrange(8..<12, with: $0) } // "coco"
        for elementID in UInt64(0)..<2000 {
            withUnsafeBytes(of: elementID.littleEndian) { token.replaceSubrange(12..<20, with: $0) }
            guard let element = axFromRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, AX.messagingTimeout)
            var id: CGWindowID = 0
            switch axGetWindow?(element, &id) {
            case .success where id == windowID: return element
            case .cannotComplete: return nil // the app stopped answering
            default: continue
            }
        }
        return nil
    }

    /// Brings one window of an app to the front and makes it key, the way
    /// a click on it would — including a window on another Space or in
    /// Stage Manager's strip. Returns false when the calls aren't available.
    static func focusWindow(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let getProcessForPID, let setFrontProcess, let postEventRecord else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        _ = setFrontProcess(&psn, windowID, 0x200) // user generated
        // Two event records that make the window key, the technique window
        // managers such as yabai use.
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: windowID.littleEndian) { for (i, byte) in $0.enumerated() { bytes[0x3c + i] = byte } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = postEventRecord(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = postEventRecord(&psn, &bytes)
        return true
    }
}
