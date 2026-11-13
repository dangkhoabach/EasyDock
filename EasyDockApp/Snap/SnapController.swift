import AppKit
import Carbon.HIToolbox
import EasyDockCore
import Observation
import os

/// Window Snapping: puts the window in front on part of its screen from a
/// shortcut, a snap zone or a saved layout, and remembers where each window
/// was so it can go back.
@MainActor
@Observable
final class SnapController {
    static let shared = SnapController()

    private(set) var sizes: [CustomSnapSize] = []
    private(set) var layouts: [WindowLayout] = []

    /// Where a window was before EasyDock first moved it, where EasyDock put
    /// it last, and what put it there (to do the same on another screen).
    struct Remembered {
        var original: CGRect
        var placed: CGRect
        var target: SnapTarget?
        var step: Int
    }

    @ObservationIgnored private var memory: [CGWindowID: Remembered] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private let log = Logger(subsystem: "com.dangkhoabach.easydock", category: "snap")

    private var store: SnapStore? { AppDatabase.shared.map { SnapStore(dbQueue: $0.dbQueue) } }
    private var settings: AppSettings { SettingsViewModel.shared.settings }

    private init() {}

    /// After `StatusBarController.start()`, which makes the shortcut manager.
    func start() {
        guard !started else { return }
        started = true
        SettingsViewModel.shared.loadIfNeeded()
        sizes = (try? store?.loadSizes()) ?? []
        layouts = (try? store?.loadLayouts()) ?? []
        StatusBarController.shared.hotKeys?.onSnapPress = { key in SnapController.shared.perform(key: key) }
        trackHotKeys()
    }

    // MARK: - Shortcuts

    /// Registered while the feature is on and Accessibility is allowed: a
    /// shortcut that can't move anything shouldn't take the keys from other apps.
    private func trackHotKeys() {
        withObservationTracking {
            var keys: [String: HotKey?] = [:]
            for action in SnapAction.allCases { keys.updateValue(action.defaultHotKey, forKey: action.rawValue) }
            for size in sizes { keys.updateValue(nil, forKey: Self.key(forSize: size.id)) }
            for layout in layouts { keys.updateValue(nil, forKey: Self.key(forLayout: layout.id)) }
            StatusBarController.shared.hotKeys?.setSnapKeys(keys, active: settings.snapEnabled && Permissions.shared.accessibility)
        } onChange: {
            Task { @MainActor in SnapController.shared.trackHotKeys() }
        }
    }

    static func key(forSize id: UUID) -> String { "custom.\(id.uuidString)" }
    static func key(forLayout id: UUID) -> String { "layout.\(id.uuidString)" }

    func title(forKey key: String) -> String {
        if let action = SnapAction(rawValue: key) { return action.title }
        if let size = sizes.first(where: { Self.key(forSize: $0.id) == key }) { return size.name }
        if let layout = layouts.first(where: { Self.key(forLayout: $0.id) == key }) { return layout.name }
        return key
    }

    func perform(key: String) {
        if let action = SnapAction(rawValue: key) {
            snapFrontWindow(.action(action))
        } else if let size = sizes.first(where: { Self.key(forSize: $0.id) == key }) {
            snapFrontWindow(.custom(size.id))
        } else if let layout = layouts.first(where: { Self.key(forLayout: $0.id) == key }) {
            restore(layout)
        }
    }

    // MARK: - Snapping

    func isExcluded(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier.map(settings.snapExcludedApps.contains) ?? false
    }

    func snapFrontWindow(_ target: SnapTarget) {
        guard settings.snapEnabled, Permissions.shared.accessibility,
              let (app, window) = WindowMover.frontWindow(), !isExcluded(app)
        else { return }
        snap(window, pid: app.processIdentifier, to: target, cycling: true)
    }

