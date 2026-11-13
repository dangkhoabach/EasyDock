import AppKit

/// macOS's own tiling of windows dragged to the screen edges (System
/// Settings › Desktop & Dock › Windows), on unless turned off there.
enum MacTiling {
    static func edgeDragIsOn() -> Bool {
        let domain = "com.apple.WindowManager" as CFString
        CFPreferencesAppSynchronize(domain)
        func on(_ key: String) -> Bool { CFPreferencesCopyAppValue(key as CFString, domain) as? Bool ?? true }
        return on("EnableTilingByEdgeDrag") || on("EnableTopTilingByEdgeDrag")
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
