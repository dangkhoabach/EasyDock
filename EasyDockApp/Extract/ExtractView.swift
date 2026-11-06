import EasyDockCore
import SwiftUI
import UniformTypeIdentifiers

/// The in-app language for a window that isn't part of a SwiftUI scene.
struct ExtractRoot: View {
    @AppStorage("languagePreference") private var languageRaw = AppLocale.systemDefault.rawValue
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ExtractView()
            .environment(\.locale, (AppLocale(rawValue: languageRaw) ?? .systemDefault).locale)
            .onAppear { WindowPresenter.openWindow = openWindow }
    }
}

/// Each archive with its progress, a password field when one is needed,
/// and the result. More archives can be dropped on the window.
struct ExtractView: View {
    private let controller = ExtractController.shared

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.items) { item in
                        row(item)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 60, maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            buttons
        }
        .frame(width: 460)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in ExtractController.shared.open([url]) }
                }
            }
            return true
        }
    }

    private func row(_ item: ExtractController.Item) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status(item.state)
                    .font(.caption)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func status(_ state: ExtractController.State) -> some View {
        switch state {
        case .waiting:
            Text("Waiting").foregroundStyle(.secondary)
        case .working(let percent, let name):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: Double(percent), total: 100).frame(maxWidth: 260)
                if let name {
                    Text(verbatim: name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        case .needsPassword(let wrong):
            PasswordField(wrong: wrong)
        case .done(let url, let damaged):
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    if let url {
                        Text(verbatim: url.lastPathComponent)
                    } else {
                        Text("The archive is empty.")
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if damaged {
                    Label("Some files are damaged and may not open.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        case .failed(let message):
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        case .stopped:
            Text("Stopped").foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack {
            if !controller.results.isEmpty {
                Button("Show in Finder") { controller.showResultsInFinder() }
            }
            Spacer()
            if controller.isRunning {
                Button("Stop") { controller.stop() }
            } else {
                Button("Done") { controller.close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

/// Asked in the archive's own row; the password is never kept.
private struct PasswordField: View {
    let wrong: Bool
    @State private var password = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(wrong ? "The password is wrong. Try again." : "This archive needs a password.")
                .foregroundStyle(wrong ? .red : .secondary)
            HStack {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
                Button("Skip") { ExtractController.shared.answerPassword(nil) }
                Button("Extract", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
            .controlSize(.small)
        }
        .onAppear { focused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        ExtractController.shared.answerPassword(password)
    }
}
