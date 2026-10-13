import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var app
    @State private var showsTable = false

    var body: some View {
        let range = app.settings.dashboardRange
        ScrollView {
            HistorySeriesReader(range: range) { series in
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Presentation", selection: $showsTable) {
                        Text("Charts").tag(false)
                        Text("Table").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Show history as charts or as a table")

                    if showsTable {
                        HistoryTableCard(series: series)
                    } else {
                        charts(series)
                    }
                    HistoryFootnote(series: series)
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder
    private func charts(_ series: HistorySeries) -> some View {
        DashboardCard("Memory usage", subtitle: "App, Wired, Compressed, and Reserved, stacked; the top line is estimated use") {
            MemoryUsageChart(series: series, style: .full)
                .frame(height: 220)
            HStack(spacing: 14) {
                LegendItem(title: "App", color: Palette.app)
                LegendItem(title: "Wired", color: Palette.wired)
                LegendItem(title: "Compressed", color: Palette.compressed)
                LegendItem(title: "Reserved", color: Palette.reserved)
                if !series.gaps.isEmpty {
                    LegendItem(title: "No data", color: Color.secondary.opacity(0.25))
                }
            }
        }

        DashboardCard("Memory pressure", subtitle: "Share of samples at each level macOS reported") {
            PressureTimeline(series: series)
                .frame(height: 22)
            HStack(spacing: 14) {
                LegendItem(title: "Normal", color: Palette.good.opacity(0.45))
                LegendItem(title: "Warning", color: Palette.warning)
                LegendItem(title: "Critical", color: Palette.critical)
            }
        }

        AdaptiveRow(threshold: 760) {
            compressionCard(series)
            swapCard(series)
        }

        DashboardCard("Swap activity", subtitle: "Data written to swap per second (measured)") {
            SwapActivityChart(series: series)
                .frame(height: 110)
        }
    }

    private func compressionCard(_ series: HistorySeries) -> some View {
        DashboardCard("Compressed memory", subtitle: "Memory occupied vs. the data it holds") {
            CompressionChart(series: series)
                .frame(height: 160)
            HStack(spacing: 14) {
                LegendItem(title: "Occupied", color: Palette.compressed, shape: .line)
                LegendItem(title: "Data stored", color: .secondary, shape: .line)
            }
        }
    }

    private func swapCard(_ series: HistorySeries) -> some View {
        DashboardCard("Swap", subtitle: "Used vs. allocated swap files") {
            SwapChart(series: series)
                .frame(height: 160)
            HStack(spacing: 14) {
                LegendItem(title: "Used", color: Palette.swap, shape: .line)
                LegendItem(title: "Allocated", color: .secondary, shape: .line)
            }
        }
    }
}

private struct HistoryFootnote: View {
    var series: HistorySeries

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if series.resolution > 0 {
                Text("Each point averages \(MemoryFormatter.duration(series.resolution)) of samples; peaks are kept in the table.")
            } else {
                Text("Each point is an individual sample.")
            }
            if !series.gaps.isEmpty {
                Text("Shaded bands mark periods with no data (sleep, pauses, or while RamLume wasn't running). Nothing is drawn for them.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// The table twin of the charts: every plotted value, readable without hovering.
private struct HistoryTableCard: View {
    var series: HistorySeries

    struct Row: Identifiable {
        var id: Int
        var time: String
        var used: String
        var peak: String
        var app: String
        var wired: String
        var compressed: String
        var swap: String
        var swapWritten: String
        var pressure: String
        var elevated: String
    }

    var body: some View {
        let rows = series.points.reversed().map { item -> Row in
            let p = item.point
            return Row(
                id: item.id,
                time: ChartFormatting.tooltipTime(for: p),
                used: MemoryFormatter.string(fromBytes: p.used),
                peak: MemoryFormatter.string(fromBytes: p.usedPeak),
                app: MemoryFormatter.string(fromBytes: p.app),
                wired: MemoryFormatter.string(fromBytes: p.wired),
                compressed: MemoryFormatter.string(fromBytes: p.compressed),
                swap: p.swapUsed.map { MemoryFormatter.string(fromBytes: $0) } ?? "—",
                swapWritten: p.activity.map { MemoryFormatter.string(fromBytes: $0.swapOutBytes, style: .compact) } ?? "—",
                pressure: p.worstPressure?.displayName ?? "—",
                elevated: p.pressureShares.map { MemoryFormatter.share($0.warning + $0.critical) } ?? "—"
            )
        }
        DashboardCard("History table", subtitle: "\(rows.count) points, newest first") {
            Table(rows) {
                TableColumn("Time", value: \.time)
                TableColumn("Used ≈", value: \.used)
                TableColumn("Peak ≈", value: \.peak)
                TableColumn("App", value: \.app)
                TableColumn("Wired", value: \.wired)
                TableColumn("Compressed", value: \.compressed)
                TableColumn("Swap used", value: \.swap)
                TableColumn("Swap written", value: \.swapWritten)
                TableColumn("Worst pressure", value: \.pressure)
                TableColumn("Elevated", value: \.elevated)
            }
            .frame(minHeight: 360)
            .monospacedDigit()
        }
    }
}