    /// `cycling` is for a shortcut pressed again; a window dropped on a zone
    /// always gets the first size. A drop also names the screen under the
    /// pointer, which may not hold most of the window yet, and the frame the
    /// window had before the drag, to go back to.
    func snap(_ window: AXUIElement, pid: pid_t, to target: SnapTarget, cycling: Bool,
              screen: SnapScreen? = nil, originalFrame: CGRect? = nil) {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let current = WindowMover.frame(of: window) else { return }
        let screens = WindowMover.screens()
        guard let index = screen.flatMap({ s in screens.firstIndex { $0.id == s.id } }) ?? SnapScreens.index(of: current, in: screens)
        else { return }
        let visible = screens[index].visibleFrame
        let gap = Double(settings.snapGap)
        let windowID = PrivateAPIs.windowID(of: window)

        var appliedTarget: SnapTarget? = target
        var step = 0
        let destination: CGRect
        var destinationVisible = visible
        switch target {
        case .action(.restore):
            guard let windowID, let saved = memory.removeValue(forKey: windowID) else { return }
            let screen = SnapScreens.index(of: saved.original, in: screens).map { screens[$0].visibleFrame } ?? visible
            WindowMover.setFrame(saved.original, of: window, pid: pid, visible: screen)
            log.info("restore took \(Self.milliseconds(since: start), format: .fixed(precision: 1)) ms")
            return
        case .action(let action) where action == .nextDisplay || action == .previousDisplay:
            guard screens.count > 1 else { return }
            let next = SnapScreens.neighbor(of: index, in: screens, forward: action == .nextDisplay)
            destinationVisible = screens[next].visibleFrame
            // A snapped window is snapped the same way there, gap and all;
            // any other keeps its share of the screen.
            if let windowID, let saved = memory[windowID], SnapGeometry.matches(saved.placed, current),
               let last = saved.target, let frame = frame(for: last, step: saved.step, current: current, visible: destinationVisible, gap: gap) {
                destination = frame
                appliedTarget = last
                step = saved.step
            } else {
                destination = SnapGeometry.move(current, from: visible, to: destinationVisible)
                appliedTarget = nil
            }
        case .action(let action):
            if cycling && settings.snapCycleSizes {
                step = SnapGeometry.nextStep(for: action, current: current, visible: visible, gap: gap)
            }
            guard let frame = frame(for: target, step: step, current: current, visible: visible, gap: gap) else { return }
            destination = frame
            // Only a part of the screen is done again on another display;
            // Larger, Center or Move there would start from this one's frame.
            if SnapGeometry.unitRect(for: action) == nil { appliedTarget = nil }
        case .custom:
            guard let frame = frame(for: target, step: 0, current: current, visible: visible, gap: gap) else { return }
            destination = frame
        }
        let placed = WindowMover.setFrame(destination, of: window, pid: pid, visible: destinationVisible) ?? destination
        remember(windowID, original: originalFrame ?? current, placed: placed, target: appliedTarget, step: step)
        log.info("""
            \(target.stored, privacy: .public) took \(Self.milliseconds(since: start), format: .fixed(precision: 1)) ms, \
            placed as asked: \(SnapGeometry.matches(placed, destination))
            """)
    }

    func frame(for target: SnapTarget, step: Int, current: CGRect, visible: CGRect, gap: Double) -> CGRect? {
        switch target {
        case .action(let action):
            return SnapGeometry.frame(for: action, step: step, current: current, visible: visible, gap: gap)
        case .custom(let id):
            guard let size = sizes.first(where: { $0.id == id }) else { return nil }
            return SnapGeometry.region(size.unitRect, in: visible, gap: gap)
        }
    }

    /// The frame a window had before EasyDock first moved it is kept while
    /// EasyDock keeps moving it; once the user moves or resizes it, the
    /// next snap starts from where they left it.
    private func remember(_ windowID: CGWindowID?, original: CGRect, placed: CGRect, target: SnapTarget?, step: Int) {
        guard let windowID else { return }
        var first = original
        if let saved = memory[windowID], SnapGeometry.matches(saved.placed, original) { first = saved.original }
        memory[windowID] = Remembered(original: first, placed: placed, target: target, step: step)
        if memory.count > 200 { forgetClosedWindows() }
    }

    /// What EasyDock last did to a window, while it is still where EasyDock put it.
    func snapped(_ windowID: CGWindowID, at frame: CGRect) -> Remembered? {
        guard let saved = memory[windowID], SnapGeometry.matches(saved.placed, frame) else { return nil }
        return saved
    }

    func forget(_ windowID: CGWindowID) {
        memory[windowID] = nil
    }

