import AppKit
import ApplicationServices
import Carbon.HIToolbox
import EasyDockCore
import SwiftUI
import Testing
@testable import EasyDock

/// Every Window Snapping suite, one after the other: the drag tests wait
/// between events, and a window another test opens meanwhile could be the
/// one under the pointer.
@MainActor
@Suite(.serialized)
struct WindowSnappingAppTests {
    /// Window Snapping on windows the test makes itself, through Accessibility
    /// as for any other app's. Needs the Accessibility permission, which a CI
    /// runner doesn't have.
    @MainActor
    @Suite(.serialized, .enabled(if: AXIsProcessTrusted(), "needs the Accessibility permission"))
    struct WindowSnappingTests {
        private let pid = ProcessInfo.processInfo.processIdentifier

        private func makeWindow(minSize: NSSize? = nil) -> (NSWindow, AXUIElement)? {
            let title = "Snap test \(UUID().uuidString)"
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 300),
                                  styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
            window.title = title
            window.isReleasedWhenClosed = false
            if let minSize { window.contentMinSize = minSize }
            window.orderFront(nil)
            let element = AX.visibleWindows(of: pid).first { (AX.value($0, kAXTitleAttribute) as String?) == title }
            return element.map { (window, $0) }
        }

        private var main: SnapScreen { WindowMover.screens()[0] }

        @Test func aWindowGoesWhereItIsPut() throws {
            let (window, element) = try #require(makeWindow())
            defer { window.close() }
            let visible = main.visibleFrame
            let target = SnapGeometry.frame(for: .leftHalf, current: .zero, visible: visible, gap: 0)!
            let placed = try #require(WindowMover.setFrame(target, of: element, pid: pid, visible: visible))
            #expect(SnapGeometry.matches(placed, target))
            #expect(SnapGeometry.matches(try #require(WindowMover.frame(of: element)), target))
            // AppKit sees the same frame, turned the other way up.
            let appKit = SnapScreens.accessibilityRect(fromAppKit: window.frame, mainScreenHeight: NSScreen.screens[0].frame.height)
            #expect(SnapGeometry.matches(appKit, target))
        }

        /// The app keeps a minimum size: the window stays against the right
        /// edge and on the screen instead of hanging off it.
        @Test func aWindowThatWontShrinkStaysOnItsSide() throws {
            let (window, element) = try #require(makeWindow(minSize: NSSize(width: 700, height: 200)))
            defer { window.close() }
            let visible = main.visibleFrame
            let target = CGRect(x: visible.maxX - 300, y: visible.minY, width: 300, height: 300)
            let placed = try #require(WindowMover.setFrame(target, of: element, pid: pid, visible: visible))
            #expect(placed.width >= 700)
            #expect(abs(placed.maxX - visible.maxX) <= SnapGeometry.tolerance)
        }

