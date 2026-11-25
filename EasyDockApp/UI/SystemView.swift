import Charts
import EasyDockCore
import SwiftUI

/// A 2-column grid of cards, each combining related metrics (Swap nested
/// under Memory, fan RPMs nested under Temperature) rather than one metric
/// per card, with color-coded progress bars and per-core CPU usage, the same
/// page as SignalBar's System tab. Laid out as `HStack`-paired rows (see
/// `cardPairs`) rather than `LazyVGrid`, so each row's height matches its
/// own tallest card instead of either leaving every short card badly
/// mismatched or forcing one fixed height on every card in the page.
private enum ProcessSortKey {
    case name, status, cpu, memory
}

struct SystemView: View {
    @Bindable private var viewModel = SystemViewModel.shared
    @State private var processSearchText = ""
    @State private var processSortKey: ProcessSortKey = .cpu
    @State private var processSortAscending = false
    @State private var showsAllProcesses = false
    /// The list shows the busiest few until asked for all of them; a Mac
    /// runs 60 or so apps, and listing every one made the page 2,000 pt long.
    @State private var showsEveryRow = false
    /// One column of cards when two would squeeze them, below `twoColumnWidth`.
    @State private var isNarrow = false
    @Environment(\.locale) private var locale

    private var stats: SystemStats { viewModel.current }

    private static let gridSpacing: CGFloat = 18
    private static let outerPadding: CGFloat = 24
    private static let sparklineHeight: CGFloat = 32
    private static let statusColumnWidth: CGFloat = 90
    private static let cpuColumnWidth: CGFloat = 56
    private static let memoryColumnWidth: CGFloat = 150
    private static let twoColumnWidth: CGFloat = 640
    private static let collapsedRowCount = 10
    private static let processesID = "processes"

    private var ramPercent: Double {
        stats.ramTotalMB > 0 ? Double(stats.ramUsedMB) / Double(stats.ramTotalMB) * 100 : 0
    }

    private var swapPercent: Double {
        stats.swapTotalMB > 0 ? Double(stats.swapUsedMB) / Double(stats.swapTotalMB) * 100 : 0
    }