    private func forgetClosedWindows() {
        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let open = Set(info.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        memory = memory.filter { open.contains($0.key) }
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    // MARK: - Custom sizes

    @discardableResult
    func addSize() -> CustomSnapSize {
        let size = CustomSnapSize(name: String(localized: "Size \(sizes.count + 1)", bundle: AppLocale.bundle),
                                  x: 10, y: 10, width: 80, height: 80)
        sizes.append(size)
        saveSizes()
        return size
    }

    /// Only a valid size is kept; the editor shows why the others aren't.
    func update(_ size: CustomSnapSize) {
        guard size.isValid, let index = sizes.firstIndex(where: { $0.id == size.id }) else { return }
        sizes[index] = size
        saveSizes()
    }

    func deleteSize(_ id: UUID) {
        sizes.removeAll { $0.id == id }
        saveSizes()
        StatusBarController.shared.hotKeys?.forgetSnap(Self.key(forSize: id))
        // The zones that used it do nothing now, rather than pointing at nothing.
        SettingsViewModel.shared.settings.snapZones = settings.snapZones.filter { $0.value != .custom(id) }
    }

    private func saveSizes() {
        do { try store?.saveSizes(sizes) } catch { log.error("sizes not saved: \(error.localizedDescription, privacy: .public)") }
    }

    // MARK: - Layouts

    /// Every standard window on screen now, of every app but EasyDock.
    /// Hidden and minimized windows are left out.
    func currentWindows() -> [WindowLayout.Window] {
        let screens = WindowMover.screens()
        var windows: [WindowLayout.Window] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isHidden && app != NSRunningApplication.current {
            guard let bundleID = app.bundleIdentifier else { continue }
            for (index, window) in AX.visibleWindows(of: app.processIdentifier).enumerated() {
                guard let frame = WindowMover.frame(of: window), let screen = SnapScreens.index(of: frame, in: screens) else { continue }
                windows.append(WindowLayout.Window(
                    bundleID: bundleID, title: AX.value(window, kAXTitleAttribute) ?? "", index: index,
                    screenID: screens[screen].id, frame: WindowLayout.unitRect(of: frame, in: screens[screen].visibleFrame)
                ))
            }
        }
        return windows
    }

    @discardableResult
    func saveLayout() -> WindowLayout? {
        let windows = currentWindows()
        guard !windows.isEmpty else { return nil }
        let layout = WindowLayout(name: String(localized: "Layout \(layouts.count + 1)", bundle: AppLocale.bundle), windows: windows)
        layouts.append(layout)
        saveLayouts()
        log.info("layout saved with \(windows.count) windows")
        return layout
    }

    /// Takes the windows on screen now in place of the saved ones.
    func replaceWindows(of id: UUID) {
        let windows = currentWindows()
        guard !windows.isEmpty, let index = layouts.firstIndex(where: { $0.id == id }) else { return }
        layouts[index].windows = windows
        saveLayouts()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = layouts.firstIndex(where: { $0.id == id }) else { return }
        layouts[index].name = trimmed
        saveLayouts()
    }

    func deleteLayout(_ id: UUID) {
        layouts.removeAll { $0.id == id }
        saveLayouts()
        StatusBarController.shared.hotKeys?.forgetSnap(Self.key(forLayout: id))
    }

    /// Puts back the windows of the apps that are open; apps that aren't
    /// are left closed, and windows the layout doesn't know stay where they are.
    func restore(_ layout: WindowLayout) {
        guard Permissions.shared.accessibility else { return }
        let start = DispatchTime.now().uptimeNanoseconds
        let screens = WindowMover.screens()
        var placed = 0
        for (bundleID, saved) in Dictionary(grouping: layout.windows, by: \.bundleID) {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { !$0.isTerminated })
            else { continue }
            placed += place(saved, inAppWith: app.processIdentifier, screens: screens)
        }
        log.info("layout restored: \(placed) of \(layout.windows.count) windows in \(Self.milliseconds(since: start), format: .fixed(precision: 0)) ms")
    }

    /// One app's saved windows put back on its open ones; returns how many.
    func place(_ saved: [WindowLayout.Window], inAppWith pid: pid_t, screens: [SnapScreen]) -> Int {
        let open = AX.visibleWindows(of: pid)
        let titles = open.map { (AX.value($0, kAXTitleAttribute) as String?) ?? "" }
        var placed = 0
        for pair in WindowLayout.match(saved: saved, openTitles: titles) {
            let window = saved[pair.saved]
            guard let screen = WindowLayout.screenIndex(for: window.screenID, in: screens) else { continue }
            let visible = screens[screen].visibleFrame
            WindowMover.setFrame(WindowLayout.frame(of: window.frame, in: visible), of: open[pair.open], pid: pid, visible: visible)
            placed += 1
        }
        return placed
    }

    private func saveLayouts() {
        do { try store?.saveLayouts(layouts) } catch { log.error("layouts not saved: \(error.localizedDescription, privacy: .public)") }
    }
}

extension SnapAction {
    var title: String {
        switch self {
        case .leftHalf: String(localized: "Left Half", bundle: AppLocale.bundle)
        case .rightHalf: String(localized: "Right Half", bundle: AppLocale.bundle)
        case .topHalf: String(localized: "Top Half", bundle: AppLocale.bundle)
        case .bottomHalf: String(localized: "Bottom Half", bundle: AppLocale.bundle)
        case .centerHalf: String(localized: "Center Half", bundle: AppLocale.bundle)
        case .topLeft: String(localized: "Top Left Quarter", bundle: AppLocale.bundle)
        case .topRight: String(localized: "Top Right Quarter", bundle: AppLocale.bundle)
        case .bottomLeft: String(localized: "Bottom Left Quarter", bundle: AppLocale.bundle)
        case .bottomRight: String(localized: "Bottom Right Quarter", bundle: AppLocale.bundle)
        case .firstThird: String(localized: "First Third", bundle: AppLocale.bundle)
        case .centerThird: String(localized: "Center Third", bundle: AppLocale.bundle)
        case .lastThird: String(localized: "Last Third", bundle: AppLocale.bundle)
        case .firstTwoThirds: String(localized: "First Two Thirds", bundle: AppLocale.bundle)
        case .lastTwoThirds: String(localized: "Last Two Thirds", bundle: AppLocale.bundle)
        case .topLeftSixth: String(localized: "Top Left Sixth", bundle: AppLocale.bundle)
        case .topCenterSixth: String(localized: "Top Center Sixth", bundle: AppLocale.bundle)
        case .topRightSixth: String(localized: "Top Right Sixth", bundle: AppLocale.bundle)
        case .bottomLeftSixth: String(localized: "Bottom Left Sixth", bundle: AppLocale.bundle)
        case .bottomCenterSixth: String(localized: "Bottom Center Sixth", bundle: AppLocale.bundle)
        case .bottomRightSixth: String(localized: "Bottom Right Sixth", bundle: AppLocale.bundle)
        case .maximize: String(localized: "Maximize", bundle: AppLocale.bundle)
        case .almostMaximize: String(localized: "Almost Maximize", bundle: AppLocale.bundle)
        case .maximizeHeight: String(localized: "Maximize Height", bundle: AppLocale.bundle)
        case .center: String(localized: "Center", bundle: AppLocale.bundle)
        case .larger: String(localized: "Make Larger", bundle: AppLocale.bundle)
        case .smaller: String(localized: "Make Smaller", bundle: AppLocale.bundle)
        case .moveLeft: String(localized: "Move to the Left Edge", bundle: AppLocale.bundle)
        case .moveRight: String(localized: "Move to the Right Edge", bundle: AppLocale.bundle)
        case .moveUp: String(localized: "Move to the Top Edge", bundle: AppLocale.bundle)
        case .moveDown: String(localized: "Move to the Bottom Edge", bundle: AppLocale.bundle)
        case .nextDisplay: String(localized: "Next Display", bundle: AppLocale.bundle)
        case .previousDisplay: String(localized: "Previous Display", bundle: AppLocale.bundle)
        case .restore: String(localized: "Restore", bundle: AppLocale.bundle)
        }
    }

