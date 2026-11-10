import EasyDockCore
import SwiftUI

/// The in-app language for a window that isn't part of a SwiftUI scene.
struct CompressRoot: View {
    @AppStorage("languagePreference") private var languageRaw = AppLocale.systemDefault.rawValue

    var body: some View {
        CompressView()
            .environment(\.locale, (AppLocale(rawValue: languageRaw) ?? .systemDefault).locale)
    }
}

/// The items, the choices, then each archive's progress and result.
struct CompressView: View {
    @Bindable private var controller = CompressController.shared
    @Bindable private var viewModel = SettingsViewModel.shared
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(spacing: 0) {
            if controller.jobs.isEmpty {
                itemList
                Divider()
                choices
            } else {
                jobList
            }
            Divider()
            buttons
        }
        .frame(width: 480)
        .onAppear { viewModel.loadIfNeeded() }
    }

    private var settings: AppSettings { viewModel.settings }

    // MARK: - Items

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(controller.items, id: \.self) { url in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 20, height: 20)
                            Text(verbatim: url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 24, maxHeight: 120)
            .fixedSize(horizontal: false, vertical: true)
            Group {
                let size = controller.totalSize.map { bytes($0) } ?? "…"
                if controller.items.count == 1 {
                    Text(verbatim: size)
                } else {
                    Text("\(controller.items.count) items, \(size)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    // MARK: - Choices

    private var choices: some View {
        Form {
            Section {
                if controller.makesOneEach {
                    LabeledContent("Name") {
                        Text("Each item's own name").foregroundStyle(.secondary)
                    }
                } else {
                    TextField("Name", text: $controller.name)
                }
                Picker("Format", selection: $viewModel.settings.compressFormat) {
                    ForEach(CompressFormat.allCases, id: \.self) { format in
                        Text(LocalizedStringKey(format.label)).tag(format)
                    }
                }
                if settings.compressFormat != .tar {
                    Picker("Compression", selection: $viewModel.settings.compressLevel) {
                        Text("Fast").tag(CompressLevel.fast)
                        Text("Balanced").tag(CompressLevel.balanced)
                        Text("Smallest").tag(CompressLevel.smallest)
                    }
                    .pickerStyle(.segmented)
                }
                PartSizePicker(size: $viewModel.settings.compressPartSize)
                if controller.items.count > 1 {
                    Toggle("One archive for each item", isOn: $viewModel.settings.compressEachItem)
                }
            }
            if settings.compressFormat.takesPassword {
                PasswordSection(password: $controller.password, confirmation: $controller.confirmation, format: settings.compressFormat)
            }
            if let problem = controller.problem {
                Label {
                    Text(verbatim: problem)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.caption)
            }
            Text("The archive is saved next to the items and never replaces anything. Finder's .DS_Store and ._ files are left out, and so are Finder tags.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Progress

    private var jobList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(controller.jobs) { job in
                    HStack(alignment: .top, spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: Self.iconPath(job)))
                            .resizable()
                            .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: Self.name(job))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            status(job.state)
                                .font(.caption)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 60, maxHeight: 320)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func status(_ state: CompressController.State) -> some View {
        switch state {
        case .waiting:
            Text("Waiting").foregroundStyle(.secondary)
        case .working(let percent, let name):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: Double(percent), total: 100).frame(maxWidth: 280)
                if let name {
                    Text(verbatim: name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        case .done(let parts, let size, let leftOut):
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    if parts.count > 1 {
                        Text("\(parts.count) parts, \(bytes(size)) in all")
                    } else {
                        Text(verbatim: bytes(size))
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if !leftOut.isEmpty {
                    Label {
                        Text("\(leftOut.count) files couldn't be read and were left out: \(Self.list(leftOut))")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .textSelection(.enabled)
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

    /// In the app's language, which may not be the system's.
    private func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file).locale(locale))
    }

    /// The name it was saved under, a number added when it was taken.
    private static func name(_ job: CompressController.Job) -> String {
        if case .done(let parts, _, _) = job.state, let first = parts.first {
            return parts.count > 1 ? (first.lastPathComponent as NSString).deletingPathExtension : first.lastPathComponent
        }
        return job.fileName
    }

    /// The archive once made; until then what goes in it.
    private static func iconPath(_ job: CompressController.Job) -> String {
        if case .done(let parts, _, _) = job.state, let first = parts.first { return first.path }
        return job.items[0].path
    }

    /// The first three names, then an ellipsis for the rest.
    private static func list(_ names: [String]) -> String {
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? shown + ", …" : shown
    }

    // MARK: - Buttons

    private var buttons: some View {
        HStack {
            if controller.isFinished, !controller.results.isEmpty {
                Button("Show in Finder") { controller.showResultsInFinder() }
            }
            Spacer()
            if controller.isRunning {
                Button("Stop") { controller.stop() }
            } else if controller.isFinished {
                Button("Done") { controller.done() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { controller.close() }
                    .keyboardShortcut(.cancelAction)
                Button("Compress") { controller.compress() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.items.isEmpty || controller.problem != nil)
            }
        }
        .padding(16)
    }
}

/// The password, typed twice unless shown; never kept.
private struct PasswordSection: View {
    @Binding var password: String
    @Binding var confirmation: String
    let format: CompressFormat
    @State private var shows = false

    var body: some View {
        Section {
            HStack {
                Group {
                    if shows {
                        TextField("Password", text: $password)
                    } else {
                        SecureField("Password", text: $password)
                    }
                }
                Button {
                    shows.toggle()
                } label: {
                    Image(systemName: shows ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(shows ? Text("Hide the password") : Text("Show the password"))
            }
            if !shows, !password.isEmpty {
                SecureField("Repeat", text: $confirmation)
            }
        } footer: {
            Text(LocalizedStringKey(format == .zip
                ? "Optional. AES-256: Finder and Windows Explorer can't open a ZIP locked this way; whoever gets it needs 7-Zip, WinRAR or The Unarchiver. For the strongest lock, choose 7z."
                : "Optional. AES-256, file names included: nothing in the archive can be seen without it."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Shown, it needs no second typing.
        .onChange(of: shows) { _, shown in if shown { confirmation = password } }
        .onChange(of: password) { _, typed in if shows { confirmation = typed } }
    }
}

/// Off, a preset or a size in megabytes typed in.
private struct PartSizePicker: View {
    @Binding var size: Int
    private static let custom = -1

    var body: some View {
        Picker("Split into parts", selection: Binding(
            get: { CompressSplit.presets.contains(size) ? size : Self.custom },
            set: { size = $0 == Self.custom ? 50_000_000 : $0 }
        )) {
            Text("Don't split").tag(0)
            Text("20 MB (mail)").tag(20_000_000)
            Text("100 MB").tag(100_000_000)
            Text("1 GB").tag(1_000_000_000)
            Text("4 GB (FAT32 disk)").tag(4_294_967_295)
            Text("Other size…").tag(Self.custom)
        }
        if !CompressSplit.presets.contains(size) {
            LabeledContent("Part size") {
                HStack(spacing: 4) {
                    TextField("", value: Binding(get: { size / 1_000_000 }, set: { size = max(1, $0) * 1_000_000 }), format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                    Text(verbatim: "MB")
                }
            }
        }
    }
}

extension CompressFormat {
    /// A String Catalog key.
    var label: String {
        switch self {
        case .zip: "ZIP: opens anywhere"
        case .sevenZip: "7z: smallest, strongest password"
        case .tarGz: "TAR.GZ: for Linux and servers"
        case .tarXz: "TAR.XZ: smaller, for Linux"
        case .tarBz2: "TAR.BZ2: for older Linux tools"
        case .tar: "TAR: not compressed"
        }
    }
}
