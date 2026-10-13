import Charts
import SwiftUI

// All history charts plot only recorded points. A new line segment starts after every gap,
// and recorded gaps (sleep, pauses, time RamLume wasn't running) are drawn as quiet bands.
// Hover crosshairs live in `ChartCrosshair` overlays so pointer movement never re-renders marks.

private let lineWidth: CGFloat = 2
private let washOpacity = 0.12
private let gapFill = Color.secondary.opacity(0.09)

private func roundedLine(_ width: CGFloat = lineWidth) -> StrokeStyle {
    StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
}

private func gapTooltip(_ gap: HistoryGap) -> ChartTooltip {
    ChartTooltip(
        title: "\(gap.start.formatted(.dateTime.hour().minute()))–\(gap.end.formatted(.dateTime.hour().minute()))",
        rows: [],
        footnote: "No data: \(gap.reason.displayName)"
    )
}

/// Standard time axis for a range.
private func timeAxis(_ range: ChartRange) -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
        AxisValueLabel(format: ChartFormatting.timeFormat(for: range))
    }
}

/// Byte axis with clean ticks.
private func byteAxis(maximum: Double) -> some AxisContent {
    AxisMarks(position: .leading, values: ChartFormatting.byteTicks(maximum: maximum)) { value in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
        AxisValueLabel {
            if let bytes = value.as(Double.self) { Text(ChartFormatting.axisLabel(bytes: bytes)) }
        }
    }
}

private struct GapBands: ChartContent {
    var gaps: [HistoryGap]

    var body: some ChartContent {
        ForEach(Array(gaps.enumerated()), id: \.offset) { _, gap in
            RectangleMark(xStart: .value("Gap start", gap.start), xEnd: .value("Gap end", gap.end))
                .foregroundStyle(gapFill)
        }
    }
}

// MARK: - Memory usage (stacked App / Wired / Compressed)

struct MemoryUsageChart: View {
    enum Style {
        /// Single "used" series, no axes. For the menu bar panel.
        case compact
        /// Stacked composition with axes. For the dashboard.
        case full
    }

    var series: HistorySeries
    var style: Style = .full

    var body: some View {
        let total = Double(series.totalMemory ?? 0)
        Chart {
            // At panel size the broken line already shows missing data; bands would only add noise.
            if style == .full {
                GapBands(gaps: series.gaps)
            }
            switch style {
            case .compact: compactMarks
            case .full: stackedMarks
            }
        }
        .chartXScale(domain: series.domain)
        .chartYScale(domain: 0...max(total, 1))
        .chartLegend(.hidden)
        .chartXAxis {
            if style == .full { timeAxis(series.range) }
        }
        .chartYAxis {
            if style == .full { byteAxis(maximum: total) }
        }
        .chartOverlay { proxy in
            ChartCrosshair(
                proxy: proxy,
                dates: series.points.map(\.date),
                gaps: series.gaps,
                markerValue: { series.points[$0].point.used },
                markerColor: style == .compact ? Palette.app : Palette.compressed
            ) { target in
                switch target {
                case .point(let index):
                    ChartTooltip(title: ChartFormatting.tooltipTime(for: series.points[index].point), rows: tooltipRows(series.points[index].point))
                case .gap(let gap):
                    gapTooltip(gap)
                }
            }
        }
        .overlay {
            if series.isEmpty { ChartPlaceholder(message: "Collecting data…") }
        }
        .accessibilityLabel("Memory usage, \(series.range.accessibilityTitle)")
    }

    @ChartContentBuilder
    private var compactMarks: some ChartContent {
        ForEach(series.points) { item in
            AreaMark(
                x: .value("Time", item.date),
                yStart: .value("Bytes", 0),
                yEnd: .value("Used", item.point.used),
                series: .value("Layer", "used-\(item.segment)")
            )
            .foregroundStyle(Palette.app.opacity(washOpacity + 0.04))
            .interpolationMethod(.monotone)
            LineMark(x: .value("Time", item.date), y: .value("Used", item.point.used), series: .value("Line", "used-line-\(item.segment)"))
                .foregroundStyle(Palette.app)
                .lineStyle(roundedLine(1.5))
                .interpolationMethod(.monotone)
        }
    }

