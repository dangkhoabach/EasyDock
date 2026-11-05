import AppKit
import EasyDockCore
import SwiftUI
import UniformTypeIdentifiers

/// The apps EasyDock quits once they have gone unused for a while: each with
/// its time and a remove button, and an Add App… button.
struct IdleQuitList: View {
    @Binding var rules: [String: Int]

    var body: some View {
        ForEach(rules.keys.sorted(), id: \.self) { bundleID in
            HStack {
                appLabel(bundleID)
                Spacer()
                Picker("Quit after", selection: Binding(get: { rules[bundleID] ?? 60 }, set: { rules[bundleID] = $0 })) {
                    ForEach(IdleQuit.minuteChoices, id: \.self) { minutes in
                        Text(LocalizedStringKey(Self.title(minutes))).tag(minutes)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Button {
                    rules[bundleID] = nil
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove")
            }
        }
        Button("Add App…", action: addApps)
    }

    /// String Catalog keys.
    static func title(_ minutes: Int) -> String {
        switch minutes {
        case 15: "15 minutes unused"
        case 30: "30 minutes unused"
        case 60: "1 hour unused"
        case 120: "2 hours unused"
        default: "4 hours unused"
        }
    }

    @ViewBuilder
    private func appLabel(_ bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Label {
                Text(FileManager.default.displayName(atPath: url.path))
            } icon: {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
            }
        } else {
            Text(verbatim: bundleID).foregroundStyle(.secondary)
        }
    }

    /// An hour by default; macOS's own apps that keep the Mac going (Finder)
    /// and EasyDock itself can't be added.
    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier, rules[bundleID] == nil,
                  !["com.apple.finder", "com.dangkhoabach.easydock"].contains(bundleID) else { continue }
            rules[bundleID] = 60
        }
    }
}
