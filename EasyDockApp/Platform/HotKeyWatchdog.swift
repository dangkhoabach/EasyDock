import Foundation

/// Puts the system's ⌘Tab back when EasyDock ends, however it ends.
///
/// Turning ⌘Tab off is a window server setting that outlives the process
/// that made it: a crash or a `kill -9` would leave the Mac without an app
/// switcher until the next login. EasyDock's own executable therefore runs a
/// second time as a tiny watcher that only waits for the app to exit and
/// switches ⌘Tab back on.
enum HotKeyWatchdog {
    static let argument = "--restore-command-tab-after"

    /// The watcher's whole life, when the executable was started as one;
    /// otherwise returns at once and the app starts normally.
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1),
              let pid = pid_t(arguments[index + 1]) else { return }
        waitForExit(of: pid)
        PrivateAPIs.setSystemCommandTab(enabled: true)
        exit(0)
    }

    nonisolated(unsafe) private static var launched = false

    /// Called before ⌘Tab is first turned off; one watcher per run of the app.
    static func launchOnce() {
        guard !launched, let executable = Bundle.main.executableURL else { return }
        let watcher = Process()
        watcher.executableURL = executable
        watcher.arguments = [argument, String(ProcessInfo.processInfo.processIdentifier)]
        launched = (try? watcher.run()) != nil
    }

    /// Blocks until `pid` exits; returns at once if it already has.
    private static func waitForExit(of pid: pid_t) {
        let queue = kqueue()
        guard queue >= 0 else { return }
        defer { close(queue) }
        var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
                            fflags: NOTE_EXIT, data: 0, udata: nil)
        guard kevent(queue, &change, 1, nil, 0, nil) == 0 else { return } // ESRCH: already gone
        var event = kevent()
        while kevent(queue, nil, 0, &event, 1, nil) < 0 && errno == EINTR {}
    }
}
