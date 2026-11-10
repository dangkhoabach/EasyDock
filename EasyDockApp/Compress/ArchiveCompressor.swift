import Darwin
import EasyDockCore
import Foundation

/// Makes one archive of some items, next to them or in a chosen folder.
///
/// 7-Zip writes into a hidden folder beside where the archive goes, so
/// moving it out is a rename on the same disk, and a stop or a failure
/// leaves nothing half-done behind. It runs in a sandbox that can read the
/// items and nothing else. Names that macOS keeps with separate accent
/// marks are made NFC inside a ZIP or 7z, as Windows and the web write them.
enum ArchiveCompressor {
    struct Options {
        var format: CompressFormat
        var level: CompressLevel
        /// Empty: no password.
        var password: String
        /// Bytes in each part; 0 doesn't split.
        var partSize: Int
    }

    struct Result {
        /// The archive, or its parts in order.
        let parts: [URL]
        /// Files 7-Zip couldn't read, left out, as paths inside the archive.
        let leftOut: [String]
    }

    enum Failure: Error, Equatable {
        case sevenZip(CompressFailure)
        /// EasyDock can't write there: ask where to put it.
        case cannotWrite
        case cancelled
    }

    /// `fileName` is the archive's name with its extension.
    static func compress(_ items: [URL], fileName: String, into destination: URL, options: Options,
                         progress: @escaping @Sendable (Int, String?) -> Void) async throws(Failure) -> Result {
        let clashes = CompressNaming.clashingNames(items.map(\.path))
        guard clashes.isEmpty else { throw .sevenZip(.clashingNames(clashes)) }
        guard FileManager.default.isWritableFile(atPath: destination.path) else { throw .cannotWrite }
        let temporary = destination.appendingPathComponent(".EasyDock-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        } catch {
            throw .cannotWrite
        }
        do {
            // The sandbox matches real paths: /tmp is /private/tmp to it. An
            // item that is itself a link stays one, so only its folder is resolved.
            let paths = items.map { realPath($0.deletingLastPathComponent().path) + "/" + $0.lastPathComponent }
            let output = realPath(temporary.path)
            let contents = survey(paths)
            let renames = options.format.canRename ? CompressNaming.nfcRenames(contents.entries) : []
            // 7-Zip can't rename inside a split archive: split it afterwards then.
            let splitsItself = renames.isEmpty
            let archive = output + "/" + fileName
            let errors = try await run(paths, archive: archive, output: output, options: options,
                                       partSize: splitsItself ? options.partSize : 0, totalBytes: contents.bytes, progress: progress)
            if !renames.isEmpty {
                try await rename(renames, in: archive, output: output, options: options)
                if options.partSize > 0 { try split(archive, every: options.partSize) }
            }
            let parts = try moveOut(temporary, fileName: fileName, format: options.format, into: destination)
            let leftOut = SevenZip.unreadableFiles(in: errors).map { CompressNaming.entry(for: $0, items: paths) }
            return Result(parts: parts, leftOut: leftOut)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let failure = error as? Failure { throw failure }
            if error is CancellationError { throw .cancelled }
            if isOutOfSpace(error) { throw .sevenZip(.noSpace) }
            throw .sevenZip(.other(error.localizedDescription))
        }
    }

    // MARK: - 7-Zip

    /// Everything 7-Zip printed on stderr, for the files it left out.
    private static func run(_ paths: [String], archive: String, output: String, options: Options, partSize: Int,
                            totalBytes: Int64, progress: @escaping @Sendable (Int, String?) -> Void) async throws -> String {
        let threads = SevenZip.compressThreads(format: options.format, physicalMemory: ProcessInfo.processInfo.physicalMemory,
                                               cores: ProcessInfo.processInfo.activeProcessorCount)
        let password = options.password
        let answer: @Sendable () async -> String? = { password }
        guard options.format.isCompressedTar else {
            let arguments = SevenZip.compressArguments(format: options.format, level: options.level, threads: threads,
                                                       encrypted: !password.isEmpty, partSize: partSize, archive: archive, items: paths)
            let process = SevenZipProcess(arguments: arguments, readable: [], readableTrees: paths, writable: output)
            let (status, errors) = try await process.run(progress: progress, password: answer)
            if let failure = SevenZip.compressFailure(status: status, stderr: errors) { throw Failure.sevenZip(failure) }
            return errors
        }
        // A .tar.gz and its kin: a tar to a pipe, compressed by the second run,
        // which says how much it has read; the tar is about as large as the files.
        let pipe = Pipe()
        let tar = SevenZipProcess(arguments: SevenZip.tarStreamArguments(items: paths), readable: [], readableTrees: paths,
                                  writable: nil, standardOutput: pipe)
        // The name a tool that keeps it gives the tar inside: "logs.tar" in "logs.tar.gz".
        let fileName = (archive as NSString).lastPathComponent
        let tarName = String(fileName.dropLast(options.format.fileExtension.count + 1)) + ".tar"
        let arguments = SevenZip.compressTarArguments(format: options.format, level: options.level, threads: threads,
                                                      tarName: tarName, partSize: partSize, archive: archive)
        let compressor = SevenZipProcess(arguments: arguments, readable: [], writable: output, standardInput: pipe)
        let total = max(totalBytes, 1)
        async let compressed = compressor.run(progress: progress, parse: { text in
            SevenZip.streamedBytes(in: text).map { (Int(min(99, $0 * 100 / total)), nil) }
        })
        let written = try await tar.run()
        let made = try await compressed
        // The compressor's own failure comes first: when it stops, the tar
        // can only fail to write to the pipe.
        if let failure = SevenZip.compressFailure(status: made.status, stderr: made.errors) { throw Failure.sevenZip(failure) }
        if let failure = SevenZip.compressFailure(status: written.status, stderr: written.errors) { throw Failure.sevenZip(failure) }
        return written.errors
    }

