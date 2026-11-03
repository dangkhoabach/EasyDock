import AppKit
import Carbon.HIToolbox
import EasyDockCore
import Observation
import os

/// What the switcher panel shows.
@MainActor
@Observable
final class SwitcherState {
    static let shared = SwitcherState()
    var items: [SwitcherItem] = []
    var selectedIndex = 0
    private init() {}
}

/// ⌘Tab (or ⌥Tab) with every window instead of one icon per app.
///
/// Holding the modifier and pressing Tab steps through the windows, most
/// recently used first; letting go of the modifier brings the selected one
/// forward. A quick press-and-release goes straight back to the previous
/// window without the panel ever showing.
@MainActor
final class SwitcherController {
    static let shared = SwitcherController()

    private let state = SwitcherState.shared
    private let log = Logger(subsystem: "com.dangkhoabach.easydock", category: "switcher")
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var selection = SwitcherSelection(count: 0)
    private var isActive = false
    private var panel: SwitcherPanel?
    /// The system's ⌘Tab is off while EasyDock's replaces it.
    private var systemCommandTabIsOff = false
    private var secureInput = false
    private var secureInputTimer: Timer?

    func start() {
        trackSettings()
        // Secure input (a password field in some apps, Terminal's secure
        // keyboard entry) keeps keys away from the tap; while it is on the
        // system's ⌘Tab has to work again.
        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { SwitcherController.shared.checkSecureInput() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SwitcherController.shared.setSystemCommandTabOff(false) }
        }
        // Under Stage Manager only the app in front can be pictured, so each
        // app's windows are pictured whenever it comes to the front, ready
        // for the next time the switcher opens.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated { SwitcherController.shared.pictureWindows(of: pid) }
        }
    }

    /// Waits for the app's windows to settle on the stage first.
    private func pictureWindows(of pid: pid_t) {
        guard settings.switcherEnabled, settings.switcherThumbnails, pid != ProcessInfo.processInfo.processIdentifier else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
            let ids = windows.compactMap { window -> CGWindowID? in
                guard (window[kCGWindowLayer as String] as? Int) == 0, (window[kCGWindowOwnerPID as String] as? pid_t) == pid else { return nil }
                return window[kCGWindowNumber as String] as? CGWindowID
            }
            ThumbnailCache.shared.refresh(ids)
        }
    }

    // MARK: - Lifecycle

    private var settings: AppSettings { SettingsViewModel.shared.settings }

    private func trackSettings() {
        withObservationTracking {
            reconcile()
        } onChange: {
            Task { @MainActor in SwitcherController.shared.trackSettings() }
        }
    }

    private func reconcile() {
        let wanted = settings.switcherEnabled && Permissions.shared.accessibility
        wanted ? installTap() : removeTap()
        setSystemCommandTabOff(wanted && settings.switcherShortcut == .commandTab && !secureInput)
    }

    private func checkSecureInput() {
        // Another process can turn the system's ⌘Tab back on behind
        // EasyDock's back (a second copy of EasyDock quitting, another
        // switcher); it is turned off again here.
        if systemCommandTabIsOff, PrivateAPIs.systemCommandTabIsOn == true {
            log.info("system ⌘Tab was turned back on elsewhere; off again")
            PrivateAPIs.setSystemCommandTab(enabled: false)
        }
        let now = IsSecureEventInputEnabled()
        guard now != secureInput else { return }
        secureInput = now
        log.info("secure input \(now ? "on: system ⌘Tab back" : "off")")
        reconcile()
    }

    private func setSystemCommandTabOff(_ off: Bool) {
        guard off != systemCommandTabIsOff, PrivateAPIs.canReplaceCommandTab else { return }
        if off { HotKeyWatchdog.launchOnce() }
        PrivateAPIs.setSystemCommandTab(enabled: !off)
        systemCommandTabIsOff = off
    }

    private func installTap() {
        guard tap == nil else { return }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: switcherTapCallback, userInfo: nil)
        else { return }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tap = port
        tapSource = source
    }

    private func removeTap() {
        guard let tap else { return }
        cancel()
        CGEvent.tapEnable(tap: tap, enable: false)
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        tapSource = nil
    }

    // MARK: - Keys

    /// Returns true when the key was the switcher's and must not reach the app in front.
    fileprivate func handle(_ type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        let modifier: CGEventFlags = settings.switcherShortcut == .commandTab ? .maskCommand : .maskAlternate
        switch type {
        case .flagsChanged:
            if isActive && !flags.contains(modifier) { commit() }
            return false
        case .keyDown:
            if keyCode == kVK_Tab && flags.contains(modifier) {
                if isActive {
                    flags.contains(.maskShift) ? selection.previous() : selection.next()
                    state.selectedIndex = selection.index
                } else {
                    begin(backwards: flags.contains(.maskShift))
                }
                return true
            }
            guard isActive else { return false }
            switch Int(keyCode) {
            case kVK_Escape: cancel()
            case kVK_Return: commit()
            case kVK_RightArrow, kVK_DownArrow: selection.next(); state.selectedIndex = selection.index
            case kVK_LeftArrow, kVK_UpArrow: selection.previous(); state.selectedIndex = selection.index
            default: return false
            }
            return true
        case .keyUp:
            return keyCode == kVK_Tab && (isActive || flags.contains(modifier))
        default:
            return false
        }
    }

    private func begin(backwards: Bool) {
        let started = Date()
        let items = WindowInventory.items()
        guard !items.isEmpty else { return }
        selection = SwitcherSelection(count: items.count)
        if backwards { selection.select(items.count - 1) }
        state.items = items
        state.selectedIndex = selection.index
        isActive = true
        log.info("switcher: \(items.count) tiles in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        if settings.switcherThumbnails {
            let windowIDs = items.compactMap { item -> CGWindowID? in
                if case .window(let id) = item.kind { return id } else { return nil }
            }
            ThumbnailCache.shared.keepOnly(Set(windowIDs))
            // Stage Manager draws the windows in its strip small and tilted,
            // and that is what a capture of them shows; only the app in front
            // is on the stage. The others keep the picture taken while they
            // were in front, or show their icon.
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let capturable = StageManager.shared.refresh()
                ? items.compactMap { item -> CGWindowID? in
                    if case .window(let id) = item.kind, item.pid == front { return id } else { return nil }
                }
                : windowIDs
            ThumbnailCache.shared.refresh(capturable)
        }
        // Shown only if the modifier is still held a moment later, so a quick
        // ⌘Tab switches without the panel flashing up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard self.isActive else { return }
            (self.panel ?? self.makePanel()).show()
        }
    }

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel { index in
            SwitcherController.shared.selection.select(index)
            SwitcherController.shared.commit()
        }
        self.panel = panel
        return panel
    }

    private func commit() {
        guard isActive else { return }
        isActive = false
        panel?.orderOut(nil)
        let item = state.items[selection.index]
        log.info("switcher: focus tile \(self.selection.index) of \(self.state.items.count)")
        WindowFocuser.focus(item)
    }

    private func cancel() {
        isActive = false
        panel?.orderOut(nil)
    }
}

/// On the main run loop, so on the main thread; only plain values cross over.
private let switcherTapCallback: CGEventTapCallBack = { _, type, event, _ in
    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let flags = event.flags
    let swallow = MainActor.assumeIsolated {
        SwitcherController.shared.handle(type, keyCode: keyCode, flags: flags)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
