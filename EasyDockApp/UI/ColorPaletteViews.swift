import EasyDockCore
import SwiftUI

/// The palettes in the Tools tab: a name, the colors, a field to add a HEX
/// and a menu that copies the whole palette as code.
struct PalettesSection: View {
    private let colorPicker = ColorPickerController.shared

    var body: some View {
        Section {
            if colorPicker.palettes.isEmpty {
                Text("Keep the colors of a brand or a project together, then copy them as CSS variables, JSON, SwiftUI or Tailwind. Right-click a color in the menu bar panel to add it to a palette.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(colorPicker.palettes) { palette in
                PaletteRow(palette: palette)
            }
            HStack {
                Spacer()
                Button("New Palette") { colorPicker.addPalette() }
            }
        } header: {
            Text("Palettes")
        }
    }
}

private struct PaletteRow: View {
    let palette: ColorPalette
    private let colorPicker = ColorPickerController.shared
    @State private var newHex = ""
    @State private var invalidHex = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Name", text: Binding(get: { palette.name }, set: { colorPicker.rename(palette.id, to: $0) }), prompt: Text("Name"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.headline)
                Spacer()
                Menu("Copy As") {
                    ForEach(PaletteExportFormat.allCases, id: \.self) { format in
                        Button(format.label) { colorPicker.copy(palette, as: format) }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
                .disabled(palette.colors.isEmpty)
                Button(role: .destructive) {
                    colorPicker.deletePalette(palette.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete Palette")
            }
            if !palette.colors.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 26, maximum: 26), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(palette.colors, id: \.self) { color in
                        ColorSwatch(color: color, size: 26) {
                            Button("Remove from Palette", role: .destructive) { colorPicker.remove(color, from: palette.id) }
                        }
                    }
                }
            }
            HStack {
                TextField("Add a HEX color, like #3352D6", text: $newHex, prompt: Text("Add a HEX color, like #3352D6"))
                    .labelsHidden()
                    .onSubmit(addHex)
                    .onChange(of: newHex) { invalidHex = false }
                if invalidHex {
                    Label("Not a HEX color", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func addHex() {
        guard let color = PickedColor(hex: newHex.trimmingCharacters(in: .whitespaces)) else {
            invalidHex = !newHex.isEmpty
            return
        }
        colorPicker.add(color, to: palette.id)
        newHex = ""
    }
}

/// A swatch that copies its color on a click; a right-click copies it in
/// any format, followed by the caller's own items.
struct ColorSwatch<Extra: View>: View {
    let color: PickedColor
    var size: CGFloat = 22
    @ViewBuilder var extra: () -> Extra
    private let colorPicker = ColorPickerController.shared

    var body: some View {
        Button {
            colorPicker.copy(color)
        } label: {
            Circle()
                .fill(color.swiftUIColor)
                .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color.hex)
        .accessibilityLabel(color.hex)
        .contextMenu {
            ForEach(ColorFormat.allCases, id: \.self) { format in
                Button(color.string(format)) { colorPicker.copy(color, as: format) }
            }
            Divider()
            extra()
        }
    }
}

/// WCAG contrast between a text color and a background, each typed as HEX
/// or chosen from the pinned, recent and palette colors.
struct ContrastSection: View {
    @State private var textHex = "#000000"
    @State private var backgroundHex = "#FFFFFF"

    var body: some View {
        Section {
            ContrastColorField(title: "Text Color", hex: $textHex)
            ContrastColorField(title: "Background Color", hex: $backgroundHex)
            if let text = PickedColor(hex: textHex), let background = PickedColor(hex: backgroundHex) {
                let check = ContrastCheck(text, background)
                HStack(alignment: .center, spacing: 16) {
                    Text(verbatim: "Aa")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(text.swiftUIColor)
                        .frame(width: 64, height: 48)
                        .background(background.swiftUIColor, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.15)))
                    Text(verbatim: check.text)
                        .font(.title2.monospacedDigit().weight(.semibold))
                    Spacer()
                    Button {
                        (textHex, backgroundHex) = (backgroundHex, textHex)
                    } label: {
                        Label("Swap Colors", systemImage: "arrow.up.arrow.down")
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow {
                        Text(verbatim: "")
                        Text(verbatim: "AA").font(.caption.weight(.semibold))
                        Text(verbatim: "AAA").font(.caption.weight(.semibold))
                    }
                    GridRow {
                        Text("Normal text")
                        result(check.normalTextAA)
                        result(check.normalTextAAA)
                    }
                    GridRow {
                        Text("Large text (18 pt, or 14 pt bold)")
                        result(check.largeTextAA)
                        result(check.largeTextAAA)
                    }
                }
            }
        } header: {
            Text("Contrast")
        }
    }

    private func result(_ passes: Bool) -> some View {
        Label(passes ? "Pass" : "Fail", systemImage: passes ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(passes ? .green : .red)
    }
}

private struct ContrastColorField: View {
    let title: LocalizedStringKey
    @Binding var hex: String
    private let colorPicker = ColorPickerController.shared

    var body: some View {
        LabeledContent(title) {
            HStack {
                Circle()
                    .fill(PickedColor(hex: hex)?.swiftUIColor ?? .clear)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                    .frame(width: 18, height: 18)
                TextField(title, text: $hex)
                    .labelsHidden()
                    .frame(width: 100)
                Menu {
                    let history = colorPicker.history.all
                    ForEach(history, id: \.self) { color in
                        Button(color.hex) { hex = color.hex }
                    }
                    ForEach(colorPicker.palettes) { palette in
                        if !palette.colors.isEmpty {
                            Menu(palette.name) {
                                ForEach(palette.colors, id: \.self) { color in
                                    Button(color.hex) { hex = color.hex }
                                }
                            }
                        }
                    }
                } label: {
                    Label("Choose a pinned, recent or palette color", systemImage: "swatchpalette")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose a pinned, recent or palette color")
                .disabled(colorPicker.history.isEmpty && colorPicker.palettes.allSatisfy(\.colors.isEmpty))
            }
        }
    }
}

extension PickedColor {
    var swiftUIColor: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}