        @Test func pressingAHalfAgainCyclesAndRestoreGoesBack() throws {
            let (window, element) = try #require(makeWindow())
            defer { window.close() }
            let controller = SnapController.shared
            let original = try #require(WindowMover.frame(of: element))
            let visible = main.visibleFrame
            var widths: [Double] = []
            for _ in 0..<3 {
                controller.snap(element, pid: pid, to: .action(.leftHalf), cycling: true)
                widths.append(try #require(WindowMover.frame(of: element)).width)
            }
            if SettingsViewModel.shared.settings.snapCycleSizes {
                let gap = Double(SettingsViewModel.shared.settings.snapGap)
                let expected = (0..<3).map { SnapGeometry.frame(for: .leftHalf, step: $0, current: .zero, visible: visible, gap: gap)!.width }
                #expect(zip(widths, expected).allSatisfy { abs($0 - $1) <= SnapGeometry.tolerance }, "\(widths) vs \(expected)")
            }
            // Restore goes back to where the window was before the first snap,
            // not to the previous step.
            controller.snap(element, pid: pid, to: .action(.restore), cycling: true)
            #expect(SnapGeometry.matches(try #require(WindowMover.frame(of: element)), original))
            // Nothing left to restore.
            controller.snap(element, pid: pid, to: .action(.restore), cycling: true)
            #expect(SnapGeometry.matches(try #require(WindowMover.frame(of: element)), original))
        }

        /// Moved by the user after a snap, the window's earlier frame is
        /// forgotten: Restore then has nothing to go back to.
        @Test func aWindowMovedByHandStartsAfresh() throws {
            let (window, element) = try #require(makeWindow())
            defer { window.close() }
            let controller = SnapController.shared
            controller.snap(element, pid: pid, to: .action(.maximize), cycling: true)
            let id = try #require(PrivateAPIs.windowID(of: element))
            let snapped = try #require(WindowMover.frame(of: element))
            #expect(controller.snapped(id, at: snapped) != nil)
            window.setFrame(NSRect(x: 300, y: 300, width: 500, height: 320), display: false)
            let moved = try #require(WindowMover.frame(of: element))
            #expect(controller.snapped(id, at: moved) == nil)
            controller.snap(element, pid: pid, to: .action(.rightHalf), cycling: true)
            controller.snap(element, pid: pid, to: .action(.restore), cycling: true)
            #expect(SnapGeometry.matches(try #require(WindowMover.frame(of: element)), moved))
        }

        @Test func aLayoutPutsAnAppsWindowsBackByTitle() throws {
            let (first, firstElement) = try #require(makeWindow())
            let (second, secondElement) = try #require(makeWindow())
            defer { first.close(); second.close() }
            let screens = WindowMover.screens()
            let visible = screens[0].visibleFrame
            let saved = [
                WindowLayout.Window(bundleID: "test", title: second.title, index: 0, screenID: screens[0].id,
                                    frame: UnitRect(x0: 0.5, y0: 0, x1: 1, y1: 0.5)),
                WindowLayout.Window(bundleID: "test", title: first.title, index: 1, screenID: screens[0].id,
                                    frame: UnitRect(x0: 0, y0: 0.5, x1: 0.5, y1: 1)),
            ]
            // Only this process's windows: the test's two, and maybe the app's own.
            #expect(SnapController.shared.place(saved, inAppWith: pid, screens: screens) == 2)
            #expect(SnapGeometry.matches(try #require(WindowMover.frame(of: secondElement)),
                                         WindowLayout.frame(of: saved[0].frame, in: visible)))
            #expect(SnapGeometry.matches(try #require(WindowMover.frame(of: firstElement)),
                                         WindowLayout.frame(of: saved[1].frame, in: visible)))
        }

        @Test func everyDefaultShortcutIsDifferentAndClearOfTheOthers() {
            let snap = SnapAction.allCases.compactMap(\.defaultHotKey)
            #expect(Set(snap.map { "\($0.keyCode)-\($0.carbonModifiers)" }).count == snap.count)
            for action in HotKeyAction.allCases { #expect(!snap.contains(action.defaultHotKey)) }
            #expect(snap.count == 19)
        }
    }

    /// Dragging a window to a screen's edge. The events are handed to the
    /// controller directly and the window moved as a drag would, so the pointer
    /// stays where it is.
    @MainActor
    @Suite(.serialized, .enabled(if: AXIsProcessTrusted(), "needs the Accessibility permission"))
    struct SnapDragTests {
        private let pid = ProcessInfo.processInfo.processIdentifier

        private func makeWindow() -> (NSWindow, AXUIElement)? {
            let title = "Drag test \(UUID().uuidString)"
            let window = NSWindow(contentRect: NSRect(x: 400, y: 300, width: 420, height: 300),
                                  styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
            window.title = title
            window.isReleasedWhenClosed = false
            // Above other apps' windows, so it is the one under the pointer.
            window.orderFrontRegardless()
            let element = AX.visibleWindows(of: pid).first { (AX.value($0, kAXTitleAttribute) as String?) == title }
            return element.map { (window, $0) }
        }

        private func settle(_ seconds: Double = 0.05) async throws {
            try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
        }

        /// The title bar of a window, in Accessibility coordinates. The
        /// window is brought above the others first: the app's own main
        /// window, opened a moment after launch, can land on top of it.
        private func titleBar(of element: AXUIElement) throws -> CGPoint {
            let title: String? = AX.value(element, kAXTitleAttribute)
            NSApp.windows.first { $0.title == title }?.orderFrontRegardless()
            let frame = try #require(WindowMover.frame(of: element))
            return CGPoint(x: frame.midX, y: frame.minY + 12)
        }

        /// Moves the window the way a drag does: its position only.
        private func moveWindow(_ element: AXUIElement, by dx: Double, _ dy: Double) throws {
            let frame = try #require(WindowMover.frame(of: element))
            var origin = CGPoint(x: frame.minX + dx, y: frame.minY + dy)
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &origin)!)
        }

        @Test func droppingOnTheLeftEdgeSnapsToTheLeftHalf() async throws {
            let (window, element) = try #require(makeWindow())
            defer { window.close() }
            let drag = SnapDragController.shared
            let screen = WindowMover.screens()[0]
            let start = try titleBar(of: element)

            drag.handle(.leftMouseDown, at: start)
            try await settle()
            try moveWindow(element, by: -20, 0)
            drag.handle(.leftMouseDragged, at: CGPoint(x: start.x - 20, y: start.y))
            try await settle()
            #expect(drag.previewFrame == nil)

            let edge = CGPoint(x: screen.frame.minX, y: screen.frame.midY)
            try moveWindow(element, by: edge.x - start.x + 20, 0)
            drag.handle(.leftMouseDragged, at: edge)
            try await settle()
            let gap = Double(SettingsViewModel.shared.settings.snapGap)
            let expected = SnapGeometry.frame(for: .leftHalf, current: .zero, visible: screen.visibleFrame, gap: gap)!
            if SettingsViewModel.shared.settings.snapZones[.left] == .action(.leftHalf) {
                #expect(drag.previewFrame == expected)
            }

            drag.handle(.leftMouseUp, at: edge)
            try await settle(0.2)
            #expect(drag.previewFrame == nil)
            if SettingsViewModel.shared.settings.snapZones[.left] == .action(.leftHalf) {
                #expect(SnapGeometry.matches(try #require(WindowMover.frame(of: element)), expected))
            }
        }

        /// Pulled away from the edge again before letting go, nothing happens.
        @Test func leavingTheZoneBeforeLettingGoDoesNothing() async throws {
            let (window, element) = try #require(makeWindow())
            defer { window.close() }
            let drag = SnapDragController.shared
            let screen = WindowMover.screens()[0]
            let start = try titleBar(of: element)
            drag.handle(.leftMouseDown, at: start)
            try await settle()
            try moveWindow(element, by: 0, 30)
            drag.handle(.leftMouseDragged, at: CGPoint(x: start.x, y: screen.frame.maxY - 1))
            try await settle()
            #expect(drag.previewFrame != nil || SettingsViewModel.shared.settings.snapZones[.bottomCenterThird] == nil)
            drag.handle(.leftMouseDragged, at: CGPoint(x: screen.frame.midX, y: screen.frame.midY))
            try await settle()
            #expect(drag.previewFrame == nil)
            let before = try #require(WindowMover.frame(of: element))
            drag.handle(.leftMouseUp, at: CGPoint(x: screen.frame.midX, y: screen.frame.midY))
            try await settle(0.2)
            #expect(try #require(WindowMover.frame(of: element)) == before)
        }

        /// Text selected or a window resized: the window doesn't move as a
        /// whole, so no zone shows.
        @Test func resizingIsNotDragging() async throws {
            let (window, element) = try #require(makeWindow())
            defer { window.close() }
            let drag = SnapDragController.shared
            let screen = WindowMover.screens()[0]
            let start = try titleBar(of: element)
            drag.handle(.leftMouseDown, at: start)
            try await settle()
            let frame = try #require(WindowMover.frame(of: element))
            WindowMover.setFrame(CGRect(x: frame.minX - 40, y: frame.minY, width: frame.width + 40, height: frame.height),
                                 of: element, pid: pid, visible: screen.visibleFrame)
            drag.handle(.leftMouseDragged, at: CGPoint(x: screen.frame.minX, y: screen.frame.midY))
            try await settle()
            #expect(drag.previewFrame == nil)
            drag.handle(.leftMouseUp, at: CGPoint(x: screen.frame.minX, y: screen.frame.midY))
        }

        /// A snapped window dragged away gets its earlier size back at once.
        @Test func aSnappedWindowGetsItsSizeBackWhenDraggedAway() async throws {
            guard SettingsViewModel.shared.settings.snapRestoreOnDrag else { return }
            let (window, element) = try #require(makeWindow())
            defer { window.close() }
            let original = try #require(WindowMover.frame(of: element))
            SnapController.shared.snap(element, pid: pid, to: .action(.maximize), cycling: false)
            // Accessibility has the new frame at once; the window list, which
            // finds the window under the pointer, has it once macOS has
            // finished animating the change (with Stage Manager on).
            try await settle(0.7)
            let drag = SnapDragController.shared
            let start = try titleBar(of: element)
            drag.handle(.leftMouseDown, at: start)
            try await settle()
            try moveWindow(element, by: 0, 40)
            drag.handle(.leftMouseDragged, at: CGPoint(x: start.x, y: start.y + 40))
            try await settle()
            let restored = try #require(WindowMover.frame(of: element))
            #expect(abs(restored.width - original.width) <= SnapGeometry.tolerance)
            #expect(abs(restored.height - original.height) <= SnapGeometry.tolerance)
            // The pointer is still over the window's title bar.
            #expect(restored.minX <= start.x && start.x <= restored.maxX)
            drag.handle(.leftMouseUp, at: CGPoint(x: start.x, y: start.y + 40))
        }
    }

    /// The same drag with real mouse events, which moves the pointer: run only
    /// when asked, with `TEST_RUNNER_EASYDOCK_DRIVE_POINTER=1`. It drops on the
    /// middle of the bottom edge.
    @MainActor
    @Suite(.serialized, .enabled(if: AXIsProcessTrusted() && ProcessInfo.processInfo.environment["EASYDOCK_DRIVE_POINTER"] == "1"))
    struct SnapRealDragTests {
        @Test func aRealDragToTheBottomMiddleSnapsToTheCenterThird() async throws {
            let pid = ProcessInfo.processInfo.processIdentifier
            let title = "Real drag \(UUID().uuidString)"
            let window = NSWindow(contentRect: NSRect(x: 500, y: 400, width: 420, height: 300),
                                  styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
            window.title = title
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            defer { window.close() }
            let element = try #require(AX.visibleWindows(of: pid).first { (AX.value($0, kAXTitleAttribute) as String?) == title })
            let frame = try #require(WindowMover.frame(of: element))
            let screen = WindowMover.screens()[0]
            let drag = SnapDragController.shared
            drag.installTap()
            defer {
                if !(SettingsViewModel.shared.settings.snapEnabled && SettingsViewModel.shared.settings.snapDragEnabled) { drag.removeTap() }
            }

            let source = CGEventSource(stateID: .hidSystemState)
            func post(_ type: CGEventType, _ point: CGPoint) {
                CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            let start = CGPoint(x: frame.midX, y: frame.minY + 12)
            let end = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 1)
            post(.mouseMoved, start)
            try await Task.sleep(for: .milliseconds(150))
            post(.leftMouseDown, start)
            try await Task.sleep(for: .milliseconds(100))
            // Slowly, then held still at the edge before letting go, as a
            // person does: a quick fling is macOS's, which tiles a window
            // by the speed it is thrown at (seen: to the left half).
            for i in 1...60 {
                let t = Double(i) / 60
                post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
                try await Task.sleep(for: .milliseconds(16))
            }
            for _ in 0..<6 {
                post(.leftMouseDragged, end)
                try await Task.sleep(for: .milliseconds(50))
            }
            let gap = Double(SettingsViewModel.shared.settings.snapGap)
            let expected = SnapGeometry.frame(for: .centerThird, current: .zero, visible: screen.visibleFrame, gap: gap)!
            let previewed = drag.previewFrame
            // The window order while the preview shows.
            let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap { $0[kCGWindowNumber as String] as? Int }
            post(.leftMouseUp, end)
            try await Task.sleep(for: .milliseconds(500))
            post(.mouseMoved, CGPoint(x: screen.frame.midX, y: screen.frame.midY))

            #expect(previewed == expected)
            // Behind the dragged window. macOS's own tiling overlay can sit
            // between the two.
            if let windowIndex = order.firstIndex(of: window.windowNumber),
               let previewNumber = SnapDragController.shared.previewWindowNumber,
               let previewIndex = order.firstIndex(of: previewNumber) {
                #expect(previewIndex > windowIndex)
            }
            // EasyDock put it there. With macOS's tiling on, as it is out of
            // the box, macOS then moves the window again (seen: to the left
            // half, from the bottom edge too), which is why Settings asks
            // to turn it off; only with it off is the frame still ours.
            let windowID = try #require(PrivateAPIs.windowID(of: element))
            if MacTiling.edgeDragIsOn() {
                let placed = SnapController.shared.snapped(windowID, at: expected)
                #expect(placed != nil)
            } else {
                #expect(SnapGeometry.matches(try #require(WindowMover.frame(of: element)), expected))
            }
        }
    }

    /// A real ⌃⌥← press, through Carbon, the shortcut manager and the
    /// controller, on a window of this app put in front. Run with the pointer
    /// tests, as it types.
    @MainActor
    @Suite(.serialized, .enabled(if: AXIsProcessTrusted() && ProcessInfo.processInfo.environment["EASYDOCK_DRIVE_POINTER"] == "1"))
    struct SnapShortcutTests {
        @Test func controlOptionLeftArrowPutsTheWindowInFrontOnTheLeftHalf() async throws {
            let settings = SettingsViewModel.shared.settings
            guard settings.snapEnabled, StatusBarController.shared.hotKeys?.snapHotKey("leftHalf") != nil else { return }
            let pid = ProcessInfo.processInfo.processIdentifier
            let title = "Shortcut test \(UUID().uuidString)"
            let window = NSWindow(contentRect: NSRect(x: 500, y: 400, width: 420, height: 300),
                                  styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
            window.title = title
            window.isReleasedWhenClosed = false
            defer { window.close() }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            AX.makeFrontmost(pid)
            try await Task.sleep(for: .milliseconds(400))
            #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)

            let hotKey = try #require(StatusBarController.shared.hotKeys?.snapHotKey("leftHalf"))
            let source = CGEventSource(stateID: .hidSystemState)
            let flags: CGEventFlags = [.maskControl, .maskAlternate, .maskSecondaryFn, .maskNumericPad]
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(hotKey.keyCode), keyDown: down)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
            }
            try await Task.sleep(for: .milliseconds(500))

            let element = try #require(AX.visibleWindows(of: pid).first { (AX.value($0, kAXTitleAttribute) as String?) == title })
            let screens = WindowMover.screens()
            let frame = try #require(WindowMover.frame(of: element))
            let screen = try #require(SnapScreens.index(of: frame, in: screens))
            let expected = SnapGeometry.frame(for: .leftHalf, current: .zero, visible: screens[screen].visibleFrame, gap: Double(settings.snapGap))!
            #expect(SnapGeometry.matches(frame, expected), "\(frame) vs \(expected)")
        }
    }

    /// Draws the Window Snapping tab to PNG files for a look at the layout, in
    /// light and dark, English and Vietnamese: run only when asked, with
    /// `TEST_RUNNER_EASYDOCK_RENDER_DIR=<folder>`.
    @MainActor
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["EASYDOCK_RENDER_DIR"] != nil))
    struct SnapViewRenderTests {
        @Test func renderTheTab() throws {
            let folder = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["EASYDOCK_RENDER_DIR"]))
            for (language, appearance) in [("en", NSAppearance.Name.aqua), ("vi", .darkAqua)] {
                let root = SnapView()
                    .environment(\.locale, Locale(identifier: language))
                    .frame(width: 620, height: 4600)
                let host = NSHostingView(rootView: root)
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(x: 0, y: 0, width: 620, height: 4600)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(to: folder.appendingPathComponent("snap-\(language).png"))
            }
            // The rows of a custom size, a wrong one, and a layout, which the
            // tab lists only once there are some.
            let rows = Form {
                Section("Custom Sizes") {
                    CustomSizeRow(size: CustomSnapSize(name: "Writing", x: 20, y: 0, width: 60, height: 100))
                    CustomSizeRow(size: CustomSnapSize(name: "Too wide", x: 60, y: 0, width: 60, height: 100))
                }
                Section("Layouts") {
                    LayoutRow(layout: WindowLayout(name: "Work", windows: []))
                }
            }
            .formStyle(.grouped)
            .frame(width: 620, height: 520)
            let host = NSHostingView(rootView: rows)
            host.frame = NSRect(x: 0, y: 0, width: 620, height: 520)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("snap-rows.png"))
        }
    }

    /// Window Snapping's shortcuts in the shortcut manager, kept in a defaults
    /// domain of the test's own. The combinations are ones nobody uses.
    @MainActor
    @Suite struct SnapHotKeyTests {
        private let rare = HotKey(keyCode: UInt32(kVK_F19), carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        private let other = HotKey(keyCode: UInt32(kVK_F18), carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey))

        /// Nothing is written to ~/Library/Preferences.
        private func withDefaults(_ body: (UserDefaults) -> Void) {
            body(MemoryDefaults(suiteName: "com.dangkhoabach.easydock.tests.memory")!)
        }

        @Test func aShortcutShowsWhileOffAndCanBeRemovedForGood() {
            withDefaults { defaults in
                let manager = HotKeyManager(defaults: defaults) { _ in }
                manager.setSnapKeys(["leftHalf": rare, "custom.x": nil], active: false)
                #expect(manager.snapHotKey("leftHalf") == rare)
                #expect(manager.snapHotKey("custom.x") == nil)
                #expect(manager.owner(of: rare) == .snap("leftHalf"))

                manager.setSnapKeys(["leftHalf": rare, "custom.x": nil], active: true)
                #expect(manager.snapFailed.isEmpty)
                manager.updateSnap("custom.x", to: other)
                #expect(manager.snapHotKey("custom.x") == other)
                manager.updateSnap("leftHalf", to: nil)
                #expect(manager.snapHotKey("leftHalf") == nil)
                #expect(manager.owner(of: rare) == nil)
                manager.setSnapKeys([:], active: false)

                // Read back by a new manager: removed stays removed, not the default.
                let again = HotKeyManager(defaults: defaults) { _ in }
                again.setSnapKeys(["leftHalf": rare, "custom.x": nil], active: false)
                #expect(again.snapHotKey("leftHalf") == nil)
                #expect(again.snapHotKey("custom.x") == other)
                again.forgetSnap("custom.x")
                again.setSnapKeys(["leftHalf": rare, "custom.x": nil], active: false)
                #expect(again.snapHotKey("custom.x") == nil)
            }
        }

        @Test func theFixedShortcutsCountAsTaken() {
            withDefaults { defaults in
                let manager = HotKeyManager(defaults: defaults) { _ in }
                #expect(manager.owner(of: HotKeyAction.pickColor.defaultHotKey) == .app(.pickColor))
            }
        }
    }
}

/// Defaults kept in memory, for the methods the shortcut manager uses.
private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}
