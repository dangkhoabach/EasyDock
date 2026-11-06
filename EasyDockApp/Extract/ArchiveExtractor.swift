import Darwin
import EasyDockCore
import Foundation

/// Extracts one archive next to itself, or into a chosen folder.
///
/// 7-Zip writes into a hidden folder beside where the result goes, so
/// moving it out is a rename on the same disk, however large, and a stop
/// or a failure leaves nothing half-done behind. Before the move: links
/// that lead outside are removed, Finder's `._` files are merged back into
/// the files they belong to, and every item gets the archive's quarantine,
/// so Gatekeeper still checks an app that came inside a download.
enum ArchiveExtractor {
    struct Result {
        /// The single item or the folder that now holds the contents; nil
        /// for an archive with nothing in it.
        let item: URL?
        /// Every part of the archive, for moving them to the Trash.
        let parts: [URL]
        /// Some files failed their checksum: they are out, but damaged.
        let damaged: Bool
    }

    enum Failure: Error, Equatable {
        case sevenZip(ExtractFailure)
        /// EasyDock can't write next to the archive: ask where to put it.
        case cannotWrite
        case cancelled
    }

    /// `password` is asked only when the archive needs one; nil stops.
    static func extract(_ archive: URL, into destination: URL? = nil,
                        progress: @escaping @Sendable (Int, String?) -> Void,
                        password: @escaping @Sendable () async -> String?) async throws(Failure) -> Result {
        let folder = archive.deletingLastPathComponent()
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let volumes = ArchiveVolumes.resolve(archive.lastPathComponent, siblings: siblings)
        let first = folder.appendingPathComponent(volumes.first)
        guard FileManager.default.fileExists(atPath: first.path) else { throw .sevenZip(.missingPart(volumes.first)) }
        guard let format = ArchiveFormat.detect(header(of: first)) else { throw .sevenZip(.notAnArchive) }

        let target = destination ?? folder
        guard FileManager.default.isWritableFile(atPath: target.path) else { throw .cannotWrite }
        let temporary = target.appendingPathComponent(".EasyDock-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        } catch {
            throw .cannotWrite
        }
        // The sandbox matches real paths: /tmp is /private/tmp to it.
        let parts = volumes.parts.map { folder.appendingPathComponent($0) }
        let readable = parts.map { realPath($0.path) }
        let output = realPath(temporary.path)

        do {
            let (status, errors) = try await run(format: format, isSplit: volumes.isSplit, first: realPath(first.path),
                                                 readable: readable, output: output, progress: progress, password: password)
            let failure = SevenZip.failure(status: status, stderr: errors)
            if let failure, failure != .damaged { throw Failure.sevenZip(failure) }
            for item in SevenZip.skippedLinks(in: errors) {
                removePlaceholder(temporary.appendingPathComponent(item))
            }
            prepare(temporary, format: format, quarantine: quarantine(of: first))
            let item = try moveOut(temporary, into: target, archiveName: volumes.first)
            return Result(item: item, parts: parts, damaged: failure == .damaged)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if let failure = error as? Failure { throw failure }
            if error is CancellationError { throw .cancelled }
            throw .sevenZip(.other(error.localizedDescription))
        }
    }

    private static func run(format: ArchiveFormat, isSplit: Bool, first: String, readable: [String], output: String,
                            progress: @escaping @Sendable (Int, String?) -> Void,
                            password: @escaping @Sendable () async -> String?) async throws -> (Int32, String) {
        let threads = SevenZip.threads(physicalMemory: ProcessInfo.processInfo.physicalMemory,
                                       cores: ProcessInfo.processInfo.activeProcessorCount)
        guard format.isStream, ExtractNaming.holdsTar(first), !isSplit else {
            let type = format.sevenZipType + (isSplit ? ".split" : "")
            let process = SevenZipProcess(arguments: SevenZip.extractArguments(type: type, archive: first, output: output, threads: threads),
                                          readable: readable, writable: output)
            return try await process.run(progress: progress, password: password)
        }
        // A .tar.gz and its kin: the stream unpacked straight into tar.
        let pipe = Pipe()
        let stream = SevenZipProcess(arguments: SevenZip.streamArguments(type: format.sevenZipType, archive: first),
                                     readable: readable, writable: nil, standardOutput: pipe)
        let tar = SevenZipProcess(arguments: SevenZip.tarArguments(output: output), readable: [], writable: output, standardInput: pipe)
        async let unpacked = tar.run()
        let streamed = try await stream.run(progress: progress)
        let extracted = try await unpacked
        return streamed.status == 0 ? (extracted.status, extracted.errors) : (streamed.status, streamed.errors + extracted.errors)
    }

    // MARK: - Before the move

