import CoreGraphics
import Foundation

/// One window as the window server lists it, reduced to what the switcher
/// needs. Built in the app from `CGWindowListCopyWindowInfo` and the Spaces
/// each window is on.
public struct WindowRecord: Equatable, Sendable {
    public var windowID: UInt32
    public var pid: Int32
    public var title: String
    public var size: CGSize
    /// The Spaces the window is on. Empty for the invisible helper windows
    /// apps keep around, which is how they are told apart from real ones.
    public var spaces: [UInt64]

    public init(windowID: UInt32, pid: Int32, title: String, size: CGSize, spaces: [UInt64]) {
        self.windowID = windowID
        self.pid = pid
        self.title = title
        self.size = size
        self.spaces = spaces
    }
}

/// A tile in the switcher: a window, or an app that has none.
public struct SwitcherItem: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case window(UInt32)
        case app
    }

    public var kind: Kind
    public var pid: Int32
    public var title: String
    public var isOnActiveSpace: Bool

    public var id: String {
        switch kind {
        case .window(let windowID): "w\(windowID)"
        case .app: "a\(pid)"
        }
    }

    public init(kind: Kind, pid: Int32, title: String, isOnActiveSpace: Bool) {
        self.kind = kind
        self.pid = pid
        self.title = title
        self.isOnActiveSpace = isOnActiveSpace
    }
}

/// One display and its Spaces, as the window server lists them.
public struct DisplaySpaces: Equatable, Sendable {
    public struct Space: Equatable, Sendable {
        public var id: UInt64
        public var isFullScreen: Bool

        public init(id: UInt64, isFullScreen: Bool) {
            self.id = id
            self.isFullScreen = isFullScreen
        }
    }

    public var display: String
    public var current: UInt64
    public var spaces: [Space]

    public init(display: String, current: UInt64, spaces: [Space]) {
        self.display = display
        self.current = current
        self.spaces = spaces
    }
}

/// The Spaces whose windows the switcher shows in `SwitcherScope.currentDesktop`.
public enum SwitcherSpaces {
    /// Every display's desktop, since all of them are in view, and every
    /// full-screen app, which belongs to no desktop and is reached from all
    /// of them. A display showing a full-screen app counts its desktop as
    /// the one last shown on it (`lastDesktops`, by display), or its first.
    public static func shown(_ displays: [DisplaySpaces], lastDesktops: [String: UInt64]) -> Set<UInt64> {
        var shown: Set<UInt64> = []
        for display in displays {
            let desktops = display.spaces.filter { !$0.isFullScreen }.map(\.id)
            if desktops.contains(display.current) {
                shown.insert(display.current)
            } else if let last = lastDesktops[display.display], desktops.contains(last) {
                shown.insert(last)
            } else if let first = desktops.first {
                shown.insert(first)
            }
            shown.formUnion(display.spaces.filter(\.isFullScreen).map(\.id))
        }
        return shown
    }
}

public enum SwitcherList {
    /// Smaller than this is a palette, a badge or a minimized window's
    /// leftover, not something to switch to.
    public static let minimumSize = CGSize(width: 60, height: 40)

    /// The tiles in the order the switcher shows them.
    ///
    /// - Windows in `recentWindows` (focused since EasyDock started, most
    ///   recent first) come first, in that order.
    /// - Then the rest: on the active Space in the window server's order,
    ///   front to back; elsewhere (another Space, a hidden app) by how
    ///   recently their app was used. The window server's order alone is not
    ///   the order of use: with Stage Manager on, the windows in its strip
    ///   count as on screen too.
    /// - Apps in `apps` with no window at all come last, as one tile each,
    ///   like the system's ⌘Tab.
    ///
    /// `apps` are the apps that may appear, most recently used first; a
    /// window whose app isn't in it is left out (EasyDock itself, menu bar
    /// apps, agents).
    ///
    /// With `shownSpaces`, only windows on one of those Spaces are listed.
    /// An app gets its own tile only when it has no window anywhere: one
    /// whose windows are all on other desktops is left out with them.
    public static func make(
        windows: [WindowRecord], activeSpace: UInt64, apps: [(pid: Int32, name: String)], recentWindows: [UInt32] = [],
        shownSpaces: Set<UInt64>? = nil
    ) -> [SwitcherItem] {
        let rank = Dictionary(apps.enumerated().map { ($1.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let recency = Dictionary(recentWindows.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let names = Dictionary(apps.map { ($0.pid, $0.name) }, uniquingKeysWith: { first, _ in first })

        let real = windows.enumerated().filter { _, window in
            rank[window.pid] != nil && !window.spaces.isEmpty
                && window.size.width >= minimumSize.width && window.size.height >= minimumSize.height
        }
        let withWindows = Set(real.map(\.element.pid))
        let shown = shownSpaces.map { spaces in real.filter { !spaces.isDisjoint(with: $0.element.spaces) } } ?? real
        let ordered = shown.sorted { lhs, rhs in
            let (li, l) = lhs, (ri, r) = rhs
            let lRecent = recency[l.windowID] ?? Int.max, rRecent = recency[r.windowID] ?? Int.max
            if lRecent != rRecent { return lRecent < rRecent }
            let lActive = l.spaces.contains(activeSpace), rActive = r.spaces.contains(activeSpace)
            if lActive != rActive { return lActive }
            if !lActive, rank[l.pid]! != rank[r.pid]! { return rank[l.pid]! < rank[r.pid]! }
            return li < ri
        }
        var items = ordered.map { _, window in
            SwitcherItem(
                kind: .window(window.windowID),
                pid: window.pid,
                title: window.title.isEmpty ? names[window.pid] ?? "" : window.title,
                isOnActiveSpace: window.spaces.contains(activeSpace)
            )
        }
        for app in apps where !withWindows.contains(app.pid) {
            items.append(SwitcherItem(kind: .app, pid: app.pid, title: app.name, isOnActiveSpace: false))
        }
        return items
    }
}

/// Which tile is selected while ⌘ is held.
public struct SwitcherSelection: Equatable, Sendable {
    public private(set) var index: Int
    public let count: Int

    /// The first tile is where the user already is, so ⌘Tab starts on the
    /// second: a quick press-and-release goes back to the previous window.
    public init(count: Int) {
        self.count = count
        index = count > 1 ? 1 : 0
    }

    public mutating func next() {
        guard count > 0 else { return }
        index = (index + 1) % count
    }

    public mutating func previous() {
        guard count > 0 else { return }
        index = (index - 1 + count) % count
    }

    public mutating func select(_ newIndex: Int) {
        guard (0..<count).contains(newIndex) else { return }
        index = newIndex
    }
}
