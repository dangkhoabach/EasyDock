import EasyDockCore
import SwiftUI

/// The in-app language for a window that isn't part of a SwiftUI scene.
struct QuickConvertRoot: View {
    @AppStorage("languagePreference") private var languageRaw = AppLocale.systemDefault.rawValue

    var body: some View {
        QuickConvertView()
            .environment(\.locale, (AppLocale(rawValue: languageRaw) ?? .systemDefault).locale)
    }
}

/// The files, the choices for pictures and for videos, then each file's
/// progress and result.
struct QuickConvertView: View {
    private let controller = QuickConvertController.shared
    @Bindable private var settings = SettingsViewModel.shared

    var body: some View {
        VStack(spacing: 0) {
            fileList
            Divider()
            if !controller.isRunning && !controller.isFinished {
                choices
                Divider()
            }
            buttons
        }
        .frame(width: 460)
        .onAppear { settings.loadIfNeeded() }
    }

    private var fileList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(controller.items) { item in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                            .resizable()
                            .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: item.url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            status(item.state)
                                .font(.caption)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 60, maxHeight: 220)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func status(_ state: QuickConvertController.State) -> some View {
        switch state {
        case .waiting:
            Text("Waiting").foregroundStyle(.secondary)
        case .working(let fraction):
            if let fraction {
                ProgressView(value: fraction).frame(maxWidth: 200)
            } else {
                Text("Converting…").foregroundStyle(.secondary)
            }
        case .done(let url):
            Label {
                Text(verbatim: url.lastPathComponent)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        case .failed(let message):
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        case .unsupported:
            Text("Not a picture or a video: left as it is").foregroundStyle(.secondary)
        }
    }

    private var choices: some View {
        Form {
            if controller.hasImages {
                Section {
                    Picker("Format", selection: $settings.settings.convertImageFormat) {
                        ForEach(ImageFormat.allCases, id: \.self) { format in
                            Text(verbatim: format.label).tag(format)
                        }
                    }
                    Picker("Size", selection: $settings.settings.convertMaxDimension) {
                        ForEach(QuickConvert.sizeChoices, id: \.self) { size in
                            if size == 0 {
                                Text("Same as the original").tag(size)
                            } else {
                                // A pixel count, not a quantity: no thousands separator.
                                Text("Longest side \(String(size)) px").tag(size)
                            }
                        }
                    }
                    if settings.settings.convertImageFormat.usesQuality {
                        LabeledContent("Quality") {
                            HStack {
                                Slider(value: Binding(get: { Double(settings.settings.convertQuality) },
                                                      set: { settings.settings.convertQuality = Int($0.rounded()) }),
                                       in: 40...100, step: 5)
                                Text(verbatim: "\(settings.settings.convertQuality)").monospacedDigit().frame(width: 30, alignment: .trailing)
                            }
                        }
                    }
                    Toggle("Keep camera, location and other details", isOn: $settings.settings.convertKeepMetadata)
                } header: {
                    Text("Pictures")
                }
            }
            if controller.hasVideos {
                Section {
                    Picker("Convert to", selection: $settings.settings.convertVideoPreset) {
                        ForEach(VideoPreset.allCases, id: \.self) { preset in
                            Text(LocalizedStringKey(preset.label)).tag(preset)
                        }
                    }
                } header: {
                    Text("Videos")
                }
            }
            Text("Each new file is saved next to its original; nothing is replaced.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var buttons: some View {
        HStack {
            if controller.isFinished, !controller.outputs.isEmpty {
                Button("Show in Finder") { controller.showOutputsInFinder() }
            }
            Spacer()
            if controller.isRunning {
                Button("Stop") { controller.cancel() }
            } else if controller.isFinished {
                Button("Done") { controller.close() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { controller.close() }
                    .keyboardShortcut(.cancelAction)
                Button("Convert") { controller.convert() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!controller.hasImages && !controller.hasVideos)
            }
        }
        .padding(16)
    }
}

extension ImageFormat {
    /// The same in every language.
    var label: String {
        switch self {
        case .webp: "WebP"
        case .avif: "AVIF"
        case .heic: "HEIC"
        case .jpeg: "JPEG"
        case .png: "PNG"
        }
    }
}

extension VideoPreset {
    /// A String Catalog key.
    var label: String {
        switch self {
        case .mp4Copy: "MP4, same quality (fast, nothing re-encoded)"
        case .h264_1080p: "MP4 H.264, up to 1080p (plays anywhere)"
        case .hevc_1080p: "MP4 HEVC, up to 1080p (smaller)"
        case .h264_720p: "MP4 H.264, up to 720p (smallest)"
        case .audioM4A: "Sound only (M4A)"
        }
    }
}
