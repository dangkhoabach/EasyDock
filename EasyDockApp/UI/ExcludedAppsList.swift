import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Rows of apps, by bundle identifier, with a remove button each and an Add
/// App… button — the apps a feature leaves alone.
struct ExcludedAppsList: View {
    @Binding var bundleIDs: [String]

    var body: some View {
        ForEach(bundleIDs, id: \.self) { bundleID in
            HStack {
                appLabel(bundleID)
                Spacer()
                Button {
                    bundleIDs.removeAll { $0 == bundleID }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove")
            }
        }
        Button("Add App…", action: addApps)
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
            // Not installed (or uninstalled since): the identifier is all there is to show.
            Text(verbatim: bundleID).foregroundStyle(.secondary)
        }
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier, !bundleIDs.contains(bundleID) {
                bundleIDs.append(bundleID)
            }
        }
    }
}
