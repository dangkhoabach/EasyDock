import Charts
import EasyDockCore
import SwiftUI

/// CPU, memory and temperature over the last hour or day, from the samples
/// the scheduler records once a minute whether or not this tab is open.
struct SystemHistoryCard: View {
    private enum Span: Hashable {
        case hour, day

        var seconds: TimeInterval { self == .hour ? 3600 : SystemHistoryStore.keptFor }
    }

    @State private var span: Span = .hour
    @State private var samples: [SystemSample] = []
    @State private var end = Date()
    /// Where the pointer is over any of the three charts; all three show it.
    @State private var hovered: Date?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label {
                        Text("History").font(.subheadline.weight(.medium))
                    } icon: {
                        Image(systemName: "chart.xyaxis.line")
                    }
                    .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $span) {
                        Text("1 Hour").tag(Span.hour)
                        Text("24 Hours").tag(Span.day)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                if samples.isEmpty {
                    Text("The history fills in while EasyDock runs, one point a minute.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    HStack(alignment: .top, spacing: 18) {
                        chart("CPU", unit: "%", color: .blue, fixedTop: 100) { $0.cpuPercent }
                        chart("Memory", unit: "%", color: .green, fixedTop: 100) { $0.memoryPercent }
                        if samples.contains(where: { $0.temperatureCelsius != nil }) {
                            chart("Temperature", unit: "°C", color: .orange, fixedTop: nil) { $0.temperatureCelsius }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        // A new point lands once a minute; reading it back is one small query.
        .task(id: span) {
            while !Task.isCancelled {
                load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func load() {
        end = Date()
        guard let database = AppDatabase.shared else { return }
        samples = (try? SystemHistoryStore(dbQueue: database.dbQueue).samples(since: end - span.seconds)) ?? []
    }

    private func chart(
        _ title: LocalizedStringKey,
        unit: String,
        color: Color,
        fixedTop: Double?,
        value: @escaping (SystemSample) -> Double?
    ) -> some View {
        let runs = SystemHistoryStore.runs(samples.filter { value($0) != nil })
        let shown = hovered.flatMap { time in samples.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) } }
        let reading = shown.flatMap(value) ?? samples.last.flatMap(value)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let reading {
                    Text(verbatim: "\(Int(reading.rounded()))\(unit)").font(.callout.weight(.semibold)).monospacedDigit()
                }
                if let shown {
                    Text(shown.time, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                }
            }
            Chart {
                ForEach(Array(runs.enumerated()), id: \.offset) { index, run in
                    ForEach(run, id: \.time) { sample in
                        LineMark(x: .value("Time", sample.time), y: .value(unit, value(sample) ?? 0), series: .value("Run", index))
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                if let shown {
                    RuleMark(x: .value("Time", shown.time)).foregroundStyle(.secondary.opacity(0.5))
                }
            }
            .foregroundStyle(color)
            .chartXScale(domain: (end - span.seconds)...end)
            .chartYScale(domain: 0...(fixedTop ?? max(samples.compactMap(value).max() ?? 0, 1) * 1.1))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel()
                }
            }
            .chartXSelection(value: $hovered)
            .frame(height: 110)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
            .accessibilityValue(summary(of: samples.compactMap(value), unit: unit))
        }
        .frame(maxWidth: .infinity)
    }

    /// What VoiceOver reads for a chart: the latest value and the range.
    private func summary(of values: [Double], unit: String) -> Text {
        guard let last = values.last, let low = values.min(), let high = values.max() else { return Text("No data") }
        return Text("Now \(Int(last.rounded()))\(unit), lowest \(Int(low.rounded()))\(unit), highest \(Int(high.rounded()))\(unit)")
    }
}