    @ChartContentBuilder
    private var stackedMarks: some ChartContent {
        ForEach(series.points) { item in
            let p = item.point
            AreaMark(x: .value("Time", item.date), yStart: .value("Bytes", 0), yEnd: .value("App", p.app), series: .value("Layer", "app-\(item.segment)"))
                .foregroundStyle(Palette.app.opacity(washOpacity + 0.06))
                .interpolationMethod(.monotone)
            AreaMark(x: .value("Time", item.date), yStart: .value("Bytes", p.app), yEnd: .value("Wired", p.app + p.wired), series: .value("Layer", "wired-\(item.segment)"))
                .foregroundStyle(Palette.wired.opacity(washOpacity + 0.06))
                .interpolationMethod(.monotone)
            AreaMark(x: .value("Time", item.date), yStart: .value("Bytes", p.app + p.wired), yEnd: .value("Compressed", p.app + p.wired + p.compressed), series: .value("Layer", "compressed-\(item.segment)"))
                .foregroundStyle(Palette.compressed.opacity(washOpacity + 0.06))
                .interpolationMethod(.monotone)
            // Reserved and unaccounted memory: the rest of "used".
            AreaMark(x: .value("Time", item.date), yStart: .value("Bytes", p.app + p.wired + p.compressed), yEnd: .value("Used", max(p.used, p.app + p.wired + p.compressed)), series: .value("Layer", "reserved-\(item.segment)"))
                .foregroundStyle(Palette.reserved.opacity(0.35))
                .interpolationMethod(.monotone)
        }
        ForEach(series.points) { item in
            let p = item.point
            LineMark(x: .value("Time", item.date), y: .value("App", p.app), series: .value("Line", "app-line-\(item.segment)"))
                .foregroundStyle(Palette.app)
                .lineStyle(roundedLine())
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", item.date), y: .value("Wired", p.app + p.wired), series: .value("Line", "wired-line-\(item.segment)"))
                .foregroundStyle(Palette.wired)
                .lineStyle(roundedLine())
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", item.date), y: .value("Compressed", p.app + p.wired + p.compressed), series: .value("Line", "compressed-line-\(item.segment)"))
                .foregroundStyle(Palette.compressed)
                .lineStyle(roundedLine())
                .interpolationMethod(.monotone)
        }
    }

    private func tooltipRows(_ point: HistoryPoint) -> [ChartTooltip.Row] {
        let total = MemoryFormatter.string(fromBytes: point.total, style: .compact)
        var rows = [ChartTooltip.Row(label: "used of \(total)", value: MemoryFormatter.string(fromBytes: point.used), color: style == .compact ? Palette.app : nil)]
        if style == .full {
            rows.append(.init(label: "Compressed", value: MemoryFormatter.string(fromBytes: point.compressed), color: Palette.compressed))
            rows.append(.init(label: "Wired", value: MemoryFormatter.string(fromBytes: point.wired), color: Palette.wired))
            rows.append(.init(label: "App", value: MemoryFormatter.string(fromBytes: point.app), color: Palette.app))
            if let level = point.worstPressure {
                if point.sampleCount > 1 {
                    // A bucket's worst level alone would overstate one brief warning.
                    rows.append(.init(label: "worst pressure", value: level.displayName, color: nil))
                    if level.isElevated, let shares = point.pressureShares {
                        rows.append(.init(label: "elevated", value: "\(MemoryFormatter.share(shares.warning + shares.critical)) of samples", color: nil))
                    }
                } else {
                    rows.append(.init(label: "pressure", value: level.displayName, color: nil))
                }
            }
        }
        return rows
    }
}

// MARK: - Compression

struct CompressionChart: View {
    var series: HistorySeries

