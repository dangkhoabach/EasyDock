import Foundation

/// One cleanable location: a cache directory, a build-artifact folder, the
/// Trash. Describes *what* to clean — the measuring and deleting live in the
/// app target's `JunkCleanerService`, which needs AppKit to move items to
/// the Trash rather than destroying them outright.
public struct JunkTarget: Sendable, Equatable, Identifiable {
    public enum Mode: Sendable, Equatable {
        /// Empty the folder but keep the folder itself — deleting
        /// `~/Library/Caches` outright breaks apps that expect it to exist.
        case contents
        /// Delete the item itself.
        case item
        /// The cache folders of the Chromium and Electron apps inside the
        /// folder (`ChromiumCaches`), not the folder's other contents.
        case chromiumCaches
    }

    public var id: String { path }
    public let name: String
    /// Shown under the name: what this is and what losing it costs.
    public let detail: String
    public let path: String
    public let mode: Mode
    /// Skip the Trash and delete outright. Only true for the Trash itself,
    /// which obviously cannot be moved into the Trash.
    public let deletesPermanently: Bool

    public init(name: String, detail: String, path: String, mode: Mode, deletesPermanently: Bool) {
        self.name = name
        self.detail = detail
        self.path = path
        self.mode = mode
        self.deletesPermanently = deletesPermanently
    }

    /// Drops every target that lives inside another one in the same list.
    ///
    /// Several targets are nested by design — the SwiftPM, Yarn, pip and
    /// CocoaPods caches all sit under `~/Library/Caches`, which is itself a
    /// target. That costs twice:
    ///
    /// - Summing sizes counts the nested bytes once for the child and again
    ///   for the parent, so the headline figure overstates what's there.
    /// - Cleaning both empties the parent first, which takes the child with
    ///   it; the child's own pass then fails on a directory that no longer
    ///   exists, and the UI reported that as a permission problem.
    ///
    /// Applied to whatever list is in hand — the full set for the total, the
    /// user's selection for a clean — since nesting only matters between
    /// targets actually being counted or removed together.
    public static func withoutNested(_ targets: [JunkTarget]) -> [JunkTarget] {
        targets.filter { candidate in
            !targets.contains { other in
                other.path != candidate.path && candidate.path.hasPrefix(other.path + "/")
            }
        }
    }

    /// Whether this target may be cleaned by the scheduler rather than only
    /// by an explicit click.
    ///
    /// Anything that bypasses the Trash is excluded, always — an unattended
    /// run that destroys files outright leaves the user nothing to undo, and
    /// the Trash is the only reason automating this is defensible at all.
    /// Today that is exactly the Trash target itself, but the rule is written
    /// against the flag rather than the path so a future
    /// `deletesPermanently: true` entry is excluded the moment it is added,
    /// without anyone having to remember this decision.
    public var isEligibleForScheduledCleaning: Bool {
        !deletesPermanently
    }

    /// The subset of `paths` the scheduler is allowed to act on. Applied to
    /// the user's stored selection on every run — not once when they choose —
    /// so a selection saved by an older build can never widen what an
    /// unattended run touches.
    public static func scheduledCleaningTargets(
        from paths: Set<String>, available: [JunkTarget]
    ) -> [JunkTarget] {
        withoutNested(available.filter { paths.contains($0.path) && $0.isEligibleForScheduledCleaning })
    }

    /// Path with `$HOME` collapsed back to `~` for display.
    public var displayPath: String {
        let home = NSHomeDirectory()
        return home.isEmpty ? path : path.replacingOccurrences(of: home, with: "~")
    }

