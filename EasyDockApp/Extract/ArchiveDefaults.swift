import AppKit
import UniformTypeIdentifiers

/// EasyDock as the app that opens the archives macOS can't: the types
/// Info.plist claims with rank Default. Another app that claimed them first,
/// as VLC does RAR, keeps them until the user chooses here.
@MainActor
enum ArchiveDefaults {
    static var types: [UTType] {
        let documentTypes = Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        return documentTypes
            .filter { $0["LSHandlerRank"] as? String == "Default" }
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
