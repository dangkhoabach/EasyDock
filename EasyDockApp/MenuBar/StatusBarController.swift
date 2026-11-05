import AppKit
import EasyDockCore
import Observation
import SwiftUI

/// The status item and everything hanging off it: a left click (or the
/// global shortcut) opens the panel, a right click opens a short menu, and
/// the icon follows the menu bar preferences and the permissions.
///
/// AppKit rather than SwiftUI's `MenuBarExtra`, which can't be opened from a
/// shortcut, has no right-click menu and doesn't say when it opens or closes.
@MainActor
final class StatusBarController: NSObject, NSWindowDelegate {
    static let shared = StatusBarController()

    private(set) var hotKeys: HotKeyManager?
    private var statusItem: NSStatusItem?
    private var panel: MenuBarPanel?
    /// When the panel last closed because it lost focus. A click on the icon
    /// while the panel is open takes the focus first and only then reaches
    /// `statusItemClicked`, which would open the panel again at once.
    private var lastClosedAt = Date.distantPast

    var isPanelOpen: Bool { panel?.isVisible == true }

    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.imagePosition = .imageLeading
        item.button?.setAccessibilityTitle("EasyDock")
        statusItem = item

        let hotKeys = HotKeyManager { [weak self] action in
            switch action {
            case .togglePanel: self?.togglePanel()
            case .clipboardPanel: ClipboardPanelController.shared.toggle()
            case .keepAwake: KeepAwakeController.shared.toggleSession()
            case .pickColor: ColorPickerController.shared.pick()
            case .pinWindow: AlwaysOnTopController.shared.toggleFrontWindow()
            case .dropZone: DropZoneController.shared.toggle()
            }
        }
        hotKeys.start()
        self.hotKeys = hotKeys

