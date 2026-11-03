import Foundation
import GRDB

/// The clipboard history in `clipboard_items`. Only sealed data and plain
/// facts about it (kind, time, source app, size, a keyed hash) are stored.
public struct ClipboardRepository: Sendable {
    let dbQueue: DatabaseQueue
    let crypto: ClipboardCrypto

    public init(dbQueue: DatabaseQueue, crypto: ClipboardCrypto) {
        self.dbQueue = dbQueue
        self.crypto = crypto
    }

    /// Adds a copy, or moves an equal earlier one to the top (keeping its pin).
    @discardableResult
    public func add(_ content: ClipboardContent, preview: ClipboardPreview, sourceApp: String?, at date: Date = Date()) throws -> Int64 {
        let identity = crypto.identity(of: content)
        let sealedContent = try crypto.seal(content)
        let sealedPreview = try crypto.seal(preview)
        return try dbQueue.write { db in
            if let id = try Int64.fetchOne(db, sql: "SELECT id FROM clipboard_items WHERE identity = ?", arguments: [identity]) {
                try db.execute(sql: "UPDATE clipboard_items SET last_used = ?, source_app = ? WHERE id = ?",
                               arguments: [date.timeIntervalSince1970, sourceApp, id])
                return id
            }
            try db.execute(sql: """
                INSERT INTO clipboard_items (kind, last_used, source_app, pinned, byte_count, identity, preview, content)
                VALUES (?, ?, ?, 0, ?, ?, ?, ?)
                """, arguments: [content.kind.rawValue, date.timeIntervalSince1970, sourceApp, content.byteCount,
                                 identity, sealedPreview, sealedContent])
            return db.lastInsertedRowID
        }
    }

    /// Pinned first, then the most recently used. An item whose preview
    /// can't be opened (a key that changed) is left out rather than failing
    /// the whole list.
    public func items() throws -> [ClipboardItem] {
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, kind, last_used, source_app, pinned, byte_count, preview FROM clipboard_items
                ORDER BY pinned DESC, last_used DESC
                """)
        }
        return rows.compactMap { row in
            guard let kind = ClipboardKind(rawValue: row["kind"]),
                  let preview = try? crypto.open(ClipboardPreview.self, from: row["preview"]) else { return nil }
            return ClipboardItem(
                id: row["id"], kind: kind, lastUsed: Date(timeIntervalSince1970: row["last_used"]),
                sourceApp: row["source_app"], isPinned: row["pinned"], byteCount: row["byte_count"], preview: preview)
        }
    }

    public func content(of id: Int64) throws -> ClipboardContent? {
        guard let sealed = try dbQueue.read({ db in
            try Data.fetchOne(db, sql: "SELECT content FROM clipboard_items WHERE id = ?", arguments: [id])
        }) else { return nil }
        return try crypto.open(ClipboardContent.self, from: sealed)
    }

    public func markUsed(_ id: Int64, at date: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE clipboard_items SET last_used = ? WHERE id = ?", arguments: [date.timeIntervalSince1970, id])
        }
    }

    public func setPinned(_ id: Int64, _ pinned: Bool) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE clipboard_items SET pinned = ? WHERE id = ?", arguments: [pinned, id])
        }
    }

    public func delete(_ id: Int64) throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM clipboard_items WHERE id = ?", arguments: [id]) }
    }

    /// Everything, pinned items included, and the file shrunk so the freed
    /// pages don't linger (`VACUUM` can't run inside a transaction).
    public func deleteAll() throws {
        try dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "DELETE FROM clipboard_items")
            try db.execute(sql: "VACUUM")
        }
    }

    /// Drops unpinned items older than `maxDays` (0 keeps them) and any
    /// unpinned items past the newest `maxItems`. Pinned items stay.
    public func prune(maxItems: Int, maxDays: Int, now: Date = Date()) throws {
        try dbQueue.write { db in
            if maxDays > 0 {
                let cutoff = now.addingTimeInterval(-Double(maxDays) * 86_400).timeIntervalSince1970
                try db.execute(sql: "DELETE FROM clipboard_items WHERE pinned = 0 AND last_used < ?", arguments: [cutoff])
            }
            try db.execute(sql: """
                DELETE FROM clipboard_items WHERE pinned = 0 AND id NOT IN (
                    SELECT id FROM clipboard_items WHERE pinned = 0 ORDER BY last_used DESC LIMIT ?)
                """, arguments: [maxItems])
        }
    }
}

public enum ClipboardSearch {
    /// Items whose text or file names contain every word of the query,
    /// ignoring case and diacritics ("cafe" finds "Cà phê").
    public static func filter(_ items: [ClipboardItem], query: String) -> [ClipboardItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            words.allSatisfy { item.preview.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

/// The nspasteboard.org markers apps put on what should not be kept.
public enum PasteboardMarkers {
    public static let concealed = "org.nspasteboard.ConcealedType"
    public static let transient = "org.nspasteboard.TransientType"
    public static let autoGenerated = "org.nspasteboard.AutoGeneratedType"
    /// Put by EasyDock on what it writes back from the history, so that
    /// isn't recorded as a new copy.
    public static let fromHistory = "com.dangkhoabach.easydock.from-history"

    public static func shouldSkip(types: [String]) -> Bool {
        types.contains { [concealed, transient, autoGenerated, fromHistory].contains($0) }
    }
}
