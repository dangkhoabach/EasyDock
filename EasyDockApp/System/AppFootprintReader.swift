import EasyDockCore
import Foundation
import Security

/// Reads an app's footprint from its bundle: its Info.plist, the bundles
/// and launchd jobs inside it, and the app groups in their code signatures.
/// Only a handful of known folders are listed, never the whole bundle.
enum AppFootprintReader {
    /// Where helpers, extensions, login items and launchd helper tools sit.
    /// Frameworks holds Electron's helper apps; the frameworks themselves
    /// are shared code and are skipped.
    private static let nestedFolders = [
        "Contents/Library/LoginItems", "Contents/Library/LaunchServices", "Contents/Library/SystemExtensions",
        "Contents/PlugIns", "Contents/XPCServices", "Contents/Helpers", "Contents/Frameworks", "Contents/MacOS",
        "Contents/Applications",
    ]
    private static let bundleExtensions: Set<String> = ["app", "appex", "xpc", "systemextension"]

    static func read(at path: String) -> AppFootprint? {
        guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty
        else { return nil }
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? fileName
        // The executable's name is left out: some are words any tool could
        // use ("launcher").
        var footprint = Footprint(ids: [], groups: entitlementGroups(at: path),
                                  names: [info["CFBundleName"] as? String, fileName].compactMap { $0 })
        collect(in: path, depth: 0, into: &footprint)
        for folder in ["Contents/Library/LaunchAgents", "Contents/Library/LaunchDaemons"] {
            for entry in list(path + "/" + folder) where entry.hasSuffix(".plist") {
                if let plist = NSDictionary(contentsOfFile: path + "/" + folder + "/" + entry) as? [String: Any],
                   let job = LaunchJob(plist: plist) {
                    footprint.ids.append(job.label)
                }
            }
        }
        return AppFootprint(bundleID: bundleID, name: name, path: path, embeddedIDs: footprint.ids,
                            groups: footprint.groups, names: footprint.names)
    }

    private struct Footprint {
        var ids: [String]
        var groups: [String]
        var names: [String]
    }

    /// The bundles in `bundle`'s known folders, and theirs one level down
    /// (Docker's app inside the app, with its own helpers). A helper tool
    /// in LaunchServices is named after its launchd label.
    private static func collect(in bundle: String, depth: Int, into footprint: inout Footprint) {
        for folder in nestedFolders {
            for entry in list(bundle + "/" + folder) {
                let path = bundle + "/" + folder + "/" + entry
                let ext = (entry as NSString).pathExtension
                if folder == "Contents/Library/LaunchServices" && !bundleExtensions.contains(ext) {
                    footprint.ids.append(entry)
                    continue
                }
                guard bundleExtensions.contains(ext),
                      let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") as? [String: Any],
                      let id = info["CFBundleIdentifier"] as? String
                else { continue }
                footprint.ids.append(id)
                // Electron's helper apps carry nothing of their own.
                guard folder != "Contents/Frameworks" else { continue }
                footprint.groups += entitlementGroups(at: path)
                if ext == "app" {
                    footprint.names += [info["CFBundleName"] as? String, (entry as NSString).deletingPathExtension].compactMap { $0 }
                    if depth == 0 { collect(in: path, depth: 1, into: &footprint) }
                }
            }
        }
    }

    private static func list(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    /// The app groups the code at `path` is signed to use. Read from the
    /// signature on disk, without checking it: only names are wanted.
    private static func entitlementGroups(at path: String) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return [] }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any],
              let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }
}
