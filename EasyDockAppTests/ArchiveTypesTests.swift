import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import EasyDock

/// The archive types in Info.plist, as Launch Services reads them: each type
/// EasyDock claims first must be declared without help from another app, and
/// the ones EasyDock declares carry its icon.
@MainActor struct ArchiveTypesTests {
    private static func plist(_ url: URL) -> [String: Any] {
        (try? PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)) as? [String: Any] ?? [:]
    }

    private static let info = Bundle.main.infoDictionary ?? [:]
    private static let imported = info["UTImportedTypeDeclarations"] as? [[String: Any]] ?? []

    /// The identifiers macOS declares itself, in CoreTypes.
    private static let systemTypes: Set<String> = {
        let coreTypes = plist(URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Info.plist"))
        let declarations = (coreTypes["UTExportedTypeDeclarations"] as? [[String: Any]] ?? [])
            + (coreTypes["UTImportedTypeDeclarations"] as? [[String: Any]] ?? [])
        return Set(declarations.compactMap { $0["UTTypeIdentifier"] as? String })
    }()

    @Test func everyTypeEasyDockOpensFirstIsDeclaredWithoutAnotherApp() {
        let declaredHere = Set(Self.imported.compactMap { $0["UTTypeIdentifier"] as? String })
        let types = ArchiveDefaults.types.map(\.identifier)

        // RAR is not in CoreTypes: without its own declaration, a .rar is a dyn. type on a Mac
        // with no other app that declares it, and EasyDock's claim never applies.
        #expect(types.contains("com.rarlab.rar-archive"))
        #expect(declaredHere.contains("com.rarlab.rar-archive"))
        for type in types {
            #expect(Self.systemTypes.contains(type) || declaredHere.contains(type), "\(type) is declared by no one")
        }
    }

    @Test func theTypesEasyDockOpensFirstOutrankOtherViewers() {
        // VLC claims RAR and Archive Utility 7z with rank Default; between equal ranks the app
        // registered last wins, so only Owner keeps them with EasyDock.
        let documentTypes = Self.info["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        let ranks = Dictionary(grouping: documentTypes.flatMap { claim in
            (claim["LSItemContentTypes"] as? [String] ?? []).map { ($0, claim["LSHandlerRank"] as? String ?? "") }
        }, by: \.0).mapValues { $0.map(\.1) }
        #expect(ranks["com.rarlab.rar-archive"] == ["Owner"])
        #expect(ranks["org.7-zip.7-zip-archive"] == ["Owner"])
        #expect(ranks["public.zip-archive"] == ["Alternate"])
    }

    @Test func theTypesEasyDockDeclaresShowItsIconAndTheirFormat() throws {
        // A type that conforms to public.archive gets the zipper icon unless its declaration
        // names one: the system draws the badge on a page with the text under it.
        #expect(!Self.imported.isEmpty)
        for declaration in Self.imported {
            let identifier = declaration["UTTypeIdentifier"] as? String ?? "?"
            let icons = try #require(declaration["UTTypeIcons"] as? [String: Any], "\(identifier) has no UTTypeIcons")
            let badge = try #require(icons["UTTypeIconBadgeName"] as? String)
            #expect(Bundle.main.image(forResource: badge) != nil, "\(identifier): no \(badge) in the app")
            let text = icons["UTTypeIconText"] as? String ?? ""
            #expect((1...4).contains(text.count), "\(identifier): text \(text)")
        }
    }
}