    private var diskPercent: Double {
        stats.diskTotalGB > 0 ? stats.diskUsedGB / stats.diskTotalGB * 100 : 0
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
            }
            // The filter sits in the toolbar but acts on the list at the
            // foot of the page: typing brings the list into view.
            .onChange(of: processSearchText) { old, new in
                if old.isEmpty, !new.isEmpty {
                    withAnimation { proxy.scrollTo(Self.processesID, anchor: .top) }
                }
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width < Self.twoColumnWidth } action: { isNarrow = $0 }
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .toolbar {
            // A real window-toolbar search field (`NativeSearchField`), not
            // one embedded in the card's own body — a `TextField`/
            // `NSSearchField` sitting inside a plain `GroupBox` never gets
            // the Liquid Glass material macOS 26 gives genuine toolbar items,
            // so it looked out of place. Placing it here fixes that by
            // construction: it's the same kind of toolbar item.
            ToolbarItem(placement: .primaryAction) {
                NativeSearchField(text: $processSearchText, placeholder: String(localized: "Filter apps", bundle: AppLocale.bundle))
                    .frame(minWidth: 200)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.hasLoadedOnce {
            VStack(spacing: Self.gridSpacing) {
                if isNarrow {
                    ForEach(Array(cards.enumerated()), id: \.offset) { $0.element }
                } else {
                    ForEach(Array(cardPairs.enumerated()), id: \.offset) { _, pair in
                        HStack(alignment: .top, spacing: Self.gridSpacing) {
                            pair.0
                            // A card left over takes the whole row.
                            if let second = pair.1 { second }
                        }
                    }
                }
                SystemHistoryCard(isCompact: isNarrow)
                processesCard.id(Self.processesID)
            }
            .padding(Self.outerPadding)
        } else {
            skeletonGrid
        }
    }

    /// In pairs that belong together and run about as tall: the load and
    /// the heat it makes, the two kinds of space, the two kinds of battery.
    /// Without a battery or devices, the cards after them move up a place.
    private var cards: [AnyView] {
        var cards: [AnyView] = [AnyView(cpuCard), AnyView(temperatureCard), AnyView(memoryCard), AnyView(diskCard)]
        if let battery = stats.batteryPercent { cards.append(AnyView(batteryCard(percent: battery))) }
        if !stats.peripheralBatteries.isEmpty { cards.append(AnyView(devicesCard)) }
        cards.append(AnyView(networkCard))
        cards.append(AnyView(uptimeCard))
        return cards
    }

    /// Pairs of cards laid out with `HStack`, not `LazyVGrid` — an `HStack`
    /// gives every child the same proposed height (the row's tallest
    /// natural content), so a short card (Storage) and a tall one
    /// (Memory) sharing a row end up visually equal-height *for that row*,
    /// while a different row (e.g. CPU/Temperature, both naturally tall) is
    /// free to be taller overall. `LazyVGrid` never did this — each cell
    /// sized independently — and forcing one fixed height across every card
    /// regardless of row (an earlier attempt) just turned simple cards like
    /// Storage/Uptime into mostly-empty boxes.
    private var cardPairs: [(AnyView, AnyView?)] {
        let cards = self.cards
        var pairs: [(AnyView, AnyView?)] = []
        var index = 0
        while index < cards.count {
            let second = index + 1 < cards.count ? cards[index + 1] : nil
            pairs.append((cards[index], second))
            index += 2
        }
        return pairs
    }

    private var skeletonGrid: some View {
        let placeholder = AnyView(
            card(title: "Loading", systemImage: "circle.dashed", trailingText: "00%") {
                StatBar(percent: 0, color: .blue)
            }
        )
        return VStack(spacing: Self.gridSpacing) {
            ForEach(0..<4, id: \.self) { _ in
                HStack(alignment: .top, spacing: Self.gridSpacing) {
                    placeholder
                    placeholder
                }
            }
            processesCard
        }
        .padding(Self.outerPadding)
        .redacted(reason: .placeholder)
    }

    // MARK: - Cards

    /// The GPU sits here as a second load rather than in a card of its own,
    /// where its one bar left most of the card empty.
    private var cpuCard: some View {
        card(title: "CPU", systemImage: "cpu", trailingText: "\(Int(stats.cpuPercent.rounded()))%") {
            StatBar(percent: stats.cpuPercent, color: barColor(stats.cpuPercent))
            if stats.cpuCores.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Per-core usage").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(stats.cpuTopology.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    // Labelled per core (E1…/P1…) rather than a row of
                    // anonymous bars: on Apple Silicon, "which cores are
                    // busy" is the whole point — background work pinned to
                    // the E-cluster looks very different from a P-core spike.
                    // Columns, as in Activity Monitor: one row for up to 12
                    // cores, more rows of equal length past that.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: coreColumns), spacing: 6) {
                        ForEach(coreSamples, id: \.index) { core in
                            VStack(spacing: 3) {
                                ColumnBar(percent: core.percent, color: barColor(core.percent))
                                Text(core.label)
                                    .font(.system(size: 9))
                                    .monospacedDigit()
                                    .foregroundStyle(core.isEfficiency ? .tertiary : .secondary)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(verbatim: "\(core.label) \(Int(core.percent.rounded()))%"))
                        }
                    }
                }
            }
            sparkline(viewModel.cpuHistory, color: .blue)
            if let gpuName = stats.gpuName {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("GPU")
                        Text(verbatim: gpuName).foregroundStyle(.tertiary).lineLimit(1)
                        Spacer()
                        if let gpuPercent = stats.gpuPercent {
                            Text(verbatim: "\(Int(gpuPercent.rounded()))%").monospacedDigit()
                        } else {
                            Text("Not available")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let gpuPercent = stats.gpuPercent {
                        StatBar(percent: gpuPercent, color: barColor(gpuPercent))
                    }
                }
            }
        }
    }

    private var coreColumns: Int {
        let count = max(stats.cpuCores.count, 1)
        let rows = (count + 11) / 12
        return (count + rows - 1) / rows
    }

    /// Shows one tile per sensor category rather than a single CPU number:
    /// on Apple Silicon `HIDThermalReader` surfaces GPU/battery/board
    /// sensors too, and the hottest one is often not the CPU.
    private var temperatureCard: some View {
        card(
            title: "Temperature",
            systemImage: "thermometer.medium",
            trailingText: stats.cpuTempCelsius.map { "\(Int($0.rounded()))°C" },
            trailingColor: stats.cpuTempCelsius.map(tempColor) ?? .primary
        ) {
            // No bar: degrees have no top to fill towards, and a 42°C bar
            // 42% full said nothing. The state macOS acts on says it instead.
            if !stats.temperatures.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(TemperatureReading.Category.allCases, id: \.self) { category in
                        if let value = stats.temperatures.hottest(category) {
                            temperatureTile(label: categoryLabel(category), celsius: value)
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else if stats.cpuTempCelsius == nil {
                Text("Not available").font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                Circle()
                    .fill(thermalStateColor)
                    .frame(width: 7, height: 7)
                // `Text(_:)` around the label, not the bare `LocalizedStringKey`:
                // interpolating one key into another yields its debug
                // description ("LocalizedStringKey(key: …)") rather than the
                // looked-up string. `Text` interpolation stays localizable.
                Text("Thermal state: \(Text(thermalStateLabel))")
                Spacer()
                if let fans = fansText { fans }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // macOS slows the Mac down from .serious on: say what is heating it.
            if stats.thermalStateRawValue >= ProcessInfo.ThermalState.serious.rawValue {
                let busiest = viewModel.topApps.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(3)
                    .map { "\($0.name) \(Int($0.cpuPercent.rounded()))%" }.joined(separator: ", ")
                Label {
                    Text(busiest.isEmpty ? "macOS is slowing the Mac down to cool it." : "macOS is slowing the Mac down to cool it. Using the most CPU: \(busiest).")
                } icon: {
                    Image(systemName: "thermometer.high")
                }
                .font(.callout)
                .foregroundStyle(.orange)
            }

            if stats.temperatures.count > 1 {
                DisclosureGroup {
                    // Capped at 8: Apple Silicon reports 50+ sensors, and a
                    // card listing all of them would dwarf every other card
                    // on the page. The hottest handful is what's diagnostic.
                    VStack(spacing: 3) {
                        ForEach(stats.temperatures.prefix(8)) { reading in
                            HStack {
                                Text(reading.name).lineLimit(1)
                                Spacer()
                                Text("\(Int(reading.celsius.rounded()))°C")
                                    .monospacedDigit()
                                    .foregroundStyle(tempColor(reading.celsius))
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("\(stats.temperatures.count) sensors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if stats.cpuTempCelsius != nil {
                sparkline(viewModel.tempHistory, color: .orange)
            }
        }
    }

    private func temperatureTile(label: LocalizedStringKey, celsius: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text("\(Int(celsius.rounded()))°C")
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(tempColor(celsius))
        }
    }

    /// "Fans off" when they stand still, rather than "Fan 1 0 RPM", which
    /// read as ten.
    private var fansText: Text? {
        let fans = stats.fanRPMs
        guard !fans.isEmpty else { return nil }
        if fans.allSatisfy({ $0 < 1 }) { return fans.count > 1 ? Text("Fans off") : Text("Fan off") }
        let speeds = fans.map { Int($0.rounded()).formatted(.number.locale(locale)) }.joined(separator: " · ")
        return fans.count > 1 ? Text("Fans \(speeds) RPM") : Text("Fan \(speeds) RPM")
    }

    private var thermalStateColor: Color {
        switch ProcessInfo.ThermalState(rawValue: stats.thermalStateRawValue) {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        default: .secondary
        }
    }

    private func categoryLabel(_ category: TemperatureReading.Category) -> LocalizedStringKey {
        switch category {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .battery: "Battery"
        case .system: "System"
        }
    }

    private var thermalStateLabel: LocalizedStringKey {
        switch ProcessInfo.ThermalState(rawValue: stats.thermalStateRawValue) {
        // "Normal", not Apple's own "Nominal": the Memory card right below
        // labels its healthy state "Normal", and two near-identical words for
        // the same idea in one pane read as a typo. Apple's header defines
        // nominal as "within normal limits", so this is the same meaning in
        // the word the rest of the pane already uses.
        case .nominal: "Normal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        default: "Unknown"
        }
    }

    /// What the used memory is made of, as Activity Monitor splits it, with
    /// the cache beside it: the bar no longer turns yellow on a healthy Mac
    /// that keeps its memory full. Pressure says whether it is short.
    private var memoryCard: some View {
        card(title: "Memory", systemImage: "memorychip", trailingText: ramText) {
            if stats.ramAppMB > 0, stats.ramTotalMB > 0 {
                SegmentedBar(segments: memorySegments.map { (fraction: Double($0.megabytes) / Double(stats.ramTotalMB), color: $0.color) })
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                    ForEach(0..<2) { row in
                        GridRow {
                            ForEach((row * 2)..<(row * 2 + 2), id: \.self) { index in
                                let segment = memorySegments[index]
                                HStack(spacing: 4) {
                                    Circle().fill(segment.color).frame(width: 7, height: 7)
                                    Text(segment.label)
                                    Spacer(minLength: 4)
                                    Text(verbatim: gigabytes(segment.megabytes)).monospacedDigit()
                                }
                            }
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                StatBar(percent: ramPercent, color: memoryBarColor)
            }

            // Memory pressure, not "% used", is what macOS itself acts on —
            // a healthy Mac sits near 100% used because of the file cache.
            HStack(spacing: 4) {
                Circle()
                    .fill(memoryPressureColor)
                    .frame(width: 7, height: 7)
                Text("Pressure: \(Text(memoryPressureLabel))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if stats.swapTotalMB > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Swap").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(swapText).font(.caption).foregroundStyle(.secondary)
                    }
                    StatBar(percent: swapPercent, color: barColor(swapPercent))
                }
            }
        }
    }

    /// One hue in three strengths for the memory in use, so it reads as one
    /// thing in parts, and gray for the cache macOS hands back on demand.
    private var memorySegments: [(label: LocalizedStringKey, megabytes: UInt64, color: Color)] {
        [
            ("App", stats.ramAppMB, .blue),
            ("Wired", stats.ramWiredMB, Self.blueTint(0.4)),
            ("Compressed", stats.ramCompressedMB, Self.blueTint(0.65)),
            ("Cached", min(stats.ramCachedMB, stats.ramTotalMB - min(stats.ramUsedMB, stats.ramTotalMB)), .gray.opacity(0.55)),
        ]
    }

    /// System blue mixed with white: lighter on either appearance, where an
    /// opacity sank into the dark card and two parts became hard to tell apart.
    private static func blueTint(_ whiteFraction: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            var tint = NSColor.systemBlue
            appearance.performAsCurrentDrawingAppearance {
                tint = NSColor.systemBlue.usingColorSpace(.sRGB)?.blended(withFraction: whiteFraction, of: .white) ?? .systemBlue
            }
            return tint
        })
    }

    /// For the plain bar shown when the breakdown can't be read.
    private var memoryBarColor: Color {
        switch stats.memoryPressureLevel {
        case 4: .red
        case 2: .yellow
        default: .blue
        }
    }

    /// Lists every mounted volume when there's more than one — an external
    /// SSD filling up is exactly the kind of thing a monitor should show,
    /// and the boot-volume-only card was blind to it. The bar's color goes by
    /// the space left, not the share used: 77% used with 100 GB free is fine.
    private var diskCard: some View {
        card(title: "Storage", systemImage: "internaldrive", trailingText: diskText) {
            if stats.volumes.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(stats.volumes) { volume in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Label {
                                    Text(volume.name).lineLimit(1)
                                } icon: {
                                    Image(systemName: volume.isInternal ? "internaldrive" : "externaldrive")
                                }
                                Spacer()
                                Text("\(bytesText(volume.usedBytes)) / \(bytesText(volume.totalBytes))")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            StatBar(percent: volume.usedPercent, color: spaceColor(volume.spaceLevel), height: 5)
                        }
                    }
                }
            } else {
                let freeBytes = UInt64(max(stats.diskTotalGB - stats.diskUsedGB, 0) * 1_073_741_824)
                StatBar(percent: diskPercent, color: spaceColor(VolumeUsage.spaceLevel(
                    freeBytes: freeBytes, totalBytes: UInt64(stats.diskTotalGB * 1_073_741_824))))
                Text("\(bytesText(freeBytes)) available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func batteryCard(percent: Double) -> some View {
        card(
            title: "Battery",
            systemImage: stats.batteryCharging == true ? "battery.100.bolt" : "battery.100",
            trailingText: "\(Int(percent.rounded()))%"
        ) {
            StatBar(percent: percent, color: batteryBarColor(percent))
            HStack(spacing: 4) {
                (stats.batteryCharging == true ? Text("Charging") : Text("On battery"))
                if let minutes = stats.batteryHealth?.minutesRemaining {
                    Text(verbatim: "·")
                    (stats.batteryCharging == true
                        ? Text("\(minutesText(minutes)) until full")
                        : Text("\(minutesText(minutes)) remaining"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let health = stats.batteryHealth {
                batteryHealthRows(health)
            }
        }
    }

    /// Mice, keyboards, headphones and the like that report a battery.
    private var devicesCard: some View {
        card(title: "Devices", systemImage: "dot.radiowaves.left.and.right", trailingText: nil) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(stats.peripheralBatteries) { PeripheralBatteryRow(device: $0) }
            }
            .font(.callout)
        }
    }

    /// The same three lines System Information puts under "Health
    /// Information", in its order and wording.
    private func batteryHealthRows(_ health: BatteryHealth) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
            if let capacity = health.maxCapacityPercent {
                GridRow {
                    Text("Maximum Capacity").foregroundStyle(.secondary)
                    Text(verbatim: "\(capacity)%")
                }
            }
            if let cycles = health.cycleCount {
                GridRow {
                    Text("Cycle Count").foregroundStyle(.secondary)
                    Text(verbatim: "\(cycles)")
                }
            }
            GridRow {
                Text("Condition").foregroundStyle(.secondary)
                switch health.condition {
                case .normal: Text("Normal")
                case .serviceRecommended: Text("Service Recommended").foregroundStyle(.orange)
                }
            }
        }
        .font(.caption)
        .padding(.top, 2)
    }

    private func minutesText(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    private var uptimeCard: some View {
        card(title: "Uptime", systemImage: "clock", trailingText: uptimeText) {
            Text("Since \(uptimeSinceText)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var networkCard: some View {
        card(
            title: "Network",
            systemImage: stats.networkConnected ? (stats.networkType == "Wi-Fi" ? "wifi" : "network") : "wifi.slash",
            trailingText: stats.networkConnected ? "Connected" : "Disconnected",
            trailingColor: stats.networkConnected ? .green : .red
        ) {
            if stats.networkConnected {
                VStack(alignment: .leading, spacing: 3) {
                    Text(stats.networkName.map { "\(stats.networkType ?? "Connected") · \($0)" } ?? (stats.networkType ?? "Connected"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let ip = stats.networkLocalIP {
                        Text("Local IP: \(ip)").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Label(formatKbps(stats.networkDownloadKbps), systemImage: "arrow.down")
                        Label(formatKbps(stats.networkUploadKbps), systemImage: "arrow.up")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            } else {
                Text("Not available").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Task-Manager-"Apps"-tab-style list — full width, below the metric
    /// cards. Shows apps (icon + display name via `NSRunningApplication`),
    /// not raw process names — a wall of names like `mds_stores` or
    /// `com.apple.WebKit.Networking` was hard to scan at a glance.
    ///
    /// A hand-drawn column list, not a native `Table` — `Table` on macOS is
    /// always backed by its own `NSScrollView`, so no matter how precisely
    /// its frame was sized to fit every row, it kept reserving/showing its
    /// own scroller, fighting the page's outer `ScrollView` for scroll
    /// events. A plain `VStack` of rows has no scroll machinery of its own
    /// at all, so the page's `ScrollView` is unambiguously the only one.
    /// This also happens to fix Quit/Force Quit for real: `Table`'s
    /// per-cell `.contextMenu` never fired (`NSTableView` intercepts
    /// right-click for row selection first) — a plain view's `.contextMenu`
    /// has no such interception.
    ///
    /// Named "Running Apps" rather than the earlier "Top Apps" — that name
    /// stopped fitting once the hard top-8 cap was removed; this now lists
    /// every running app, not just the busiest few. The first ten in the
    /// chosen order show until "Show All"; a filter shows every match.
    ///
    /// Sort order and the search filter live here (not the view model)
    /// because `viewModel.topApps` is replaced wholesale every 2s refresh —
    /// re-deriving the visible rows from that plus local `@State` on every
    /// render keeps the user's chosen sort/filter stable across refreshes
    /// without any extra "reapply after reload" bookkeeping.
    private var processesCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label {
                        Text(showsAllProcesses ? "All Processes" : "Running Apps")
                            .font(.subheadline.weight(.medium))
                    } icon: {
                        Image(systemName: "chart.bar.fill")
                    }
                    .foregroundStyle(.secondary)

                    Spacer()

                    // The app list hides daemons, so a runaway `mds_stores`
                    // or `kernel_task` was invisible here — this switches to
                    // the raw `libproc` list that already backs it.
                    Picker("", selection: $showsAllProcesses) {
                        Text("Apps").tag(false)
                        Text("All Processes").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                }

                VStack(spacing: 0) {
                    processesHeaderRow
                    Divider()
                    if showsAllProcesses {
                        allProcessRows
                    } else {
                        appRows
                    }
                }

                let total = showsAllProcesses ? filteredSortedProcesses.count : filteredSortedApps.count
                if processSearchText.isEmpty, total > Self.collapsedRowCount {
                    Button {
                        showsEveryRow.toggle()
                    } label: {
                        showsEveryRow ? Text("Show Fewer") : Text("Show All (\(total))")
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    @ViewBuilder
    private var appRows: some View {
        let apps = visibleRows(filteredSortedApps)
        if apps.isEmpty {
            Text("No apps found.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            ForEach(apps) { app in
                processRow(app)
                if app.id != apps.last?.id { Divider() }
            }
        }
    }

    @ViewBuilder
    private var allProcessRows: some View {
        let processes = visibleRows(filteredSortedProcesses)
        if processes.isEmpty {
            Text("No processes found.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            ForEach(processes) { process in
                rawProcessRow(process)
                if process.id != processes.last?.id { Divider() }
            }
        }
    }

    /// The first rows in the chosen order until the list is opened in full;
    /// a filter shows every match.
    private func visibleRows<Row>(_ rows: [Row]) -> [Row] {
        showsEveryRow || !processSearchText.isEmpty ? rows : Array(rows.prefix(Self.collapsedRowCount))
    }

    /// No icon, and "pid N" in place of the Status column. Quit and Force
    /// Quit ask first and only reach the user's own processes: macOS refuses
    /// a signal to one owned by root or another user, and `loginwindow` and
    /// EasyDock itself are left out, since ending the first logs the user out.
    private func rawProcessRow(_ process: ProcessUsage) -> some View {
        HStack(spacing: 8) {
            Text(process.name)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("pid \(process.pid)")
                .foregroundStyle(.secondary)
                .frame(width: Self.statusColumnWidth, alignment: .leading)
            Text("\(process.cpuPercent, specifier: "%.1f")%")
                .frame(width: Self.cpuColumnWidth, alignment: .trailing)
            Text("\(process.memoryMB, specifier: "%.0f") MB")
                .frame(width: Self.memoryColumnWidth, alignment: .trailing)
        }
        .font(.callout)
        .monospacedDigit()
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            let protected = process.pid <= 1 || process.pid == getpid() || process.name == "loginwindow"
            Button("Quit…") { confirmSignal(SIGTERM, to: process) }.disabled(protected)
            Button("Force Quit…", role: .destructive) { confirmSignal(SIGKILL, to: process) }.disabled(protected)
        }
    }

    /// The running application itself is kept, not its pid, so the answer
    /// reaches the app that was asked about even if it has quit meanwhile.
    private func confirmQuit(_ app: AppUsage, force: Bool) {
        let bundle = AppLocale.bundle
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = force
            ? String(localized: "Force quit “\(app.name)”?", bundle: bundle)
            : String(localized: "Quit “\(app.name)”?", bundle: bundle)
        alert.informativeText = force
            ? String(localized: "It stops at once, and anything it hasn't saved is lost.", bundle: bundle)
            : String(localized: "It is asked to quit, and may save its work first.", bundle: bundle)
        alert.addButton(withTitle: force ? String(localized: "Force Quit", bundle: bundle) : String(localized: "Quit", bundle: bundle))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: bundle))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        force ? app.runningApplication.forceTerminate() : app.runningApplication.terminate()
    }

    private func confirmSignal(_ signal: Int32, to process: ProcessUsage) {
        guard process.pid > 1, process.pid != getpid(), process.name != "loginwindow" else { return }
        // Which process this is, read before asking: the row can be two
        // seconds old, and the user can take their time to answer.
        // A different name means the pid already belongs to another process.
        let started = ProcessListService.processName(for: process.pid) == process.name
            ? ProcessListService.startTime(of: process.pid) : nil
        let alert = NSAlert()
        // Signal 0 only asks whether a signal would be allowed.
        guard kill(process.pid, 0) == 0 else {
            alert.messageText = String(localized: "“\(process.name)” can't be quit from EasyDock", bundle: AppLocale.bundle)
            alert.informativeText = String(localized: "It belongs to macOS or to another user.", bundle: AppLocale.bundle)
            alert.runModal()
            return
        }
        alert.alertStyle = .warning
        alert.messageText = signal == SIGKILL
            ? String(localized: "Force quit “\(process.name)” (pid \(process.pid))?", bundle: AppLocale.bundle)
            : String(localized: "Quit “\(process.name)” (pid \(process.pid))?", bundle: AppLocale.bundle)
        alert.informativeText = signal == SIGKILL
            ? String(localized: "It stops at once, and anything it hasn't saved is lost.", bundle: AppLocale.bundle)
            : String(localized: "It is asked to quit, and may save its work first.", bundle: AppLocale.bundle)
        alert.addButton(withTitle: signal == SIGKILL ? String(localized: "Force Quit", bundle: AppLocale.bundle) : String(localized: "Quit", bundle: AppLocale.bundle))
        alert.addButton(withTitle: String(localized: "Cancel", bundle: AppLocale.bundle))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Gone, or its pid already given to another process: nothing is sent.
        guard let started, ProcessListService.startTime(of: process.pid) == started else { return }
        kill(process.pid, signal)
    }

    private var filteredSortedProcesses: [ProcessUsage] {
        let filtered = processSearchText.isEmpty
            ? viewModel.allProcesses
            : viewModel.allProcesses.filter { $0.name.localizedCaseInsensitiveContains(processSearchText) }
        return filtered.sorted { a, b in
            let ascending: Bool
            switch processSortKey {
            case .name: ascending = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .status: ascending = a.pid < b.pid
            case .cpu: ascending = a.cpuPercent < b.cpuPercent
            case .memory: ascending = a.memoryMB < b.memoryMB
            }
            return processSortAscending ? ascending : !ascending
        }
    }

    private var processesHeaderRow: some View {
        HStack(spacing: 8) {
            processSortButton(showsAllProcesses ? "Process" : "App", key: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            processSortButton(showsAllProcesses ? "PID" : "Status", key: .status)
                .frame(width: Self.statusColumnWidth, alignment: .leading)
            processSortButton("CPU", key: .cpu)
                .frame(width: Self.cpuColumnWidth, alignment: .trailing)
            processSortButton("Memory", key: .memory)
                .frame(width: Self.memoryColumnWidth, alignment: .trailing)
        }
        .padding(.bottom, 4)
    }

    private func processSortButton(_ title: LocalizedStringKey, key: ProcessSortKey) -> some View {
        Button {
            if processSortKey == key {
                processSortAscending.toggle()
            } else {
                processSortKey = key
                processSortAscending = false
            }
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if processSortKey == key {
                    Image(systemName: processSortAscending ? "chevron.up" : "chevron.down")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private func processRow(_ app: AppUsage) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(app.name).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(app.status.label)
                .foregroundStyle(.secondary)
                .frame(width: Self.statusColumnWidth, alignment: .leading)
            Text("\(app.cpuPercent, specifier: "%.1f")%")
                .frame(width: Self.cpuColumnWidth, alignment: .trailing)
            Text("\(app.memoryMB, specifier: "%.0f") MB (\(app.memoryPercent, specifier: "%.1f")%)")
                .frame(width: Self.memoryColumnWidth, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 4)
        .contextMenu {
            Button("Quit…") { confirmQuit(app, force: false) }
            Button("Force Quit…", role: .destructive) { confirmQuit(app, force: true) }
        }
    }

    private var filteredSortedApps: [AppUsage] {
        let filtered = processSearchText.isEmpty
            ? viewModel.topApps
            : viewModel.topApps.filter { $0.name.localizedCaseInsensitiveContains(processSearchText) }
        return filtered.sorted { a, b in
            let ascending: Bool
            switch processSortKey {
            case .name: ascending = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .status: ascending = a.status.rawValue < b.status.rawValue
            case .cpu: ascending = a.cpuPercent < b.cpuPercent
            case .memory: ascending = a.memoryMB < b.memoryMB
            }
            return processSortAscending ? ascending : !ascending
        }
    }

    // MARK: - Formatting

    /// Per-core percentages zipped with the topology's labels. Guards on
    /// count: a core-count change mid-session (or a topology sysctl that
    /// disagreed with `host_processor_info`) would otherwise mislabel every
    /// bar, so it falls back to bare indices rather than lying.
    private var coreSamples: [(index: Int, label: String, percent: Double, isEfficiency: Bool)] {
        let labels = stats.cpuTopology.coreLabels()
        let levels = stats.cpuTopology.coreLevels()
        let slowestLevelIndex = stats.cpuTopology.levels.map(\.index).max()
        return stats.cpuCores.enumerated().map { index, percent in
            let matches = labels.count == stats.cpuCores.count
            return (
                index: index,
                label: matches ? labels[index] : "\(index + 1)",
                percent: percent,
                isEfficiency: matches && stats.cpuTopology.hasClusters && levels[index].index == slowestLevelIndex
            )
        }
    }

    private var memoryPressureLabel: LocalizedStringKey {
        switch stats.memoryPressureLevel {
        case 4: "Critical"
        case 2: "Warning"
        default: "Normal"
        }
    }

    private var memoryPressureColor: Color {
        switch stats.memoryPressureLevel {
        case 4: .red
        case 2: .yellow
        default: .green
        }
    }

    /// In the app's language, as the list's "0,5%" already was: `String(format:)`
    /// always wrote "13.8 GB", so Vietnamese mixed two decimal marks.
    private func decimal(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).locale(locale))
    }

    private func gigabytes(_ megabytes: UInt64) -> String {
        megabytes >= 1024
            ? "\(decimal(Double(megabytes) / 1024, digits: 1)) GB"
            : "\(megabytes) MB"
    }

    private func bytesText(_ bytes: UInt64) -> String {
        "\(decimal(Double(bytes) / 1_073_741_824, digits: 0)) GB"
    }

    private var ramText: String {
        "\(decimal(Double(stats.ramUsedMB) / 1024, digits: 1)) / \(decimal(Double(stats.ramTotalMB) / 1024, digits: 1)) GB"
    }

    private var swapText: String {
        "\(decimal(Double(stats.swapUsedMB) / 1024, digits: 1)) / \(decimal(Double(stats.swapTotalMB) / 1024, digits: 1)) GB"
    }

    private var diskText: String {
        "\(decimal(stats.diskUsedGB, digits: 0)) / \(decimal(stats.diskTotalGB, digits: 0)) GB"
    }

    private var uptimeText: String {
        let secs = stats.uptimeSecs
        let days = secs / 86400
        let hours = (secs % 86400) / 3600
        let minutes = (secs % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Boot time derived from uptime, since the stats provider only reports the duration.
    private var uptimeSinceText: String {
        Date().addingTimeInterval(-Double(stats.uptimeSecs)).formatted(date: .abbreviated, time: .shortened)
    }

    private func formatKbps(_ kbps: Double) -> String {
        kbps >= 1024 ? "\(decimal(kbps / 1024, digits: 1)) MB/s" : "\(decimal(kbps, digits: 0)) KB/s"
    }

    private func barColor(_ percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .yellow }
        return .blue
    }

    /// Apple's own thermal throttling starts well above 90°C — 70/85 flags
    /// "running hot" early enough to be a useful heads-up in a monitoring UI.
    private func tempColor(_ celsius: Double) -> Color {
        if celsius >= 85 { return .red }
        if celsius >= 70 { return .yellow }
        return .primary
    }

    private func spaceColor(_ level: VolumeUsage.SpaceLevel) -> Color {
        switch level {
        case .plenty: .blue
        case .low: .yellow
        case .critical: .red
        }
    }

    /// Inverse of `barColor`: for a battery a HIGH percentage is good, so
    /// "danger at the top end" would be backwards.
    private func batteryBarColor(_ percent: Double) -> Color {
        if percent <= 20 { return .red }
        if percent <= 40 { return .yellow }
        return .blue
    }

    @ViewBuilder
    private func sparkline(_ data: [Double], color: Color) -> some View {
        if data.count > 1 {
            // On a fixed 0–100 scale (more for a reading above it), so a
            // move from 15% to 20% stays small; scaled to its own range it
            // filled the height. Monotone: Catmull-Rom curves overshoot
            // between samples and drew peaks that were never measured.
            Chart(Array(data.enumerated()), id: \.offset) { sample in
                AreaMark(x: .value("Tick", sample.offset), y: .value("Value", sample.element))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.25), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Tick", sample.offset), y: .value("Value", sample.element))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(color)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0...max(100, data.max() ?? 0))
            .frame(height: Self.sparklineHeight)
            // Purely decorative trend view - the card's trailingText already
            // announces the current numeric value, and `Chart` has no
            // meaningful default accessibility representation of its own
            // (VoiceOver would otherwise stop on an unlabeled element here).
            .accessibilityHidden(true)
        }
    }

    /// `GroupBox` with no `label:` (rather than the built-in label slot used
    /// elsewhere) — the icon/title/value header here is one row inside the
    /// content, matching the old app's card layout, while still getting
    /// `GroupBox`'s automatic system material (Liquid Glass on macOS 26+)
    /// instead of a hand-drawn background.
    @ViewBuilder
    private func card<Content: View>(
        title: LocalizedStringKey,
        systemImage: String,
        trailingText: String?,
        trailingColor: Color = .primary,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label {
                        Text(title).font(.subheadline.weight(.medium))
                    } icon: {
                        Image(systemName: systemImage)
                    }
                    .foregroundStyle(.secondary)
                    Spacer()
                    if let trailingText {
                        Text(trailingText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(trailingColor)
                    }
                }
                content()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(10)
        }
        // Applied to the whole `GroupBox`, not just its inner content: an
        // `HStack` row proposes the same height to every child (the row's
        // tallest natural content), and only a view that explicitly accepts
        // `maxHeight: .infinity` at its outermost level actually stretches
        // its drawn background to fill that proposal — the `Spacer` above
        // then absorbs the extra space so a short card's header still sits
        // at the top instead of centered in the taller row.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Thin horizontal progress bar with a color that's chosen by the caller
/// (green/blue "normal" vs. yellow/red thresholds), replacing the plain
/// `Chart`-based sparkline-only cards from the previous design.
private struct StatBar: View {
    let percent: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color)
                    .frame(width: geo.size.width * CGFloat(min(max(percent, 0), 100)) / 100)
            }
        }
        .frame(height: height)
    }
}

/// `StatBar` standing up, for the per-core columns.
private struct ColumnBar: View {
    let percent: Double
    let color: Color

    var body: some View {
        // Filled inside the track's shape rather than drawn as a capsule of
        // its own, which at a low reading came out as a round dot.
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Rectangle().fill(.quaternary)
                Rectangle().fill(color)
                    .frame(height: geo.size.height * CGFloat(min(max(percent, 0), 100)) / 100)
            }
        }
        .frame(maxWidth: 10)
        .frame(height: 28)
        .clipShape(Capsule())
    }
}

/// `StatBar` in parts, each a share of the whole, with a 2 pt gap between
/// them; what is left over shows as the empty track.
private struct SegmentedBar: View {
    let segments: [(fraction: Double, color: Color)]
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let shown = segments.filter { $0.fraction > 0 }
            let width = max(geo.size.width - CGFloat(shown.count) * 2, 0)
            HStack(spacing: 2) {
                ForEach(shown.indices, id: \.self) { index in
                    Rectangle()
                        .fill(shown[index].color)
                        .frame(width: width * CGFloat(min(shown[index].fraction, 1)))
                }
                Rectangle().fill(.quaternary)
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
    }
}
