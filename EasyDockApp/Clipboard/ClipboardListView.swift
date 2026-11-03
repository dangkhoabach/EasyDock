import AppKit
import EasyDockCore
import SwiftUI

/// The history, searchable, in both the menu bar panel's Clipboard tab and
/// the panel ⌘⇧V opens. ↑↓ select, Return pastes, ⌥Return pastes plain text;
/// a click pastes, ⌥-click as plain text.
struct ClipboardListView: View {
    /// Hides the panel the list is in, before anything is pasted.
    let close: () -> Void

    private let store = ClipboardStore.shared
    @Bindable private var settings = SettingsViewModel.shared
    @State private var query = ""
    @State private var selected = 0
    @State private var keyMonitor: Any?
    @State private var isConfirmingClear = false
    @State private var host = HostWindow()

    private var shown: [ClipboardItem] { ClipboardSearch.filter(store.items, query: query) }

    var body: some View {
        VStack(spacing: 0) {
            NativeSearchField(text: $query, placeholder: String(localized: "Search", bundle: AppLocale.bundle))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            content
            Divider()
            footer
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .background(HostWindowReader(host: host))
        .onChange(of: query) { _, _ in selected = 0 }
        .onAppear(perform: installKeys)
        .onDisappear(perform: removeKeys)
    }

    /// Clearing asks inline: a dialog would take the focus, and the panel
    /// closes when it loses it.
    @ViewBuilder
    private var footer: some View {
        if isConfirmingClear {
            HStack {
                Text("Delete all \(store.items.count) items, pinned ones too?")
                Spacer()
                Button("Cancel") { isConfirmingClear = false }
                Button("Delete All", role: .destructive) {
                    store.clearHistory()
                    isConfirmingClear = false
                }
            }
            .controlSize(.small)
        } else {
            HStack {
                Toggle("Record copies", isOn: $settings.settings.clipboardEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Spacer()
                Text("\(store.items.count) items").foregroundStyle(.secondary)
                Button {
                    isConfirmingClear = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(store.items.isEmpty)
                .help("Clear History…")
                .accessibilityLabel("Clear History…")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let failure = store.failure {
            message("exclamationmark.triangle", "The clipboard history can't open its key in the Keychain.", detail: failure)
        } else if store.items.isEmpty {
            message("doc.on.clipboard", settings.settings.clipboardEnabled
                    ? "Copy something and it shows up here."
                    : "Recording is off.")
        } else if shown.isEmpty {
            message("magnifyingglass", "No matches.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                            row(item, isSelected: index == selected)
                                .id(item.id)
                                .onTapGesture { choose(item, plainText: NSEvent.modifierFlags.contains(.option)) }
                                .contextMenu { menu(for: item) }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selected) { _, index in
                    if shown.indices.contains(index) { proxy.scrollTo(shown[index].id) }
                }
            }
        }
    }

    private func row(_ item: ClipboardItem, isSelected: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let data = item.preview.thumbnail, let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: item.kind == .files ? "doc" : "text.alignleft").foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.callout)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    if let source = item.sourceApp, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 12, height: 12)
                    }
                    Text(item.lastUsed, format: .relative(presentation: .named))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if item.isPinned {
                Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        // One element per item for VoiceOver, activated like a click.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityValue(item.isPinned ? Text("Pinned") : Text(verbatim: ""))
    }

    @ViewBuilder
    private func menu(for item: ClipboardItem) -> some View {
        Button("Paste") { choose(item, plainText: false) }
        if item.kind == .text {
            Button("Paste as Plain Text") { choose(item, plainText: true) }
        }
        Button("Copy") { store.copy(item) }
        Divider()
        Button(item.isPinned ? "Unpin" : "Pin") { store.togglePin(item) }
        Button("Delete", role: .destructive) { store.delete(item) }
    }

    private func message(_ systemImage: String, _ text: LocalizedStringKey, detail: String? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.title2).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func choose(_ item: ClipboardItem, plainText: Bool) {
        store.choose(item, plainText: plainText, close: close)
    }

    /// The arrows and Return work whatever has the focus, the search field
    /// included; other keys go on to it. Only in this list's own window:
    /// a hidden panel keeps its view, so the monitor outlives it, and it
    /// would otherwise take Return from EasyDock's other windows and paste.
    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = host.window, event.window === window, window.isKeyWindow else { return event }
            let items = shown
            switch Int(event.keyCode) {
            case 125: // down
                selected = min(selected + 1, max(items.count - 1, 0)); return nil
            case 126: // up
                selected = max(selected - 1, 0); return nil
            case 36, 76: // return, enter
                guard items.indices.contains(selected) else { return event }
                choose(items[selected], plainText: event.modifierFlags.contains(.option)); return nil
            default:
                return event
            }
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// The window a SwiftUI view is in, kept weakly.
final class HostWindow {
    weak var window: NSWindow?
}

private struct HostWindowReader: NSViewRepresentable {
    let host: HostWindow

    func makeNSView(context: Context) -> NSView { ReaderView(host: host) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        let host: HostWindow
        init(host: HostWindow) {
            self.host = host
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            host.window = window
        }
    }
}