    var body: some View {
        let maximum = max(series.peak { $0.compressedOriginal }, series.peak { $0.compressed }, Double(MemoryUnits.gibibyte) / 4)
        Chart {
            GapBands(gaps: series.gaps)
            ForEach(series.points) { item in
                AreaMark(x: .value("Time", item.date), yStart: .value("Bytes", 0), yEnd: .value("Occupied", item.point.compressed), series: .value("Layer", "occupied-\(item.segment)"))
                    .foregroundStyle(Palette.compressed.opacity(washOpacity))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", item.date), y: .value("Occupied", item.point.compressed), series: .value("Line", "occupied-\(item.segment)"))
                    .foregroundStyle(Palette.compressed)
                    .lineStyle(roundedLine())
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", item.date), y: .value("Stored", item.point.compressedOriginal), series: .value("Line", "stored-\(item.segment)"))
                    .foregroundStyle(Color.secondary)
                    .lineStyle(roundedLine(1.5))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: series.domain)
        .chartYScale(domain: 0...maximum)
        .chartXAxis { timeAxis(series.range) }
        .chartYAxis { byteAxis(maximum: maximum) }
        .chartOverlay { proxy in
            ChartCrosshair(
                proxy: proxy,
                dates: series.points.map(\.date),
                gaps: series.gaps,
                markerValue: { series.points[$0].point.compressed },
                markerColor: Palette.compressed
            ) { target in
                switch target {
                case .point(let index):
                    let point = series.points[index].point
                    ChartTooltip(title: ChartFormatting.tooltipTime(for: point), rows: [
                        .init(label: "occupied", value: MemoryFormatter.string(fromBytes: point.compressed), color: Palette.compressed),
                        .init(label: "of data stored", value: MemoryFormatter.string(fromBytes: point.compressedOriginal), color: .secondary),
                    ])
                case .gap(let gap):
                    gapTooltip(gap)
                }
            }
        }
        .overlay {
            if series.isEmpty { ChartPlaceholder(message: "Collecting data…") }
        }
        .accessibilityLabel("Compressed memory, \(series.range.accessibilityTitle)")
    }
}

// MARK: - Swap

struct SwapChart: View {
    var series: HistorySeries

    var body: some View {
        let swapPoints = series.points.filter { $0.point.swapUsed != nil }
        let maximum = Self.yMaximum(for: series)
        Chart {
            GapBands(gaps: series.gaps)
            ForEach(swapPoints) { item in
                let used = item.point.swapUsed ?? 0
                AreaMark(x: .value("Time", item.date), yStart: .value("Bytes", 0), yEnd: .value("Swap used", used), series: .value("Layer", "swap-\(item.segment)"))
                    .foregroundStyle(Palette.swap.opacity(washOpacity))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", item.date), y: .value("Swap used", used), series: .value("Line", "swap-\(item.segment)"))
                    .foregroundStyle(Palette.swap)
                    .lineStyle(roundedLine())
                    .interpolationMethod(.monotone)
                if let allocated = item.point.swapTotal {
                    LineMark(x: .value("Time", item.date), y: .value("Allocated", Double(allocated)), series: .value("Line", "allocated-\(item.segment)"))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(roundedLine(1.5))
                        .interpolationMethod(.stepEnd)
                }
            }
        }
        .chartXScale(domain: series.domain)
        .chartYScale(domain: 0...maximum)
        .chartXAxis { timeAxis(series.range) }
        .chartYAxis { byteAxis(maximum: maximum) }
        .chartOverlay { proxy in
            ChartCrosshair(
                proxy: proxy,
                dates: swapPoints.map(\.date),
                gaps: series.gaps,
                markerValue: { swapPoints[$0].point.swapUsed },
                markerColor: Palette.swap
            ) { target in
                switch target {
                case .point(let index):
                    let point = swapPoints[index].point
                    ChartTooltip(title: ChartFormatting.tooltipTime(for: point), rows: [
                        .init(label: "swap used", value: point.swapUsed.map { MemoryFormatter.string(fromBytes: $0) } ?? "—", color: Palette.swap),
                        .init(label: "allocated", value: point.swapTotal.map { MemoryFormatter.string(fromBytes: $0) } ?? "—", color: .secondary),
                    ])
                case .gap(let gap):
                    gapTooltip(gap)
                }
            }
        }
        .overlay {
            if swapPoints.isEmpty { ChartPlaceholder(message: series.isEmpty ? "Collecting data…" : "Swap usage unavailable") }
        }
        .accessibilityLabel("Swap usage, \(series.range.accessibilityTitle)")
    }

