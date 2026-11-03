import AppKit
import EasyDockCore
import Observation
import os

/// A click on the Dock icon of the app in front minimizes it, as on the
/// Windows taskbar, and the next click brings its windows back.
///
/// The event tap only listens: it never holds or swallows a click, so the
/// Dock keeps its menu on a long press, its drag to reorder, and everything
/// else, even if EasyDock were to stall.
@MainActor
final class DockClickController {
    static let shared = DockClickController()

    private struct Press {
        let time: TimeInterval
        let point: CGPoint
        let frontPID: pid_t
        var travel: Double = 0
    }

    /// Read right after mouse-down, before the Dock acts on the click.
    private struct PressState {
        let time: TimeInterval
        let app: NSRunningApplication
        let visibleWindows: [AXUIElement]
        let focusedWindow: AXUIElement?
    }

    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var press: Press?
    private var pressState: PressState?
    private let minimizer = WindowMinimizer()
    private var history: AppActivationHistory { .shared }
    /// One line per click on an app's Dock icon: what was seen and what was
    /// done. `log stream --predicate 'subsystem == "com.dangkhoabach.easydock"'`.
    private let log = Logger(subsystem: "com.dangkhoabach.easydock", category: "dock")

    func start() {
        SettingsViewModel.shared.loadIfNeeded()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { note in
            guard let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated { DockClickController.shared.minimizer.forget(pid) }
        }
        trackSettings()
    }

    // MARK: - Tap lifecycle

    /// The tap runs while the feature is on and Accessibility is allowed;
    /// both can change at any time.
    private func trackSettings() {
        withObservationTracking {
            let wanted = SettingsViewModel.shared.settings.dockClickEnabled && Permissions.shared.accessibility
            wanted ? installTap() : removeTap()
        } onChange: {
            Task { @MainActor in DockClickController.shared.trackSettings() }
        }
    }

    private func installTap() {
        guard tap == nil else { return }
        let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            .reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: mask, callback: dockTapCallback, userInfo: nil)
        else { return }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        tap = port
        tapSource = source
    }

    private func removeTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        tapSource = nil
        press = nil
    }

    // MARK: - Events

    /// Kept to bookkeeping: anything slow here delays every click on the Mac,
    /// and macOS turns a slow tap off. The Accessibility work runs on the
    /// next turn of the main loop.
    fileprivate func handle(_ type: CGEventType, at location: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            let point = location
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
            press = Press(time: now, point: point, frontPID: front)
            pressState = nil
            DispatchQueue.main.async { self.readPressState(at: point, time: now) }
        case .leftMouseDragged:
            if let press { self.press?.travel = max(press.travel, Self.distance(press.point, location)) }
        case .leftMouseUp:
            guard var finished = press else { return }
            press = nil
            finished.travel = max(finished.travel, Self.distance(finished.point, location))
            let held = now - finished.time
            DispatchQueue.main.async { self.finishClick(finished, heldSeconds: held) }
        default:
            break
        }
    }

    /// Runs well before mouse-up (a click lasts 70 ms or more); by mouse-up
    /// the Dock has sent its reopen event and the app has already restored a
    /// window on its own.
    private func readPressState(at point: CGPoint, time: TimeInterval) {
        guard let app = DockItemLocator.runningApp(at: point) else { return }
        let pid = app.processIdentifier
        pressState = PressState(time: time, app: app, visibleWindows: AX.visibleWindows(of: pid), focusedWindow: AX.focusedWindow(of: pid))
    }

    private func finishClick(_ press: Press, heldSeconds: Double) {
        guard let state = pressState, state.time == press.time else { return }
        pressState = nil
        let settings = SettingsViewModel.shared.settings
        let app = state.app
        let pid = app.processIdentifier
        let click = DockClick(
            appWasInFront: press.frontPID == pid,
            visibleWindows: state.visibleWindows.count,
            hasWindowsMinimizedByEasyDock: minimizer.hasMinimizedWindows(of: pid),
            travel: press.travel,
            heldSeconds: heldSeconds,
            isExcluded: app.bundleIdentifier.map(settings.dockClickExcludedApps.contains) ?? false
        )
        let stageManager = StageManager.shared.refresh()
        let action = DockClickDecision.decide(click, preference: settings.dockClickAction, stageManager: stageManager)
        log.info("""
            click \(app.bundleIdentifier ?? "?", privacy: .public): front=\(click.appWasInFront) visible=\(click.visibleWindows) \
            minimizedByUs=\(click.hasWindowsMinimizedByEasyDock) travel=\(click.travel, format: .fixed(precision: 1)) \
            held=\(heldSeconds, format: .fixed(precision: 2)) stageManager=\(stageManager) → \(String(describing: action), privacy: .public)
            """)
        // Every action waits for the Dock to finish with the click. On
        // mouse-up it activates the app and sends it a reopen event; an app
        // that gets the reopen after its windows went down restores one at
        // once, and the Dock's activation would undo a switch made earlier.
        // The checks found both happening when EasyDock acted straight away.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dockSettleDelay) {
            switch action {
            case .none:
                break
            case .minimizeWindows:
                // The next app comes forward only once every window is down:
                // asking a window of the clicked app to minimize again
                // brought that app back to the front.
                self.minimizer.minimize(state.visibleWindows, focused: state.focusedWindow, of: pid) {
                    self.activateNextApp(after: pid)
                }
            case .hide:
                app.hide()
            case .restoreMinimized:
                self.minimizer.restore(pid)
            }
        }
    }

    private func activateNextApp(after pid: pid_t) {
        let next = history.nextApp(excluding: pid)
        let accepted = next.map { AX.makeFrontmost($0.processIdentifier) } ?? false
        log.info("next app \(next?.bundleIdentifier ?? "none", privacy: .public) frontmost=\(accepted)")
    }

    /// How long the Dock takes to activate the clicked app and deliver its
    /// reopen event after mouse-up.
    private static let dockSettleDelay = 0.25

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }

}

/// The tap is added to the main run loop, so this runs on the main thread.
/// Only the location crosses over; the event itself is handed straight back.
private let dockTapCallback: CGEventTapCallBack = { _, type, event, _ in
    let location = event.location
    MainActor.assumeIsolated { DockClickController.shared.handle(type, at: location) }
    return Unmanaged.passUnretained(event)
}
