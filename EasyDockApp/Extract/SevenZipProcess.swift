import EasyDockCore
import Foundation
import os

/// One run of the 7-Zip helper, inside its sandbox. Reads what it prints
/// as it comes, answers its password prompt, and stops it when the task
/// running it is cancelled.
final class SevenZipProcess: @unchecked Sendable {
    /// Built from ThirdParty/7-Zip by the app target's "Build 7-Zip" phase.
    static var helper: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/7zz") }
    private static let sandboxExec = "/usr/bin/sandbox-exec"
    private static let log = Logger(subsystem: "com.dangkhoabach.easydock", category: "extract")

    private let process = Process()
    private let input = Pipe()
    private let output: Pipe?
    private let errors = Pipe()
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var errors = Data()
        var answered = 0
        var stopped = false
    }

    /// `readable`: the archive's parts, the only files it may open.
    /// `writable`: the one folder it may write to. `standardInput` and
    /// `standardOutput` connect two runs with a pipe; by default the output
    /// is read for progress.
    init(arguments: [String], readable: [String], writable: String?, standardInput: Pipe? = nil, standardOutput: Pipe? = nil) {
        let helper = Self.helper.path
        if FileManager.default.isExecutableFile(atPath: Self.sandboxExec) {
            process.executableURL = URL(fileURLWithPath: Self.sandboxExec)
            process.arguments = ["-p", SevenZip.sandboxProfile(helper: helper, readable: readable, writable: writable), helper] + arguments
        } else {
            // A later macOS without it: extracting still works, unconfined.
            Self.log.error("sandbox-exec is missing; 7-Zip runs without its sandbox")
            process.executableURL = Self.helper
            process.arguments = arguments
        }
        output = standardOutput == nil ? Pipe() : nil
        process.standardInput = standardInput ?? input
        process.standardOutput = standardOutput ?? output
        process.standardError = errors
    }

    /// Runs to the end and returns the exit status and everything printed on
    /// stderr. `progress` gets each update, read from stderr when the output
    /// is the data itself. `password` is asked when 7-Zip stops for one;
    /// nil stops it.
    func run(progress: (@Sendable (Int, String?) -> Void)? = nil,
             password: (@Sendable () async -> String?)? = nil) async throws -> (status: Int32, errors: String) {
        try await withTaskCancellationHandler {
            let finished = AsyncStream<Void>.makeStream()
            process.terminationHandler = { _ in finished.continuation.finish() }
            try process.run()
            let progressOnErrors = output == nil
            async let errorsRead: Void = read(errors.fileHandleForReading) { [self] chunk in
                let text = state.withLock { state -> String in
                    state.errors.append(chunk)
                    return String(decoding: state.errors, as: UTF8.self)
                }
                if progressOnErrors, let update = SevenZip.progress(in: String(decoding: chunk, as: UTF8.self)) {
                    progress?(update.percent, update.item)
                }
                answerPrompts(in: text, password: password)
            }
            async let outputRead: Void = read(output?.fileHandleForReading) { chunk in
                if let update = SevenZip.progress(in: String(decoding: chunk, as: UTF8.self)) {
                    progress?(update.percent, update.item)
                }
            }
            _ = await (errorsRead, outputRead)
            for await _ in finished.stream {}
            try? input.fileHandleForWriting.close()
            if Task.isCancelled || state.withLock(\.stopped) { throw CancellationError() }
            return (process.terminationStatus, state.withLock { String(decoding: $0.errors, as: UTF8.self) })
        } onCancel: {
            stop()
        }
    }

    /// 7-Zip catches SIGTERM but only looks at it between files, never while
    /// it waits for a password: closing its input ends that wait. Whatever
    /// still runs two seconds later is killed.
    func stop() {
        state.withLock { $0.stopped = true }
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Each "Enter password" not answered yet gets the password, once it is known.
    private func answerPrompts(in text: String, password: (@Sendable () async -> String?)?) {
        let asked = text.components(separatedBy: "Enter password").count - 1
        let due = state.withLock { state -> Bool in
            guard asked > state.answered else { return false }
            state.answered = asked
            return true
        }
        guard due else { return }
        Task { [self] in
            guard let password, let given = await password() else {
                stop()
                return
            }
            try? input.fileHandleForWriting.write(contentsOf: Data((given + "\n").utf8))
        }
    }

    /// Reads `handle` until 7-Zip closes it, off the main thread.
    private func read(_ handle: FileHandle?, _ chunk: @escaping @Sendable (Data) -> Void) async {
        guard let handle else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                while case let data = handle.availableData, !data.isEmpty { chunk(data) }
                done.resume()
            }
        }
    }
}
