import EasyDockCore
import SwiftUI

/// The Window Snapping tab: the shortcuts, dragging to the screen edges and
/// the zones, custom sizes, layouts and the apps left alone.
struct SnapView: View {
    @Bindable private var viewModel = SettingsViewModel.shared
    private let controller = SnapController.shared
    private let permissions = Permissions.shared
    @State private var macTilingOn = MacTiling.edgeDragIsOn()

    private var settings: AppSettings { viewModel.settings }

    var body: some View {
        Form {
            Section {
                Toggle("Snap windows with shortcuts", isOn: $viewModel.settings.snapEnabled)
                Text("Put the window in front on a half, a quarter, a third or a sixth of its screen, fill the screen or nearly, center it, or send it to another display. Restore puts it back as it was before EasyDock moved it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.snapEnabled && !permissions.accessibility {
                    HStack {
                        Label("This needs the Accessibility permission.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Allow…") { permissions.requestAccessibility() }
                    }
                }
            } header: {
                Text("Window Snapping")
            }

            Group {
                ForEach(SnapAction.Group.allCases, id: \.self) { group in
                    Section {
                        ForEach(SnapAction.allCases.filter { $0.group == group }, id: \.self) { action in
                            actionRow(action)
                        }
                    } header: {
                        Text(group.title)
                    }
                }

                Section {
                    Toggle("Press a half or a quarter again for two thirds, then one third", isOn: $viewModel.settings.snapCycleSizes)
                    Stepper(value: $viewModel.settings.snapGap, in: 0...30, step: 2) {
                        LabeledContent("Gap between windows", value: "\(settings.snapGap) pt")
                    }
                } header: {
                    Text("Options")
                }

                Section {
                    Toggle("Drop a window at a screen edge to snap it", isOn: $viewModel.settings.snapDragEnabled)
                    Toggle("A snapped window dragged away gets its size back", isOn: $viewModel.settings.snapRestoreOnDrag)
                        .disabled(!settings.snapDragEnabled)
                    if settings.snapDragEnabled && macTilingOn {
                        HStack {
                            Label("macOS also tiles windows dropped at the screen edges, so a window would be placed twice. Turn off “Drag windows to screen edges to tile” and “Drag windows to menu bar to fill screen” in Desktop & Dock.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Open Desktop & Dock…") { MacTiling.openSettings() }
                        }
                    }
                    SnapZonesEditor(zones: $viewModel.settings.snapZones, sizes: controller.sizes)
                        .disabled(!settings.snapDragEnabled)
                } header: {
                    Text("Drag to Screen Edges")
                }

                CustomSizesSection()
                LayoutsSection()

                Section {
                    ExcludedAppsList(bundleIDs: $viewModel.settings.snapExcludedApps)
                    Text("Shortcuts and dragging leave their windows where they are. Layouts still arrange them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Apps Left Alone")
                }
            }
            .disabled(!settings.snapEnabled)
        }
        .formStyle(.grouped)
        .onAppear {
            viewModel.loadIfNeeded()
            macTilingOn = MacTiling.edgeDragIsOn()
        }
        // The setting is changed in System Settings, while EasyDock is behind it.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            macTilingOn = MacTiling.edgeDragIsOn()
        }
    }

    @ViewBuilder
    private func actionRow(_ action: SnapAction) -> some View {
        HStack(spacing: 10) {
            SnapAreaIcon(action: action)
            if let hotKeys = StatusBarController.shared.hotKeys {
                HotKeyRecorderView(title: Text(verbatim: action.title), target: .snap(action.rawValue), manager: hotKeys)
            } else {
                Text(verbatim: action.title)
            }
        }
    }
}

extension SnapAction.Group {
    var title: LocalizedStringKey {
        switch self {
        case .halves: "Halves"
        case .quarters: "Quarters"
        case .thirds: "Thirds"
        case .sixths: "Sixths"
        case .maximize: "Fill, Center and Restore"
        case .size: "Size"
        case .move: "Move"
        case .display: "Displays"
        }
    }
}

/// A small screen with the part an action covers filled in, or a symbol for
/// an action that depends on the window.
struct SnapAreaIcon: View {
    let unit: UnitRect?
    let symbol: String