    /// Every location this app knows how to clean, in the order shown.
    /// `userCacheDirectory` is macOS's per-user cache folder in
    /// `/private/var/folders`, where the compiler keeps its module cache.
    ///
    /// Deliberately excludes anything whose loss isn't purely a rebuild
    /// cost: no `~/Library/Containers` app data, no Simulator *devices*
    /// (which hold real app state), no Docker volumes. Every entry here
    /// either regenerates on next use or is already garbage.
    public static func defaults(homeDirectory: String, userCacheDirectory: String? = nil) -> [JunkTarget] {
        func path(_ suffix: String) -> String { homeDirectory + "/" + suffix }
        let compilerCache = userCacheDirectory.map {
            JunkTarget(name: "Compiler module cache", detail: "Clang's prebuilt modules, rebuilt by the next build",
                       path: ($0.hasSuffix("/") ? String($0.dropLast()) : $0) + "/clang", mode: .contents, deletesPermanently: false)
        }
        return [
            JunkTarget(name: "Trash", detail: "Permanently empties ~/.Trash",
                       path: path(".Trash"), mode: .contents, deletesPermanently: true),
            JunkTarget(name: "App caches", detail: "~/Library/Caches — apps rebuild these on demand",
                       path: path("Library/Caches"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "Browser and Electron app caches", detail: "Cache folders in ~/Library/Application Support, rebuilt on demand",
                       path: path("Library/Application Support"), mode: .chromiumCaches, deletesPermanently: false),
            JunkTarget(name: "Logs", detail: "~/Library/Logs",
                       path: path("Library/Logs"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "iPhone updates", detail: "iOS installers Finder downloaded, fetched again when needed",
                       path: path("Library/iTunes/iPhone Software Updates"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "iPad updates", detail: "iPadOS installers Finder downloaded, fetched again when needed",
                       path: path("Library/iTunes/iPad Software Updates"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "Xcode DerivedData", detail: "Build cache, regenerated on the next build",
                       path: path("Library/Developer/Xcode/DerivedData"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "Xcode iOS DeviceSupport", detail: "Symbols for every iOS version this Mac has connected to",
                       path: path("Library/Developer/Xcode/iOS DeviceSupport"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "Xcode Archives", detail: "Past archives — check before deleting",
                       path: path("Library/Developer/Xcode/Archives"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "Simulator caches", detail: "~/Library/Developer/CoreSimulator/Caches",
                       path: path("Library/Developer/CoreSimulator/Caches"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "SwiftPM cache", detail: "Cloned package checkouts, re-fetched on demand",
                       path: path("Library/Caches/org.swift.swiftpm"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "NuGet packages", detail: "~/.nuget/packages — restored by the next build",
                       path: path(".nuget/packages"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "npm cache", detail: "~/.npm/_cacache",
                       path: path(".npm/_cacache"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "Yarn cache", detail: "~/Library/Caches/Yarn",
                       path: path("Library/Caches/Yarn"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "pnpm store", detail: "~/Library/pnpm/store",
                       path: path("Library/pnpm/store"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "pip cache", detail: "~/Library/Caches/pip",
                       path: path("Library/Caches/pip"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "Gradle cache", detail: "~/.gradle/caches",
                       path: path(".gradle/caches"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "CocoaPods cache", detail: "~/Library/Caches/CocoaPods",
                       path: path("Library/Caches/CocoaPods"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "Homebrew cache", detail: "Downloaded bottles, re-fetched on demand",
                       path: path("Library/Caches/Homebrew"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "Cargo registry", detail: "~/.cargo/registry — crates downloaded again by the next build",
                       path: path(".cargo/registry"), mode: .contents, deletesPermanently: false),
            JunkTarget(name: "Command-line tool caches", detail: "~/.cache — tools download these again when needed",
                       path: path(".cache"), mode: .contents, deletesPermanently: false),
        ] + [compilerCache].compactMap { $0 }
    }
}

/// The caches Chromium and the apps built on it (Electron apps, Chromium
/// browsers) keep next to their data in Application Support, rather than
/// in `~/Library/Caches`.
public enum ChromiumCaches {
    /// Folders they rebuild on their own. Cache Storage and service worker
    /// scripts are left: sites keep offline data there.
    public static let names: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "GraphiteDawnCache",
        "GrShaderCache", "ShaderCache", "GPUPersistentCache", "component_crx_cache", "CachedData",
    ]
    /// Found only in a Chromium profile or user-data folder.
    private static let markers: Set<String> = ["GPUCache", "Code Cache", "Local State"]
    /// Application Support › App › Partitions › name › Cache is four levels down.
    private static let maximumDepth = 4

    /// Whether a folder with these entries is a Chromium profile or user-data folder.
    public static func isProfile(_ entries: [String]) -> Bool {
        entries.contains(where: markers.contains)
    }

    /// The cache folders under `root`. `children` lists a folder's entries
    /// with whether each is a folder; nil when it can't be read.
    public static func folders(under root: String, children: (String) -> [(name: String, isFolder: Bool)]?) -> [String] {
        var found: [String] = []
        func walk(_ path: String, depth: Int) {
            guard depth < maximumDepth, let entries = children(path) else { return }
            let isProfile = isProfile(entries.map(\.name))
            for entry in entries where entry.isFolder {
                let child = path + "/" + entry.name
                if isProfile && names.contains(entry.name) {
                    found.append(child)
                } else {
                    walk(child, depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        return found
    }
}

/// Telling a cache or log an open app is using, which it would only write
/// again, into the Trash, from one that can go.
public enum JunkInUse {
    /// The open app `entry` (a file or folder directly in a cache or log
    /// folder, or an app's folder in Application Support) belongs to: named
    /// after its identifier or one of its names, or a vendor's folder the
    /// app's name starts with ("Google" for Google Chrome).
    public static func owner(of entry: String, running: [AppFootprint]) -> String? {
        let lowered = entry.lowercased()
        return running.first { app in
            app.identifiers.contains { id in
                let id = id.lowercased()
                return lowered == id || lowered.hasPrefix(id + ".")
            } || app.names.contains { name in
                AppLeftovers.isNamed(entry, after: name) || name.lowercased().hasPrefix(lowered + " ")
            }
        }?.name
    }
}