    /// ⌃⌥, EasyDock's family, clear of its ⌃⌥D, A, C, T and Z. Center is ⌃⌥M:
    /// ⌃⌥Space is macOS's "next input source", which Carbon would take
    /// without saying so. The rest are left for the user to choose.
    var defaultHotKey: HotKey? {
        let controlOption = UInt32(controlKey | optionKey)
        func key(_ code: Int, _ extra: Int = 0) -> HotKey { HotKey(keyCode: UInt32(code), carbonModifiers: controlOption | UInt32(extra)) }
        switch self {
        case .leftHalf: return key(kVK_LeftArrow)
        case .rightHalf: return key(kVK_RightArrow)
        case .topHalf: return key(kVK_UpArrow)
        case .bottomHalf: return key(kVK_DownArrow)
        case .topLeft: return key(kVK_ANSI_U)
        case .topRight: return key(kVK_ANSI_I)
        case .bottomLeft: return key(kVK_ANSI_J)
        case .bottomRight: return key(kVK_ANSI_K)
        case .firstThird: return key(kVK_ANSI_1)
        case .centerThird: return key(kVK_ANSI_2)
        case .lastThird: return key(kVK_ANSI_3)
        case .firstTwoThirds: return key(kVK_ANSI_4)
        case .lastTwoThirds: return key(kVK_ANSI_5)
        case .maximize: return key(kVK_Return)
        case .almostMaximize: return key(kVK_Return, shiftKey)
        case .center: return key(kVK_ANSI_M)
        case .restore: return key(kVK_Delete)
        case .nextDisplay: return key(kVK_RightArrow, cmdKey)
        case .previousDisplay: return key(kVK_LeftArrow, cmdKey)
        default: return nil
        }
    }
}