    /// Removes links that lead outside, merges `._` files, gives a ZIP's
    /// names back their own language, sets quarantine. On a large archive
    /// the merging and marking are the slow part, so both run on every core.
    private static func prepare(_ temporary: URL, format: ArchiveFormat, quarantine: Data?) {
        let root = realPath(temporary.path)
        var items: [String] = []
        var links: [String] = []
        var appleDoubles: [String] = []
        walk(temporary.path) { path, isLink in
            if (path as NSString).lastPathComponent.hasPrefix("._") {
                appleDoubles.append(path)
            } else if isLink {
                links.append(path)
            } else {
                items.append(path)
            }
        }
        for link in links where !linkStaysInside(URL(fileURLWithPath: link), root: root) {
            try? FileManager.default.removeItem(atPath: link)
        }
        mergeAppleDoubles(appleDoubles)
        if format == .zip, recoverNames(in: temporary.path) {
            items = []
            walk(temporary.path) { path, isLink in
                if !isLink { items.append(path) }
            }
        }
        guard let quarantine else { return }
        let paths = items
        DispatchQueue.concurrentPerform(iterations: ProcessInfo.processInfo.activeProcessorCount) { lane in
            for index in stride(from: lane, to: paths.count, by: ProcessInfo.processInfo.activeProcessorCount) {
                _ = quarantine.withUnsafeBytes { setxattr(paths[index], "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
            }
        }
    }

    /// Finder's `._name` files, which carry the attributes and resource fork
    /// of `name` on disks and in archives that can't hold them, put back
    /// onto `name` and removed, as Archive Utility does. The archive's
    /// attributes win over the ones the new file was given. A `._` file with
    /// nothing beside it goes too.
    private static func mergeAppleDoubles(_ appleDoubles: [String]) {
        DispatchQueue.concurrentPerform(iterations: appleDoubles.count) { index in
            let appleDouble = appleDoubles[index]
            let name = String((appleDouble as NSString).lastPathComponent.dropFirst(2))
            let target = ((appleDouble as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
            _ = copyfile(appleDouble, target, nil, copyfile_flags_t(COPYFILE_UNPACK | COPYFILE_XATTR | COPYFILE_NOFOLLOW))
            unlink(appleDouble)
        }
    }

    /// Names an older Windows tool stored in its own code page, which 7-Zip
    /// read as DOS Latin, renamed to what they were. Deepest first, so a
    /// folder is renamed after everything inside it. True when any was.
    private static func recoverNames(in folder: String) -> Bool {
        var paths: [String] = []
        walk(folder) { path, _ in paths.append(path) }
        guard let encoding = ZipNames.encoding(of: paths.map { ($0 as NSString).lastPathComponent },
                                               preferredLanguages: Locale.preferredLanguages) else { return false }
        var renamed = false
        for path in paths.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            guard let meant = ZipNames.recovered((path as NSString).lastPathComponent, in: encoding) else { continue }
            let target = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(meant)
            if !FileManager.default.fileExists(atPath: target), (try? FileManager.default.moveItem(atPath: path, toPath: target)) != nil {
                renamed = true
            }
        }
        return renamed
    }

    /// Every item under `folder`, links not followed, as `readdir` lists
    /// them. FileManager's listings leave out a `._name` file sitting next
    /// to `name`, exactly the files merged above.
    private static func walk(_ folder: String, _ visit: (_ path: String, _ isLink: Bool) -> Void) {
        guard let directory = opendir(folder) else { return }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
            guard name != ".", name != ".." else { continue }
            let path = folder + "/" + name
            var type = Int32(entry.pointee.d_type)
            // Some file systems don't say; ask the file itself.
            if type == DT_UNKNOWN {
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }
                type = (info.st_mode & S_IFMT) == S_IFDIR ? DT_DIR : (info.st_mode & S_IFMT) == S_IFLNK ? DT_LNK : DT_REG
            }
            visit(path, type == DT_LNK)
            if type == DT_DIR { walk(path, visit) }
        }
    }

    /// A relative link that the system itself resolves to somewhere inside
    /// `root`. Resolving it as the kernel does, not as text, also catches a
    /// link that steps out through another link (`d/y → .` with
    /// `x → d/y/../..`). Absolute links never stay: 7-Zip points them at
    /// the temporary folder, which is gone after the move. A link to nothing
    /// goes too.
    static func linkStaysInside(_ link: URL, root: String) -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), !target.hasPrefix("/"),
              let resolved = Darwin.realpath(link.path, nil) else { return false }
        defer { free(resolved) }
        let path = String(cString: resolved)
        return path == root || path.hasPrefix(root + "/")
    }

    /// Where 7-Zip refused a link it leaves an empty file of that name.
    private static func removePlaceholder(_ item: URL) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: item.path)
        if attributes?[.type] as? FileAttributeType == .typeRegular, attributes?[.size] as? UInt64 == 0 {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// One item goes next to the archive as it is; several stay together
    /// in the temporary folder, renamed after the archive.
    private static func moveOut(_ temporary: URL, into target: URL, archiveName: String) throws -> URL? {
        let contents = try FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: [.isDirectoryKey])
        let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }
        guard contents.count != 1 else {
            let item = contents[0]
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let path = ExtractNaming.uniquePath(target.appendingPathComponent(item.lastPathComponent).path, isDirectory: isDirectory, exists: exists)
            try FileManager.default.moveItem(at: item, to: URL(fileURLWithPath: path))
            try? FileManager.default.removeItem(at: temporary)
            return URL(fileURLWithPath: path)
        }
        guard !contents.isEmpty else {
            try FileManager.default.removeItem(at: temporary)
            return nil
        }
        let name = ExtractNaming.folderName(forArchive: archiveName)
        let path = ExtractNaming.uniquePath(target.appendingPathComponent(name).path, isDirectory: true, exists: exists)
        try FileManager.default.moveItem(at: temporary, to: URL(fileURLWithPath: path))
        return URL(fileURLWithPath: path)
    }

    // MARK: - Files

    private static func header(of url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: ArchiveFormat.headerLength)) ?? Data()
    }

    private static func quarantine(of url: URL) -> Data? {
        let size = getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var value = Data(count: size)
        let read = value.withUnsafeMutableBytes { getxattr(url.path, "com.apple.quarantine", $0.baseAddress, size, 0, 0) }
        return read == size ? value : nil
    }

    /// The path with every link resolved; unlike URL's own resolving, it
    /// keeps /private, which the sandbox needs.
    static func realPath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
