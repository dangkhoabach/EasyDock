import Foundation

/// Emptying the Trash through Finder, for when macOS keeps EasyDock from
/// reading it (that takes Full Disk Access). macOS asks once whether
/// EasyDock may control Finder.
enum FinderTrash {
    /// Waits for Finder to finish. False when Finder couldn't, or the user
    /// didn't allow EasyDock to control it.
    static func empty() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "tell application id \"com.apple.finder\" to empty trash"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }

    /// System Settings › Privacy & Security › Full Disk Access.
    static let fullDiskAccessSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