    /// Tall enough for both used and allocated swap, and at least 1 GB.
    static func yMaximum(for series: HistorySeries) -> Double {
        // Not `swapTotal.map(Double.init)`: for a UInt64 that resolves to `Double(bitPattern:)`,
        // which reinterprets the bits instead of converting the value.
        max(series.peak { $0.swapTotal.map { Double($0) } }, series.peak { $0.swapUsed }, Double(MemoryUnits.gibibyte))
    }
}

// MARK: - Pressure timeline

/// The kernel-reported pressure level over time. Each point is split into the share of its
/// samples at each level, so one brief warning inside a long bucket shows as a thin sliver rather
/// than painting the whole bucket.
struct PressureTimeline: View {
    var series: HistorySeries

    struct Slice: Identifiable, Equatable {
        var id: Int
        var start: Date
        var end: Date
        var level: MemoryPressureLevel
        var lower: Double
        var upper: Double
    }

    struct Column: Equatable {
        var start: Date
        var end: Date
        var normal: Double
        var warning: Double
        var critical: Double

        var midpoint: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
        var elevatedSeconds: TimeInterval { (warning + critical) * end.timeIntervalSince(start) }
    }

    var body: some View {
        let columns = Self.columns(for: series)
        let slices = Self.slices(for: columns)
        Chart {
            ForEach(slices) { slice in
                RectangleMark(
                    xStart: .value("Start", slice.start),
                    xEnd: .value("End", slice.end),
                    yStart: .value("Bottom", slice.lower),
                    yEnd: .value("Top", slice.upper)
                )
                .foregroundStyle(Palette.pressure(slice.level).opacity(slice.level == .normal ? 0.45 : 0.9))
            }
        }
        .chartXScale(domain: series.domain)
        .chartYScale(domain: 0.0...1.0)
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        .chartOverlay { proxy in
            ChartCrosshair(proxy: proxy, dates: columns.map(\.midpoint)) { target in
                if case .point(let index) = target {
                    let column = columns[index]
                    ChartTooltip(
                        title: "\(column.start.formatted(.dateTime.hour().minute()))–\(column.end.formatted(.dateTime.hour().minute()))",
                        rows: Self.tooltipRows(column),
                        footnote: "Share of samples at each level"
                    )
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("macOS memory pressure over \(series.range.accessibilityTitle.lowercased())")
        .accessibilityValue(Self.accessibilitySummary(columns))
    }

    /// One column per history point with a known pressure level, spanning the time it covers.
    static func columns(for series: HistorySeries) -> [Column] {
        var columns: [Column] = []
        let points = series.points
        for (index, item) in points.enumerated() {
            guard let shares = item.point.pressureShares else { continue }
            let start = item.point.start
            var end = item.point.end
            if item.point.duration == 0 {
                // A single sample: it stands for the time until the next sample in its segment.
                if let next = points[safe: index + 1], next.segment == item.segment {
                    end = next.point.start
                } else {
                    end = start.addingTimeInterval(max(series.resolution, 1))
                }
            }
            columns.append(Column(start: start, end: end, normal: shares.normal, warning: shares.warning, critical: shares.critical))
        }
        return columns
    }

    /// Stacks each column bottom-up: critical, warning, then normal. Adjacent columns with the
    /// same shares are drawn as one mark, so a long calm stretch has no hairline seams.
    static func slices(for columns: [Column]) -> [Slice] {
        var runs: [Column] = []
        for column in columns {
            if let last = runs.last, last.end == column.start,
               last.normal == column.normal, last.warning == column.warning, last.critical == column.critical {
                runs[runs.count - 1].end = column.end
            } else {
                runs.append(column)
            }
        }
        var slices: [Slice] = []
        for run in runs {
            var lower = 0.0
            for (level, share) in [(MemoryPressureLevel.critical, run.critical), (.warning, run.warning), (.normal, run.normal)] where share > 0 {
                slices.append(Slice(id: slices.count, start: run.start, end: run.end, level: level, lower: lower, upper: min(lower + share, 1)))
                lower += share
            }
        }
        return slices
    }

    static func tooltipRows(_ column: Column) -> [ChartTooltip.Row] {
        [(MemoryPressureLevel.normal, column.normal), (.warning, column.warning), (.critical, column.critical)]
            .filter { $0.1 > 0 }
            .map { ChartTooltip.Row(label: $0.0.displayName, value: MemoryFormatter.share($0.1), color: Palette.pressure($0.0)) }
    }

    static func accessibilitySummary(_ columns: [Column]) -> String {
        if columns.isEmpty { return "No data" }
        let elevated = columns.reduce(0) { $0 + $1.elevatedSeconds }
        if elevated < 1 { return "Normal throughout" }
        return "Elevated for about \(MemoryFormatter.duration(elevated))"
    }
}

// MARK: - Swap activity

/// The rate at which data was written to swap. Each bar covers exactly the time its counters
/// cover, so bar heights don't depend on how samples happen to fall into fixed-width bins.
struct SwapActivityChart: View {
    var series: HistorySeries

    struct Bar: Identifiable, Equatable {
        var id: Int
        var start: Date
        var end: Date
        var written: UInt64
        var read: UInt64
        /// Seconds of counter data behind the bar.
        var interval: TimeInterval

        var writeRate: Double { interval > 0 ? Double(written) / interval : 0 }
        var midpoint: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
    }

    var body: some View {
        let bars = Self.bars(for: series)
        let maximum = max(bars.map(\.writeRate).max() ?? 0, Double(MemoryUnits.mebibyte))
        Chart {
            ForEach(bars) { bar in
                let inset = bar.end.timeIntervalSince(bar.start) * 0.1
                BarMark(
                    xStart: .value("Start", bar.start.addingTimeInterval(inset)),
                    xEnd: .value("End", bar.end.addingTimeInterval(-inset)),
                    y: .value("Written per second", bar.writeRate)
                )
                .foregroundStyle(Palette.swap)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2))
            }
        }
        .chartXScale(domain: series.domain)
        .chartYScale(domain: 0...maximum)
        .chartXAxis { timeAxis(series.range) }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisValueLabel {
                    if let rate = value.as(Double.self) { Text(rate <= 0 ? "0" : MemoryFormatter.rate(bytesPerSecond: rate)) }
                }
            }
        }
        .chartOverlay { proxy in
            ChartCrosshair(proxy: proxy, dates: bars.map(\.midpoint)) { target in
                if case .point(let index) = target {
                    let bar = bars[index]
                    ChartTooltip(title: "\(bar.start.formatted(.dateTime.hour().minute().second()))–\(bar.end.formatted(.dateTime.hour().minute().second()))", rows: [
                        .init(label: "written to swap", value: "\(MemoryFormatter.string(fromBytes: bar.written, style: .compact)) · \(MemoryFormatter.rate(bytesPerSecond: bar.writeRate))", color: Palette.swap),
                        .init(label: "read from swap", value: MemoryFormatter.string(fromBytes: bar.read, style: .compact), color: nil),
                    ])
                }
            }
        }
        .overlay {
            if bars.isEmpty { ChartPlaceholder(message: series.isEmpty ? "Collecting data…" : "No activity data in this range") }
        }
        .accessibilityLabel("Swap writes, \(series.range.accessibilityTitle)")
    }

    /// One bar per history point that has counter data. An aggregated point covers its bucket; a
    /// single sample covers the interval its counters were measured over, ending at the sample.
    /// Points without counter data (after a gap) get no bar rather than a zero.
    static func bars(for series: HistorySeries) -> [Bar] {
        series.points.compactMap { item in
            guard let activity = item.point.activity, activity.interval > 0 else { return nil }
            let start: Date
            let end: Date
            if item.point.duration > 0 {
                start = item.point.start
                end = item.point.end
            } else {
                end = item.point.start
                start = end.addingTimeInterval(-activity.interval)
            }
            return Bar(id: item.id, start: start, end: end, written: activity.swapOutBytes, read: activity.swapInBytes, interval: activity.interval)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
