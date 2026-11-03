import EasyDockCore
import Foundation

/// The two cleanups that only a tool can do: Xcode's simulators whose
/// runtime is gone, and Homebrew's old versions and downloads. Each is
/// offered only when its tool is installed, and both delete outright, as the
/// tools themselves do.
actor DeveloperToolsCleaner {
    struct Status: Sendable {
        /// Nil when Xcode isn't installed or `simctl` didn't answer.
        var unavailableSimulators: Int?
        var hasHomebrew = false
        /// Nil when Homebrew has nothing to remove.
        var homebrewReclaimable: String?
    }

    private static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    private var brew: String? {
        Self.brewPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func status() -> Status {
        var status = Status()
        if hasXcode, let output = Self.run("/usr/bin/xcrun", ["simctl", "list", "devices", "unavailable", "--json"]) {
            status.unavailableSimulators = DeveloperCleanup.unavailableSimulatorCount(fromJSON: Data(output.utf8))
        }
        if let brew {
            status.hasHomebrew = true
            status.homebrewReclaimable = Self.run(brew, ["cleanup", "--dry-run"]).flatMap(DeveloperCleanup.brewReclaimable)
        }
        return status
    }

    func deleteUnavailableSimulators() -> Bool {
        Self.run("/usr/bin/xcrun", ["simctl", "delete", "unavailable"]) != nil
    }

    func cleanUpHomebrew() -> Bool {
        guard let brew else { return false }
        return Self.run(brew, ["cleanup"]) != nil
    }

    /// `xcrun` without Xcode opens the installer prompt, and `simctl` installs
    /// Xcode's system components on its own when they are out of date. So it
    /// runs only when `xcode-select` names an Xcode with `simctl` whose
    /// first-launch install is done.
    private var hasXcode: Bool {
        guard let developer = Self.run("/usr/bin/xcode-select", ["-p"])?.trimmingCharacters(in: .whitespacesAndNewlines),
              FileManager.default.fileExists(atPath: developer + "/usr/bin/simctl")
        else { return false }
        return Self.run(developer + "/usr/bin/xcodebuild", ["-checkFirstLaunchStatus"]) != nil
    }

    /// Standard output, or nil when the tool failed.
    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Homebrew would otherwise update itself first, which takes a while
        // and is not what the user asked for.
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Read before waiting: a long output fills the pipe and both sides would wait.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
