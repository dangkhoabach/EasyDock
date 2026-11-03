import CryptoKit
import Foundation
import GRDB
import Testing
@testable import EasyDockCore

@Suite struct ClipboardTests {
    private let crypto = ClipboardCrypto(key: ClipboardCrypto.newKey())

    private func makeRepo(crypto: ClipboardCrypto? = nil) throws -> (ClipboardRepository, DatabaseQueue) {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(inMemory: queue)
        return (ClipboardRepository(dbQueue: queue, crypto: crypto ?? self.crypto), queue)
    }

    private func text(_ string: String) -> (ClipboardContent, ClipboardPreview) {
        (ClipboardContent(text: string), ClipboardPreview(text: string))
    }

    @Test func sealedDataOpensWithTheKeyAndNotWithAnother() throws {
        let sealed = try crypto.seal(ClipboardContent(text: "hello"))
        #expect(try crypto.open(ClipboardContent.self, from: sealed).text == "hello")
        let other = ClipboardCrypto(key: ClipboardCrypto.newKey())
        #expect(throws: (any Error).self) { try other.open(ClipboardContent.self, from: sealed) }
        var tampered = sealed
        tampered[tampered.count - 1] ^= 0xff
        #expect(throws: (any Error).self) { try crypto.open(ClipboardContent.self, from: tampered) }
    }

    /// Nothing copied appears in the database file in clear.
    @Test func theDatabaseHoldsNoCopiedTextInClear() throws {
        let (repo, queue) = try makeRepo()
        let secret = "PlainWordsThatMustNotAppear"
        let (content, preview) = text(secret)
        try repo.add(content, preview: preview, sourceApp: "com.example.editor")
        let blobs = try queue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM clipboard_items") }
        let dump = blobs.map { String(describing: $0) }.joined()
        #expect(!dump.contains(secret))
        #expect(try repo.items().first?.preview.text == secret)
        #expect(try repo.content(of: try repo.items().first!.id)?.text == secret)
    }

    @Test func copyingTheSameThingAgainMovesItUpInsteadOfAddingIt() throws {
        let (repo, _) = try makeRepo()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let (a, pa) = text("first"), (b, pb) = text("second")
        let firstID = try repo.add(a, preview: pa, sourceApp: nil, at: t0)
        try repo.add(b, preview: pb, sourceApp: nil, at: t0.addingTimeInterval(1))
        let again = try repo.add(ClipboardContent(text: "first", html: Data("<b>first</b>".utf8)), preview: pa, sourceApp: nil, at: t0.addingTimeInterval(2))
        #expect(again == firstID)
        #expect(try repo.items().map(\.preview.text) == ["first", "second"])
    }

    @Test func pinnedItemsComeFirstAndSurvivePruning() throws {
        let (repo, _) = try makeRepo()
        let now = Date(timeIntervalSince1970: 100 * 86_400)
        var ids: [Int64] = []
        for day in 0..<5 {
            let (content, preview) = text("item \(day)")
            ids.append(try repo.add(content, preview: preview, sourceApp: nil, at: now.addingTimeInterval(-Double(day) * 86_400 * 10)))
        }
        try repo.setPinned(ids[4], true)            // the oldest, 40 days old
        try repo.prune(maxItems: 2, maxDays: 30, now: now)
        #expect(try repo.items().map(\.preview.text) == ["item 4", "item 0", "item 1"])
    }

    @Test func zeroDaysKeepsEverythingUpToTheCount() throws {
        let (repo, _) = try makeRepo()
        let now = Date()
        for day in 0..<3 {
            let (content, preview) = text("old \(day)")
            try repo.add(content, preview: preview, sourceApp: nil, at: now.addingTimeInterval(-Double(day + 1) * 86_400 * 400))
        }
        try repo.prune(maxItems: 10, maxDays: 0, now: now)
        #expect(try repo.items().count == 3)
    }

    @Test func clearingRemovesEverythingIncludingPins() throws {
        let (repo, _) = try makeRepo()
        let (content, preview) = text("x")
        try repo.setPinned(try repo.add(content, preview: preview, sourceApp: nil), true)
        try repo.deleteAll()
        #expect(try repo.items().isEmpty)
    }

    /// After a new key (the old one lost), old items are skipped, not a failure.
    @Test func itemsUnderAnotherKeyAreLeftOut() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(inMemory: queue)
        let (content, preview) = text("written with the old key")
        try ClipboardRepository(dbQueue: queue, crypto: crypto).add(content, preview: preview, sourceApp: nil)
        let reader = ClipboardRepository(dbQueue: queue, crypto: ClipboardCrypto(key: ClipboardCrypto.newKey()))
        #expect(try reader.items().isEmpty)
    }

    @Test func searchMatchesEveryWordIgnoringCaseAndDiacritics() {
        let items = ["Cà phê sữa đá", "Coffee beans", "Tea"].enumerated().map { index, text in
            ClipboardItem(id: Int64(index), kind: .text, lastUsed: Date(), sourceApp: nil, isPinned: false, byteCount: 0,
                          preview: ClipboardPreview(text: text))
        }
        #expect(ClipboardSearch.filter(items, query: "cafe").isEmpty)
        #expect(ClipboardSearch.filter(items, query: "ca phe").map(\.id) == [0])
        #expect(ClipboardSearch.filter(items, query: "COFFEE").map(\.id) == [1])
        #expect(ClipboardSearch.filter(items, query: "  ").count == 3)
    }

    @Test func markedCopiesAreSkipped() {
        #expect(PasteboardMarkers.shouldSkip(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        #expect(PasteboardMarkers.shouldSkip(types: ["org.nspasteboard.TransientType"]))
        #expect(PasteboardMarkers.shouldSkip(types: [PasteboardMarkers.fromHistory]))
        #expect(!PasteboardMarkers.shouldSkip(types: ["public.utf8-plain-text", "public.html"]))
    }

    @Test func kindFollowsWhatWasCopied() {
        #expect(ClipboardContent(text: "a").kind == .text)
        #expect(ClipboardContent(png: Data([1])).kind == .image)
        #expect(ClipboardContent(text: "a", filePaths: ["/tmp/a"]).kind == .files)
        #expect(ClipboardPreview(text: String(repeating: "x", count: 5000)).text.count == ClipboardPreview.maxTextLength)
    }
}

@Suite struct ClipboardScaleTests {
    /// The whole list is read and its previews opened each time a panel
    /// shows; at the default limit that has to stay well under a frame or two.
    @Test func fiveHundredItemsOpenQuickly() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(inMemory: queue)
        let repo = ClipboardRepository(dbQueue: queue, crypto: ClipboardCrypto(key: ClipboardCrypto.newKey()))
        for index in 0..<500 {
            let text = "Item \(index) " + String(repeating: "lorem ipsum ", count: 40)
            try repo.add(ClipboardContent(text: text), preview: ClipboardPreview(text: text), sourceApp: "com.example.editor")
        }
        let start = Date()
        let items = try repo.items()
        let elapsed = Date().timeIntervalSince(start)
        #expect(items.count == 500)
        #expect(elapsed < 0.5, "opening 500 items took \(elapsed) s")
        print("500 items opened in \(Int(elapsed * 1000)) ms")
    }
}