        trackIcon()
    }

    // MARK: - Panel

    func togglePanel() {
        isPanelOpen ? closePanel() : openPanel()
    }

    func openPanel() {
        guard !isPanelOpen, Date().timeIntervalSince(lastClosedAt) > 0.3,
              let button = statusItem?.button, let buttonWindow = button.window else { return }
        let panel = self.panel ?? makePanel()
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        let size = panel.frame.size
        let x = min(max(anchor.midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - size.height - 6))
        ClipboardStore.shared.refresh()
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        SystemViewModel.shared.start()
        Permissions.shared.refresh()
        StageManager.shared.refresh()
    }

    func closePanel() {
        guard isPanelOpen else { return }
        panel?.orderOut(nil)
        statusItem?.button?.highlight(false)
        SystemViewModel.shared.stop()
        lastClosedAt = Date()
    }

    private func makePanel() -> MenuBarPanel {
        let panel = MenuBarPanel(size: MenuBarPanelView.size, rootView: MenuBarPanelView())
        panel.delegate = self
        panel.onClose = { [weak self] in self?.closePanel() }
        self.panel = panel
        return panel
    }

    /// Clicking anywhere else — another app, the desktop, EasyDock's own
    /// window — takes the focus away from the panel.
    func windowDidResignKey(_ notification: Notification) {
        closePanel()
    }

    // MARK: - Status item

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            closePanel()
            showQuickMenu()
        } else {
            togglePanel()
        }
    }

    private func showQuickMenu() {
        let menu = NSMenu()
        func add(_ key: String, _ action: Selector, _ keyEquivalent: String = "") {
            let item = NSMenuItem(title: localized(key), action: action, keyEquivalent: keyEquivalent)
            item.target = self
            menu.addItem(item)
        }
        add("Pin or Unpin the Window in Front", #selector(pinWindow))
        add("Pick Color", #selector(pickColor))
        add(DropZoneController.shared.isShown ? "Hide Drop Zone" : "Show Drop Zone", #selector(toggleDropZone))
        menu.addItem(keepAwakeMenuItem())
        menu.addItem(.separator())
        add("Show EasyDock", #selector(showMainWindow))
        add("Settings…", #selector(showSettings), ",")
        add("Check for Updates…", #selector(checkForUpdates))
        menu.addItem(.separator())
        add("Quit EasyDock", #selector(quit), "q")
        // A menu set on the item opens on the next click; it's taken off
        // again so a left click keeps opening the panel.
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    /// Keep Awake with its durations, and Turn Off while a session runs.
    private func keepAwakeMenuItem() -> NSMenuItem {
        let keepAwake = KeepAwakeController.shared
        let submenu = NSMenu()
        if keepAwake.session != nil {
            let off = NSMenuItem(title: localized("Turn Off"), action: #selector(stopKeepAwake), keyEquivalent: "")
            off.target = self
            submenu.addItem(off)
            submenu.addItem(.separator())
        }
        for minutes in KeepAwakePolicy.durations {
            let item = NSMenuItem(title: localized(KeepAwakeDurationText.title(minutes)), action: #selector(startKeepAwake(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: localized("Keep Awake"), action: nil, keyEquivalent: "")
        item.state = keepAwake.isActive ? .on : .off
        item.submenu = submenu
        return item
    }

    @objc private func startKeepAwake(_ sender: NSMenuItem) { KeepAwakeController.shared.startSession(minutes: sender.tag) }
    @objc private func stopKeepAwake() { KeepAwakeController.shared.stopSession() }
    @objc private func pickColor() { ColorPickerController.shared.pick() }
    @objc private func pinWindow() { AlwaysOnTopController.shared.toggleFrontWindow() }
    @objc private func toggleDropZone() { DropZoneController.shared.toggle() }
    @objc private func showMainWindow() { WindowPresenter.showMainWindow() }
    @objc private func showSettings() { WindowPresenter.showSettings() }
    @objc private func checkForUpdates() { AppUpdater.checkForUpdates() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func localized(_ key: String) -> String {
        String(localized: String.LocalizationValue(key), bundle: AppLocale.bundle)
    }

    // MARK: - Icon

    /// Redraws the icon now and again whenever anything it read changes.
    private func trackIcon() {
        withObservationTracking {
            renderIcon()
        } onChange: { [weak self] in
            Task { @MainActor in self?.trackIcon() }
        }
    }

    private func renderIcon() {
        guard let button = statusItem?.button else { return }
        let mode = MenuBarPreferences.shared.iconMode
        let stats = MenuBarStatsViewModel.shared
        mode.needsLiveStats ? stats.start() : stats.stop()

        let glyphName = Permissions.shared.allGranted ? "dock.rectangle" : "exclamationmark.triangle"
        var glyph = NSImage(systemSymbolName: glyphName, accessibilityDescription: "EasyDock")
        if KeepAwakeController.shared.isActive { glyph = glyph.map(Self.glyphWithCup) }
        switch mode {
        case .glyph:
            button.image = glyph
            button.title = ""
        case .cpuPercent:
            button.image = glyph
            let percent = stats.cpuHistory.last.map { "\(Int($0.rounded()))%" } ?? "—"
            button.attributedTitle = NSAttributedString(
                string: " " + percent,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
            )
        case .cpuChart:
            button.image = glyph.map { Self.glyphWithChart($0, values: stats.cpuHistory) }
            button.title = ""
        }
    }

    /// The glyph followed by a cup while Keep Awake holds the Mac awake.
    private static func glyphWithCup(_ glyph: NSImage) -> NSImage {
        guard let cup = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        else { return glyph }
        let gap: CGFloat = 3
        let height = max(glyph.size.height, cup.size.height)
        let image = NSImage(size: NSSize(width: glyph.size.width + gap + cup.size.width, height: height), flipped: false) { _ in
            glyph.draw(in: NSRect(x: 0, y: (height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height))
            cup.draw(in: NSRect(x: glyph.size.width + gap, y: (height - cup.size.height) / 2, width: cup.size.width, height: cup.size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = glyph.accessibilityDescription
        return image
    }

    /// The glyph followed by a small line of recent CPU load, drawn as a
    /// template so the menu bar tints it like every other icon.
    private static func glyphWithChart(_ glyph: NSImage, values: [Double]) -> NSImage {
        let chartWidth: CGFloat = 26, gap: CGFloat = 3, height: CGFloat = 16
        let size = NSSize(width: glyph.size.width + gap + chartWidth, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            glyph.draw(in: NSRect(x: 0, y: (height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height))
            let recent = values.suffix(13)
            guard recent.count > 1 else { return true }
            let originX = glyph.size.width + gap
            let step = chartWidth / CGFloat(recent.count - 1)
            let path = NSBezierPath()
            for (index, value) in recent.enumerated() {
                let point = NSPoint(x: originX + CGFloat(index) * step,
                                    y: 2 + (height - 4) * CGFloat(min(max(value, 0), 100)) / 100)
                index == 0 ? path.move(to: point) : path.line(to: point)
            }
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
