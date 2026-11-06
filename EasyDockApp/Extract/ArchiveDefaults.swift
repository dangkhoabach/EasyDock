import AppKit
import UniformTypeIdentifiers

/// EasyDock as the app that opens the archives macOS can't: the types
/// Info.plist claims with rank Owner, so it wins over another viewer's Default
/// claim, as VLC's on RAR (between equal ranks the app registered last wins).
/// Archive Utility, macOS's own app for 7z, and an app the user chose in
/// Finder's Get Info keep their types until the user chooses EasyDock here.
@MainActor
enum ArchiveDefaults {
    static var types: [UTType] {
        let documentTypes = Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        return documentTypes
            .filter { $0["LSHandlerRank"] as? String == "Owner" }
            .flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
            .compactMap { UTType($0) }
    }

    /// Whether EasyDock opens every one of them now.
    static var areEasyDock: Bool {
        types.allSatisfy { type in
            NSWorkspace.shared.urlForApplication(toOpen: type).flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
        }
    }

    static func makeEasyDock() async {
        for type in types {
            try? await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
        }
    }
}
