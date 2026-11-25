import Foundation
import GRDB

/// What EasyDock moved to the Trash while cleaning and uninstalling, so it
/// can delete those items for good later — on request, or once they have
/// sat there for the days the user chose — and leave the rest of the Trash
/// alone.
public struct TrashLedger: Sendable {
    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    /// The file system's identity of an item: what was moved, not just
    /// what has its name now. A name in the Trash can be reused by
    /// something the user put there.
    public struct Identity: Sendable, Equatable {
        public var device: Int64
        public var inode: Int64

        public init(device: Int64, inode: Int64) {
            self.device = device
            self.inode = inode
        }
    }

    public struct Entry: Sendable, Equatable {
        public var trashPath: String
        public var bytes: Int64
        public var movedAt: Date
        public var identity: Identity

        public init(trashPath: String, bytes: Int64, movedAt: Date, identity: Identity) {
            self.trashPath = trashPath
            self.bytes = bytes
            self.movedAt = movedAt
            self.identity = identity
        }
    }

    /// The item at `path` itself, a link included, not what it points to.
    /// Works in the Trash without Full Disk Access, which only listing the
    /// Trash needs.
    public static func identity(of path: String) -> Identity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Identity(device: Int64(info.st_dev), inode: Int64(info.st_ino))
    }

    public func record(_ entries: [Entry]) throws {
        guard !entries.isEmpty else { return }
        try dbQueue.write { db in
            for entry in entries {
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO trash_ledger (trash_path, bytes, moved_at, device, inode)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [entry.trashPath, entry.bytes, entry.movedAt.timeIntervalSince1970,
                                entry.identity.device, entry.identity.inode]
                )
            }
        }
    }

    /// Every entry, or those moved at or before `date`.
    public func entries(movedBefore date: Date = .distantFuture) throws -> [Entry] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM trash_ledger WHERE moved_at <= ? ORDER BY moved_at",
                             arguments: [date.timeIntervalSince1970]).map { row in
                Entry(trashPath: row["trash_path"], bytes: row["bytes"],
                      movedAt: Date(timeIntervalSince1970: row["moved_at"]),
                      identity: Identity(device: row["device"], inode: row["inode"]))
            }
        }
    }

    public func remove(_ trashPaths: [String]) throws {
        guard !trashPaths.isEmpty else { return }
        try dbQueue.write { db in
            for path in trashPaths {
                try db.execute(sql: "DELETE FROM trash_ledger WHERE trash_path = ?", arguments: [path])
            }
        }
    }

    /// The entries whose item is still in the Trash: there, and the same item.
    public static func present(_ entries: [Entry], identity: (String) -> Identity? = identity(of:)) -> [Entry] {
        entries.filter { identity($0.trashPath) == $0.identity }
    }

    /// Deletes for good each entry's item that is still the item EasyDock
    /// moved. `settled` are the entries done with: deleted, or no longer
    /// there to delete (put back, emptied, replaced); the rest failed and
    /// are tried again next time.
    public static func purge(_ entries: [Entry], identity: (String) -> Identity? = identity(of:),
                             remove: (URL) throws -> Void = TrashFolders.removePermanently) -> (freed: Int64, settled: [String]) {
        var freed: Int64 = 0
        var settled: [String] = []
        for entry in entries {
            guard identity(entry.trashPath) == entry.identity else {
                settled.append(entry.trashPath)
                continue
            }
            do {
                try remove(URL(fileURLWithPath: entry.trashPath))
                freed += entry.bytes
                settled.append(entry.trashPath)
            } catch {
                continue
            }
        }
        return (freed, settled)
    }
}

/// The apps EasyDock has seen installed, with their footprints, so what an
/// app left can still be recognized after it is gone, even when it went
/// while EasyDock wasn't running.
public struct KnownAppStore: Sendable {
    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public struct Record: Sendable, Equatable {
        public var footprint: AppFootprint
        /// Its removal was already told in a notification.
        public var removalNoticed: Bool
    }

    /// Saves what is installed now. An app installed again is no longer
    /// one whose removal was noticed.
    public func save(_ footprints: [AppFootprint]) throws {
        guard !footprints.isEmpty else { return }
        let encoder = JSONEncoder()
        try dbQueue.write { db in
            for footprint in footprints {
                try db.execute(
                    sql: """
                        INSERT INTO known_apps (bundle_id, footprint, removal_noticed) VALUES (?, ?, 0)
                        ON CONFLICT(bundle_id) DO UPDATE SET footprint = excluded.footprint, removal_noticed = 0
                        """,
                    arguments: [footprint.bundleID.lowercased(), String(decoding: try encoder.encode(footprint), as: UTF8.self)]
                )
            }
        }
    }

    public func all() throws -> [Record] {
        let decoder = JSONDecoder()
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT footprint, removal_noticed FROM known_apps").compactMap { row in
                let json: String = row["footprint"]
                guard let footprint = try? decoder.decode(AppFootprint.self, from: Data(json.utf8)) else { return nil }
                return Record(footprint: footprint, removalNoticed: row["removal_noticed"])
            }
        }
    }

    public func markRemovalNoticed(_ bundleID: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE known_apps SET removal_noticed = 1 WHERE bundle_id = ?", arguments: [bundleID.lowercased()])
        }
    }
}
