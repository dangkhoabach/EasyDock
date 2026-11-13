import CoreGraphics
import Foundation
import GRDB

/// A size and place the user made, in percent of the screen's usable area.
public struct CustomSnapSize: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(id: UUID = UUID(), name: String, x: Double, y: Double, width: Double, height: Double) {
        self.id = id
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Named, and entirely on the screen.
    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 100.0001 && y + height <= 100.0001
    }

    public var unitRect: UnitRect {
        UnitRect(x0: x / 100, y0: y / 100, x1: min(1, (x + width) / 100), y1: min(1, (y + height) / 100))
    }
}

/// The windows of several apps and where they were, to put back later.
public struct WindowLayout: Codable, Identifiable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var bundleID: String
        /// Matched first when the layout is put back.
        public var title: String
        /// The window's place among its app's windows when saved; matched
        /// when the titles don't.
        public var index: Int
        public var screenID: String
        /// In fractions of that screen's usable area, so it fits a screen
        /// whose Dock or resolution changed since.
        public var frame: UnitRect

        public init(bundleID: String, title: String, index: Int, screenID: String, frame: UnitRect) {
            self.bundleID = bundleID
            self.title = title
            self.index = index
            self.screenID = screenID
            self.frame = frame
        }
    }

    public var id: UUID
    public var name: String
    public var windows: [Window]

    public init(id: UUID = UUID(), name: String, windows: [Window]) {
        self.id = id
        self.name = name
        self.windows = windows
    }

    public static func unitRect(of frame: CGRect, in visible: CGRect) -> UnitRect {
        UnitRect(x0: (frame.minX - visible.minX) / visible.width, y0: (frame.minY - visible.minY) / visible.height,
                 x1: (frame.maxX - visible.minX) / visible.width, y1: (frame.maxY - visible.minY) / visible.height)
    }

    public static func frame(of unit: UnitRect, in visible: CGRect) -> CGRect {
        let x = (visible.minX + unit.x0 * visible.width).rounded(), y = (visible.minY + unit.y0 * visible.height).rounded()
        return CGRect(x: x, y: y,
                      width: (visible.minX + unit.x1 * visible.width).rounded() - x,
                      height: (visible.minY + unit.y1 * visible.height).rounded() - y)
    }

    /// Pairs one app's saved windows with its open ones (given by title, in
    /// the order the app lists them): the same title first, then what is
    /// left in order. Each window is used once.
    public static func match(saved: [Window], openTitles: [String]) -> [(saved: Int, open: Int)] {
        var pairs: [(saved: Int, open: Int)] = []
        var usedOpen = Set<Int>(), usedSaved = Set<Int>()
        for (s, window) in saved.enumerated() where !window.title.isEmpty {
            if let o = openTitles.indices.first(where: { !usedOpen.contains($0) && openTitles[$0] == window.title }) {
                pairs.append((s, o))
                usedOpen.insert(o)
                usedSaved.insert(s)
            }
        }
        let restSaved = saved.indices.filter { !usedSaved.contains($0) }.sorted { saved[$0].index < saved[$1].index }
        let restOpen = openTitles.indices.filter { !usedOpen.contains($0) }
        for (s, o) in zip(restSaved, restOpen) { pairs.append((s, o)) }
        return pairs
    }

    /// The screen a saved window goes to: the same one, or the main one
    /// (first in `screens`) when it is no longer connected.
    public static func screenIndex(for id: String, in screens: [SnapScreen]) -> Int? {
        screens.firstIndex { $0.id == id } ?? (screens.isEmpty ? nil : 0)
    }
}

/// Custom sizes and layouts, as JSON in `app_settings`.
public struct SnapStore: Sendable {
    let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func loadSizes() throws -> [CustomSnapSize] { try load("snap_custom_sizes") }
    public func saveSizes(_ sizes: [CustomSnapSize]) throws { try save(sizes, "snap_custom_sizes") }
    public func loadLayouts() throws -> [WindowLayout] { try load("snap_layouts") }
    public func saveLayouts(_ layouts: [WindowLayout]) throws { try save(layouts, "snap_layouts") }

    private func load<T: Decodable>(_ key: String) throws -> [T] {
        let json = try dbQueue.read { db in try AppSettingsStore.get(db, key: key, default: "[]") }
        return (try? JSONDecoder().decode([T].self, from: Data(json.utf8))) ?? []
    }

    private func save<T: Encodable>(_ items: [T], _ key: String) throws {
        let json = String(decoding: try JSONEncoder().encode(items), as: UTF8.self)
        try dbQueue.write { db in try AppSettingsStore.set(db, key: key, value: json) }
    }
}