    init(action: SnapAction) {
        unit = SnapGeometry.unitRect(for: action)
        symbol = switch action {
        case .maximizeHeight: "arrow.up.and.down"
        case .center: "dot.square"
        case .larger: "arrow.up.left.and.arrow.down.right"
        case .smaller: "arrow.down.right.and.arrow.up.left"
        case .moveLeft: "arrow.left.to.line"
        case .moveRight: "arrow.right.to.line"
        case .moveUp: "arrow.up.to.line"
        case .moveDown: "arrow.down.to.line"
        case .nextDisplay: "arrow.right.square"
        case .previousDisplay: "arrow.left.square"
        default: "arrow.uturn.backward"
        }
    }

    init(unit: UnitRect?, symbol: String = "exclamationmark.triangle") {
        self.unit = unit
        self.symbol = symbol
    }

    var body: some View {
        Group {
            if let unit {
                GeometryReader { geometry in
                    let inner = CGSize(width: geometry.size.width - 4, height: geometry.size.height - 4)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary, lineWidth: 1)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor)
                            .frame(width: max(2, (unit.x1 - unit.x0) * inner.width), height: max(2, (unit.y1 - unit.y0) * inner.height))
                            .offset(x: 2 + unit.x0 * inner.width, y: 2 + unit.y0 * inner.height)
                    }
                }
            } else {
                Image(systemName: symbol).foregroundStyle(.secondary)
            }
        }
        .frame(width: 26, height: 17)
        .accessibilityHidden(true)
    }
}

// MARK: - Zones

/// A screen with its ten zones: click one, then choose what it does. The
/// part of the screen it gives is shown inside.
struct SnapZonesEditor: View {
    @Binding var zones: [SnapZone: SnapTarget]
    let sizes: [CustomSnapSize]
    @State private var selected: SnapZone = .left

    /// The actions that make sense for a dropped window.
    private static let actions = SnapAction.allCases.filter {
        SnapGeometry.unitRect(for: $0) != nil || $0 == .maximizeHeight || $0 == .center
    }

    private func unit(of target: SnapTarget?) -> UnitRect? {
        switch target {
        case .action(let action): SnapGeometry.unitRect(for: action)
        case .custom(let id): sizes.first { $0.id == id }?.unitRect
        case nil: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            screen
                .frame(width: 320, height: 200)
                .frame(maxWidth: .infinity)
            LabeledContent {
                Picker(selection: Binding(get: { zones[selected] }, set: { zones[selected] = $0 })) {
                    Text("Nothing").tag(SnapTarget?.none)
                    Divider()
                    ForEach(Self.actions, id: \.self) { action in
                        Text(verbatim: action.title).tag(SnapTarget?.some(.action(action)))
                    }
                    if !sizes.isEmpty {
                        Divider()
                        ForEach(sizes) { size in
                            Text(verbatim: size.name).tag(SnapTarget?.some(.custom(size.id)))
                        }
                    }
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            } label: {
                Text(selected.title)
            }
            Text("Click a zone on the screen above to choose what a window dropped there does. A zone at an edge shared with another display stays free, so windows can still be dragged across.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var screen: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                if let unit = unit(of: zones[selected]) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.25))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5))
                        .frame(width: (unit.x1 - unit.x0) * (size.width - 16), height: (unit.y1 - unit.y0) * (size.height - 16))
                        .offset(x: 8 + unit.x0 * (size.width - 16), y: 8 + unit.y0 * (size.height - 16))
                }
                ForEach(SnapZone.allCases, id: \.self) { zone in
                    zoneButton(zone, in: size)
                }
            }
        }
    }

