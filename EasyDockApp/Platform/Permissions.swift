import AppKit
import ApplicationServices
import Observation
import ScreenCaptureKit

/// The two privacy grants EasyDock's features need. Both are given in System
/// Settings while EasyDock is in the background, so they are read again each
/// time the app becomes active, and every two seconds while one is missing —
/// otherwise a feature allowed from System Settings stayed off until
/// EasyDock was next brought forward.
@MainActor
@Observable
final class Permissions {
    static let shared = Permissions()

    /// Dock clicks, window switching and pasting from the clipboard history.
    private(set) var accessibility = AXIsProcessTrusted()
    /// Window thumbnails in the switcher.
    private(set) var screenRecording = CGPreflightScreenCaptureAccess()

    var allGranted: Bool { accessibility && screenRecording }

    private var poll: Timer?

    private init() {
        updatePolling()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Permissions.shared.refresh() }
        }
    }

    func refresh() {
        let accessibility = AXIsProcessTrusted(), screenRecording = CGPreflightScreenCaptureAccess()
        if accessibility != self.accessibility { self.accessibility = accessibility }
        if screenRecording != self.screenRecording { self.screenRecording = screenRecording }
        updatePolling()
    }

    private func updatePolling() {
        if allGranted {
            poll?.invalidate()
            poll = nil
        } else if poll == nil {
            poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                MainActor.assumeIsolated { Permissions.shared.refresh() }
            }
            poll?.tolerance = 1
        }
    }

    /// The prompt also adds EasyDock to the Accessibility list, where it has
    /// to be switched on; macOS shows the prompt only once, so the pane is
    /// opened as well.
    func requestAccessibility() {
        // The value of `kAXTrustedCheckOptionPrompt`, a C global that Swift 6
        // refuses to read outside a single isolation domain.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openPrivacyPane("Privacy_Accessibility")
        }
    }

    /// On macOS 27 `CGRequestScreenCaptureAccess` alone did not add EasyDock
    /// to the Screen Recording list; asking ScreenCaptureKit for the shareable
    /// content does, so the pane opens only after that call returns.
    func requestScreenRecording() {
        guard !CGRequestScreenCaptureAccess() else { return refresh() }
        Task {
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            openPrivacyPane("Privacy_ScreenCapture")
        }
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