    /// The names made NFC, listed in a file inside the temporary folder:
    /// there can be thousands, too many for a command line.
    private static func rename(_ renames: [(from: String, to: String)], in archive: String, output: String, options: Options) async throws {
        let list = output + "/.names"
        let lines = renames.flatMap { [$0.from, $0.to] }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: URL(fileURLWithPath: list))
        defer { unlink(list) }
        let password = options.password
        let arguments = SevenZip.renameArguments(format: options.format, encrypted: !password.isEmpty, archive: archive, listFile: list)
        let (status, errors) = try await SevenZipProcess(arguments: arguments, readable: [], writable: output).run(password: { password })
        if let failure = SevenZip.compressFailure(status: status, stderr: errors) { throw Failure.sevenZip(failure) }
    }

    // MARK: - Files

    /// The bytes of the files in `paths`, as the archive will hold them.
    static func size(of paths: [String]) -> Int64 {
        survey(paths).bytes
    }

    /// What 7-Zip will put in the archive, by the same rules: the names
    /// inside it, for the NFC renames, and the bytes of its files, for the
    /// progress of a compressed tar. Links are not followed.
    private static func survey(_ paths: [String]) -> (entries: [String], bytes: Int64) {
        var entries: [String] = []
        var bytes: Int64 = 0
        func visit(_ path: String, entry: String) {
            let name = (entry as NSString).lastPathComponent
            guard !isExcluded(name) else { return }
            var info = stat()
            guard lstat(path, &info) == 0 else { return }
            entries.append(entry)
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                bytes += Int64(info.st_size)
            case S_IFDIR:
                for child in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] {
                    visit(path + "/" + child, entry: entry + "/" + child)
                }
            default:
                break
            }
        }
        for path in paths { visit(path, entry: (path as NSString).lastPathComponent) }
        return (entries, bytes)
    }

    /// `CompressNaming.excluded`, as 7-Zip's `-xr!` matches it.
    private static func isExcluded(_ name: String) -> Bool {
        CompressNaming.excluded.contains { pattern in
            pattern.hasSuffix("*") ? name.hasPrefix(pattern.dropLast()) : name == pattern
        }
    }

    /// Cuts `archive` into parts of `size` bytes, as 7-Zip's own `-v` does,
    /// and removes it. One part is the archive itself.
    private static func split(_ archive: String, every size: Int) throws {
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: archive))
        defer { try? input.close() }
        let length = try input.seekToEnd()
        guard length > UInt64(size) else { return }
        try input.seek(toOffset: 0)
        var index = 1
        while try input.offset() < length {
            let part = CompressSplit.partName(archive, index: index)
            guard FileManager.default.createFile(atPath: part, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let output = try FileHandle(forWritingTo: URL(fileURLWithPath: part))
            defer { try? output.close() }
            var left = size
            while left > 0, let chunk = try input.read(upToCount: min(left, 8 << 20)), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
                left -= chunk.count
            }
            index += 1
        }
        try FileManager.default.removeItem(atPath: archive)
    }

    /// The archive, or every part of it, out of the temporary folder under
    /// a name not taken yet; then the folder goes. A split that came out as
    /// one part is just the archive. Moved with `rename(2)`: FileManager
    /// would write the NFC name with its accents apart again.
    private static func moveOut(_ temporary: URL, fileName: String, format: CompressFormat, into destination: URL) throws -> [URL] {
        let names = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
        var parts = names.filter { $0.hasPrefix(fileName + ".") && $0.dropFirst(fileName.count + 1).allSatisfy(\.isNumber) }.sorted()
        if parts.count == 1 {
            try move(temporary.path + "/" + parts[0], to: temporary.path + "/" + fileName)
            parts = []
        }
        // A name is taken when the archive or any first part of it is there.
        let taken = { (path: String) in
            FileManager.default.fileExists(atPath: path) || FileManager.default.fileExists(atPath: CompressSplit.partName(path, index: 1))
        }
        let finalName = CompressNaming.uniqueFileName(fileName, format: format) { taken(destination.appendingPathComponent($0).path) }
        var moved: [URL] = []
        for (index, part) in (parts.isEmpty ? [fileName] : parts).enumerated() {
            let name = parts.isEmpty ? finalName : CompressSplit.partName(finalName, index: index + 1)
            try move(temporary.path + "/" + part, to: destination.path + "/" + name)
            moved.append(destination.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(at: temporary)
        return moved
    }

    private static func move(_ source: String, to target: String) throws {
        guard Darwin.rename(source, target) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func isOutOfSpace(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC))
    }

    /// The path with every link resolved; unlike URL's own resolving, it
    /// keeps /private, which the sandbox needs.
    private static func realPath(_ path: String) -> String {
        ArchiveExtractor.realPath(path)
    }
}
