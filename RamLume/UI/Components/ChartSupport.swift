import Charts
import SwiftUI

extension HistorySeries {
    /// The point closest in time to `date` (binary search; points are chronological).
    func nearestPoint(to date: Date) -> ChartPoint? {
        guard !points.isEmpty else { return nil }
        var low = 0
        var high = points.count - 1
        while low < high {
            let mid = (low + high) / 2
            if points[mid].date < date { low = mid + 1 } else { high = mid }
        }
        let candidate = points[low]
        if low > 0 {
            let previous = points[low - 1]
            if abs(previous.date.timeIntervalSince(date)) < abs(candidate.date.timeIntervalSince(date)) {
                return previous
            }
        }
        return candidate
    }

    func gap(containing date: Date) -> HistoryGap? {
        gaps.first { $0.start <= date && date <= $0.end }
    }

    /// The x-domain shown: always the full requested range, so a short history isn't stretched
    /// to look longer than it is.
    var domain: ClosedRange<Date> { start...max(end, start.addingTimeInterval(1)) }

    func peak(_ value: (HistoryPoint) -> Double?) -> Double {
        points.compactMap { value($0.point) }.max() ?? 0
    }
}

enum ChartFormatting {
    /// "8 GB", "512 MB" — compact axis labels.
    static func axisLabel(bytes: Double) -> String {
        if bytes <= 0 { return "0" }
        let gib = bytes / Double(MemoryUnits.gibibyte)
        if gib >= 1, gib.rounded() == gib {
            return "\(Int(gib)) GB"
        }
        return MemoryFormatter.string(fromBytes: bytes, style: .compact)
    }

    /// Clean tick values (in bytes) for a 0…maximum memory axis.
    static func byteTicks(maximum: Double, desired: Int = 4) -> [Double] {
        guard maximum > 0 else { return [0] }
        let gib = Double(MemoryUnits.gibibyte)
        let mib = Double(MemoryUnits.mebibyte)
        let candidates: [Double] = [64, 128, 256, 512].map { $0 * mib } + [1, 2, 4, 8, 16, 32, 64, 128, 256].map { $0 * gib }
        let step = candidates.first { maximum / $0 <= Double(desired) } ?? candidates.last ?? gib
        return stride(from: 0, through: maximum + step * 0.01, by: step).map { $0 }
    }

    static func timeFormat(for range: ChartRange) -> Date.FormatStyle {
        switch range {
        case .fiveMinutes, .fifteenMinutes, .oneHour, .oneDay:
            .dateTime.hour().minute()
        case .sevenDays:
            .dateTime.weekday(.abbreviated).hour()
        }
    }

    static func tooltipTime(for point: HistoryPoint) -> String {
        if point.duration <= 0 {
            return point.start.formatted(.dateTime.hour().minute().second())
        }
        let start = point.start.formatted(.dateTime.hour().minute())
        let end = point.end.formatted(.dateTime.hour().minute())
        return start == end ? start : "\(start)–\(end)"
    }
}

/// What the pointer is over.
enum ChartHoverTarget: Equatable {
    case point(Int)
    case gap(HistoryGap)
}

/// Hover crosshair and tooltip drawn *over* a chart rather than as chart marks. It owns its
/// hover state, so moving the pointer redraws only this overlay — never the chart's marks —
/// and it snaps to data positions, so it only updates when the nearest point changes.
struct ChartCrosshair<Tooltip: View>: View {
    var proxy: ChartProxy
    /// Chronological x positions the crosshair snaps to.
    var dates: [Date]
    var gaps: [HistoryGap] = []
    /// Y value for the marker dot at a point, if any.
    var markerValue: ((Int) -> Double?)?
    var markerColor: Color = .accentColor
    @ViewBuilder var tooltip: (ChartHoverTarget) -> Tooltip

