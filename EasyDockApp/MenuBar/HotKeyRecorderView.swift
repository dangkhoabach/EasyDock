import AppKit
import SwiftUI

/// A Settings row: shows the shortcut, and while recording takes
/// the next key press (with ⌘/⌥/⌃) as the new one (ported from KeyCellar).
/// Window Snapping's shortcuts can also be cleared.
struct HotKeyRecorderView: View {
    let title: Text
    let target: HotKeyTarget
    let manager: HotKeyManager
    @State private var recording = false
    @State private var monitor: Any?
    /// The name of the EasyDock shortcut that already uses the keys pressed.
    @State private var takenBy: String?

    init(title: LocalizedStringKey, action: HotKeyAction, manager: HotKeyManager) {
        self.init(title: title, target: .app(action), manager: manager)
    }

    init(title: LocalizedStringKey, target: HotKeyTarget, manager: HotKeyManager) {
        self.init(title: Text(title), target: target, manager: manager)
    }

    /// For a title already translated, such as a Window Snapping action's.
    init(title: Text, target: HotKeyTarget, manager: HotKeyManager) {
        self.title = title
        self.target = target
        self.manager = manager
    }

    private var current: HotKey? {
        switch target {
        case .app(let action): manager.hotKey(for: action)
        case .snap(let key): manager.snapHotKey(key)
        }
    }

    private var failed: Bool {
        switch target {
        case .app(let action): manager.failed.contains(action)
        case .snap(let key): manager.snapFailed[key] != nil
        }
    }

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Button {
                        recording ? stop() : start()
                    } label: {
                        if recording {
                            Text("Press keys…")
                        } else if let current {
                            Text(verbatim: current.displayString)
                        } else {
                            Text("None").foregroundStyle(.secondary)
                        }
                    }
                    .frame(minWidth: 110)
                    if recording {
                        Button("Cancel") { stop() }
                    } else if case .snap(let key) = target, current != nil {
                        Button {
                            manager.updateSnap(key, to: nil)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(Text("Remove the shortcut"))
                    }
                }
                if let takenBy {
                    Label("“\(takenBy)” already uses this shortcut. Choose a different one.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                } else if failed {
                    Label("Another app already uses this shortcut, so it does nothing here. Choose a different one.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
        } label: {
            title
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        takenBy = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                Task { @MainActor in stop() }
                return nil
            }
            if let hotKey = HotKey(event: event) {
                Task { @MainActor in
                    record(hotKey)
                    stop()
                }
                return nil
            }
            return event
        }
    }

    private func record(_ hotKey: HotKey) {
        if let owner = manager.owner(of: hotKey), owner != target {
            takenBy = switch owner {
            case .app(let action): action.title
            case .snap(let key): SnapController.shared.title(forKey: key)
            }
            return
        }
        switch target {
        case .app(let action): manager.update(action, to: hotKey)
        case .snap(let key): manager.updateSnap(key, to: hotKey)
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
