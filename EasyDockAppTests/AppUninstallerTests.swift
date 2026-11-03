import Foundation
import Testing
@testable import EasyDock

/// The uninstaller lists the app first, then what it left in the Library,
/// and nothing that belongs to another app.
@Suite struct AppUninstallerTests {
    @Test func theAppAndItsLeftoversAreListedAndNothingElse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("uninstaller-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Library")
        let app = root.appendingPathComponent("Notes.app")
        let paths = [
            "Notes.app/Contents/Info.plist",
            "Library/Preferences/com.example.Notes.plist",
            "Library/Caches/com.example.Notes/cache.db",
            "Library/Application Support/Notes/data.json",
            "Library/Containers/com.example.Notes/Data/file",
            "Library/Preferences/com.example.Notes.canary.plist",
            "Library/Caches/com.example.Other/cache.db",
        ]
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 5000).write(to: url)
        }

        let items = await AppUninstaller().items(forAppAt: app, bundleID: "com.example.Notes", name: "Notes", library: library.path)

        #expect(items.first?.isAppBundle == true)
        #expect(items.first?.path == app.path)
        let leftovers = Set(items.dropFirst().map { String($0.path.dropFirst(library.path.count + 1)) })
        #expect(leftovers == [
            "Preferences/com.example.Notes.plist",
            "Caches/com.example.Notes",
            "Application Support/Notes",
            "Containers/com.example.Notes",
        ])
        #expect(items.allSatisfy { $0.bytes > 0 })
    }
}