    @State private var target: ChartHoverTarget?
    @State private var pointerX: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                let plot = geometry[anchor]
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            update(phase: phase, plot: plot)
                        }
                    if let target, let x = crosshairX(for: target, plot: plot) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.6))
                            .frame(width: 1, height: plot.height)
                            .offset(x: x - 0.5, y: plot.minY)
                            .allowsHitTesting(false)
                        if case .point(let index) = target,
                           let value = markerValue?(index),
                           let y = proxy.position(forY: value) {
                            Circle()
                                .fill(markerColor)
                                .overlay(Circle().strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 2))
                                .frame(width: 10, height: 10)
                                .offset(x: x - 5, y: plot.minY + y - 5)
                                .allowsHitTesting(false)
                        }
                        tooltipView(for: target, x: x, plot: plot)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tooltipView(for target: ChartHoverTarget, x: CGFloat, plot: CGRect) -> some View {
        // Keep the tooltip inside the plot: right of the crosshair on the left half, left of it on the right half.
        if x < plot.midX {
            tooltip(target)
                .fixedSize()
                .offset(x: x + 8, y: plot.minY + 4)
        } else {
            tooltip(target)
                .fixedSize()
                .alignmentGuide(.leading) { dimensions in dimensions[.trailing] }
                .offset(x: x - 8, y: plot.minY + 4)
        }
    }

    private func crosshairX(for target: ChartHoverTarget, plot: CGRect) -> CGFloat? {
        switch target {
        case .point(let index):
            guard dates.indices.contains(index), let x = proxy.position(forX: dates[index]) else { return nil }
            return plot.minX + x
        case .gap:
            return pointerX
        }
    }

    /// SwiftUI re-sends the current hover location after every view update, so this must only
    /// write state that actually changed. An unconditional write would make each update request
    /// another, keeping the main thread busy for as long as the pointer rests on the chart.
    private func update(phase: HoverPhase, plot: CGRect) {
        #if DEBUG
        // `--no-mouse` measurements mustn't depend on where the pointer happens to rest.
        if DebugOptions.ignoresMouse { return }
        #endif
        switch phase {
        case .active(let location):
            let x = location.x - plot.minX
            guard x >= 0, x <= plot.width, let date: Date = proxy.value(atX: x) else {
                if target != nil { target = nil }
                return
            }
            let newTarget: ChartHoverTarget?
            if let gap = gaps.first(where: { $0.start <= date && date <= $0.end }) {
                newTarget = .gap(gap)
                if abs(pointerX - location.x) >= 0.5 { pointerX = location.x }
            } else if let index = Self.nearestIndex(in: dates, to: date) {
                newTarget = .point(index)
            } else {
                newTarget = nil
            }
            if newTarget != target { target = newTarget }
        case .ended:
            if target != nil { target = nil }
        }
    }

    static func nearestIndex(in dates: [Date], to date: Date) -> Int? {
        guard !dates.isEmpty else { return nil }
        var low = 0
        var high = dates.count - 1
        while low < high {
            let mid = (low + high) / 2
            if dates[mid] < date { low = mid + 1 } else { high = mid }
        }
        if low > 0, abs(dates[low - 1].timeIntervalSince(date)) < abs(dates[low].timeIntervalSince(date)) {
            return low - 1
        }
        return low
    }
}

/// Tooltip: values lead, labels follow, series keyed by a short line in the series color.
struct ChartTooltip: View {
    struct Row: Identifiable {
        var label: String
        var value: String
        var color: Color?
        var id: String { label }
    }

    var title: String
    var rows: [Row]
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ForEach(rows) { row in
                HStack(spacing: 6) {
                    if let color = row.color {
                        Capsule().fill(color).frame(width: 10, height: 2.5)
                    }
                    Text(row.value)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        }
        .fixedSize()
    }
}

/// Legend entry: a line key for line series, a square swatch for fills.
struct LegendItem: View {
    enum Shape { case line, swatch }
    var title: String
    var color: Color
    var shape: Shape = .swatch

    var body: some View {
        HStack(spacing: 5) {
            switch shape {
            case .line:
                Capsule().fill(color).frame(width: 12, height: 2.5)
            case .swatch:
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            }
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "No data yet" overlay shown inside a chart frame.
struct ChartPlaceholder: View {
    var message: String

    var body: some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