    private func zoneButton(_ zone: SnapZone, in size: CGSize) -> some View {
        let rect = Self.rect(of: zone, in: size)
        let isSelected = zone == selected
        return Button {
            selected = zone
        } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected ? Color.accentColor : Color.secondary.opacity(zones[zone] == nil ? 0.2 : 0.55))
                .frame(width: rect.width, height: rect.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: rect.minX, y: rect.minY)
        .help(Text(zone.title))
        .accessibilityLabel(Text(zone.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Where each zone's handle sits on the drawing.
    private static func rect(of zone: SnapZone, in size: CGSize) -> CGRect {
        let corner: Double = 20, thickness: Double = 9, inset: Double = 3
        let w = size.width, h = size.height
        let edgeLength = h * 0.4, bottomLength = (w - 2 * corner - 4 * inset) / 3
        switch zone {
        case .topLeft: return CGRect(x: inset, y: inset, width: corner, height: corner)
        case .topRight: return CGRect(x: w - inset - corner, y: inset, width: corner, height: corner)
        case .bottomLeft: return CGRect(x: inset, y: h - inset - corner, width: corner, height: corner)
        case .bottomRight: return CGRect(x: w - inset - corner, y: h - inset - corner, width: corner, height: corner)
        case .top: return CGRect(x: w * 0.3, y: inset, width: w * 0.4, height: thickness)
        case .left: return CGRect(x: inset, y: (h - edgeLength) / 2, width: thickness, height: edgeLength)
        case .right: return CGRect(x: w - inset - thickness, y: (h - edgeLength) / 2, width: thickness, height: edgeLength)
        case .bottomLeftThird, .bottomCenterThird, .bottomRightThird:
            let index: Double = zone == .bottomLeftThird ? 0 : zone == .bottomCenterThird ? 1 : 2
            return CGRect(x: inset + corner + inset + index * (bottomLength + inset), y: h - inset - thickness,
                          width: bottomLength, height: thickness)
        }
    }
}

extension SnapZone {
    var title: LocalizedStringKey {
        switch self {
        case .topLeft: "Top left corner"
        case .top: "Top edge"
        case .topRight: "Top right corner"
        case .left: "Left edge"
        case .right: "Right edge"
        case .bottomLeft: "Bottom left corner"
        case .bottomLeftThird: "Bottom edge, left third"
        case .bottomCenterThird: "Bottom edge, middle third"
        case .bottomRightThird: "Bottom edge, right third"
        case .bottomRight: "Bottom right corner"
        }
    }
}

// MARK: - Custom sizes

struct CustomSizesSection: View {
    private let controller = SnapController.shared

    var body: some View {
        Section {
            ForEach(controller.sizes) { size in
                CustomSizeRow(size: size)
            }
            Button("Add a Size") { controller.addSize() }
            Text("In percent of the screen without the menu bar and the Dock, from its top left corner. A size can have a shortcut and be chosen for a zone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Custom Sizes")
        }
    }
}

struct CustomSizeRow: View {
    let size: CustomSnapSize
    @State private var draft: CustomSnapSize

    init(size: CustomSnapSize) {
        self.size = size
        _draft = State(initialValue: size)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SnapAreaIcon(unit: draft.isValid ? draft.unitRect : nil)
                TextField("Name", text: $draft.name)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Button {
                    SnapController.shared.deleteSize(size.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help(Text("Delete"))
            }
            HStack(spacing: 14) {
                percent("X", $draft.x)
                percent("Y", $draft.y)
                percent("Width", $draft.width)
                percent("Height", $draft.height)
            }
            if !draft.isValid {
                Label("Give it a name and keep it on the screen: X plus Width, and Y plus Height, at most 100.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let hotKeys = StatusBarController.shared.hotKeys {
                HotKeyRecorderView(title: "Shortcut", target: .snap(SnapController.key(forSize: size.id)), manager: hotKeys)
            }
        }
        .padding(.vertical, 2)
        .onChange(of: draft) { _, new in SnapController.shared.update(new) }
    }

    private func percent(_ label: LocalizedStringKey, _ value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number.precision(.fractionLength(0...1)))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
            Text(verbatim: "%").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Layouts

struct LayoutsSection: View {
    private let controller = SnapController.shared
    private let permissions = Permissions.shared

    var body: some View {
        Section {
            ForEach(controller.layouts) { layout in
                LayoutRow(layout: layout)
            }
            Button("Save the Windows on Screen as a Layout") { controller.saveLayout() }
                .disabled(!permissions.accessibility)
            Text("A layout keeps where the windows of every open app are. Restoring it puts back the windows of the apps that are open, matched by title; apps that aren't open stay closed.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Layouts")
        }
    }
}

struct LayoutRow: View {
    let layout: WindowLayout
    @State private var name: String

    init(layout: WindowLayout) {
        self.layout = layout
        _name = State(initialValue: layout.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.3.group").foregroundStyle(.secondary)
                TextField("Name", text: $name)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit { SnapController.shared.rename(layout.id, to: name) }
                Spacer()
                Text("Windows: \(layout.windows.count)")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Button("Restore") { SnapController.shared.restore(layout) }
                Menu {
                    Button("Replace with the Windows on Screen") { SnapController.shared.replaceWindows(of: layout.id) }
                    Divider()
                    Button("Delete", role: .destructive) { SnapController.shared.deleteLayout(layout.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let hotKeys = StatusBarController.shared.hotKeys {
                HotKeyRecorderView(title: "Shortcut", target: .snap(SnapController.key(forLayout: layout.id)), manager: hotKeys)
            }
        }
        .padding(.vertical, 2)
        // A name typed and left without Return is kept too.
        .onDisappear { SnapController.shared.rename(layout.id, to: name) }
    }
}
