import AppKit
import EasyDockCore
import SwiftUI

/// The switcher's window: centred on the screen with the pointer, over
/// full-screen apps too, and never key — the keys reach EasyDock through its
/// event tap, so the app in front keeps the focus until a window is chosen.
final class SwitcherPanel: NSPanel {
    static let tileSize = CGSize(width: 200, height: 150)
    static let spacing: CGFloat = 10
    static let padding: CGFloat = 16
    static let maxColumns = 6

    init(onPick: @escaping (Int) -> Void) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        let hosting = NSHostingView(rootView: SwitcherView(onPick: onPick))
        hosting.safeAreaRegions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
    }

    override var canBecomeKey: Bool { false }

    /// Sized for the current tiles, at most two thirds of the screen high.
    @MainActor
    func show() {
        let count = max(SwitcherState.shared.items.count, 1)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let columns = min(count, Self.maxColumns)
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        let width = CGFloat(columns) * Self.tileSize.width + CGFloat(columns - 1) * Self.spacing + Self.padding * 2
        let fullHeight = CGFloat(rows) * Self.tileSize.height + CGFloat(rows - 1) * Self.spacing + Self.padding * 2
        let height = min(fullHeight, visible.height * 2 / 3)
        setFrame(NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height), display: true)
        orderFrontRegardless()
    }
}

private struct SwitcherView: View {
    let onPick: (Int) -> Void
    private let state = SwitcherState.shared
    private let thumbnails = ThumbnailCache.shared

    var body: some View {
        let columns = min(max(state.items.count, 1), SwitcherPanel.maxColumns)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(SwitcherPanel.tileSize.width), spacing: SwitcherPanel.spacing), count: columns),
                    spacing: SwitcherPanel.spacing
                ) {
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                        tile(item, selected: index == state.selectedIndex)
                            .id(index)
                            .onTapGesture { onPick(index) }
                    }
                }
                .padding(SwitcherPanel.padding)
            }
            .scrollIndicators(.never)
            .onChange(of: state.selectedIndex) { _, index in proxy.scrollTo(index) }
        }
    }

    private func tile(_ item: SwitcherItem, selected: Bool) -> some View {
        let icon = NSRunningApplication(processIdentifier: item.pid)?.icon
        return VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.18))
                if case .window(let id) = item.kind, let image = thumbnails.images[id] {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(4)
                } else if let icon {
                    Image(nsImage: icon).resizable().frame(width: 56, height: 56)
                }
            }
            .frame(height: SwitcherPanel.tileSize.height - 40)
            HStack(spacing: 5) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                Text(item.title).font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .frame(width: SwitcherPanel.tileSize.width, height: SwitcherPanel.tileSize.height)
        .background(selected ? Color.accentColor.opacity(0.35) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
