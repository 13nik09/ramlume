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

/// What a chart's crosshair points at. A pure value, so the rule "change state only when the
/// result changes" is enforced in one place and unit tested (ChartDataTests).
struct ChartHoverState: Equatable {
    var target: ChartHoverTarget?
    /// The pointer's x position, kept only over a gap: a gap has no data position to snap to.
    var gapPointerX: CGFloat?

    static let idle = ChartHoverState(target: nil, gapPointerX: nil)

    /// The state for a pointer at `location` (in the overlay's coordinates), or `nil` once it left.
    /// `dateAtX` maps an x offset into the plot to a date (the chart proxy does this).
    static func resolve(
        location: CGPoint?,
        plot: CGRect,
        dates: [Date],
        gaps: [HistoryGap],
        dateAtX: (CGFloat) -> Date?
    ) -> ChartHoverState {
        guard let location, plot.width > 0 else { return .idle }
        let x = location.x - plot.minX
        guard x >= 0, x <= plot.width, let date = dateAtX(x) else { return .idle }
        if let gap = gaps.first(where: { $0.start <= date && date <= $0.end }) {
            // Whole points: sub-point jitter isn't a change worth redrawing.
            return ChartHoverState(target: .gap(gap), gapPointerX: location.x.rounded())
        }
        if let index = nearestIndex(in: dates, to: date) {
            return ChartHoverState(target: .point(index), gapPointerX: nil)
        }
        return .idle
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

    @State private var hover = ChartHoverState.idle

    var body: some View {
        #if DEBUG
        let _ = HoverDiagnostics.record { $0.crosshairBodies += 1 }
        #endif
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                let plot = geometry[anchor]
                // The hover region is the base view, and everything drawn for the current target is
                // an overlay on it. Overlays never change their base view's frame, so showing,
                // moving, or flipping the tooltip can't move the region that receives hover.
                // (When they shared a ZStack, a tooltip placed left of the crosshair widened the
                // stack and shifted the region; SwiftUI re-tested hover after that layout, the
                // pointer landed on a different target whose tooltip went right, the shift
                // disappeared, and the cycle repeated forever at 100% CPU.)
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        update(phase: phase, plot: plot)
                    }
                    .overlay(alignment: .topLeading) {
                        if let target = hover.target, let x = crosshairX(for: target, plot: plot) {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.6))
                                .frame(width: 1, height: plot.height)
                                .offset(x: x - 0.5, y: plot.minY)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if case .point(let index)? = hover.target,
                           let x = crosshairX(for: .point(index), plot: plot),
                           let value = markerValue?(index),
                           let y = proxy.position(forY: value) {
                            Circle()
                                .fill(markerColor)
                                .overlay(Circle().strokeBorder(Color(nsColor: .controlBackgroundColor), lineWidth: 2))
                                .frame(width: 10, height: 10)
                                .offset(x: x - 5, y: plot.minY + y - 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let target = hover.target, let x = crosshairX(for: target, plot: plot) {
                            tooltipView(for: target, x: x, plot: plot)
                                .allowsHitTesting(false)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private func tooltipView(for target: ChartHoverTarget, x: CGFloat, plot: CGRect) -> some View {
        // Keep the tooltip inside the plot: right of the crosshair on the left half, left of it on
        // the right half. The left placement is a frame that ends 8 points before the crosshair,
        // with the tooltip at its trailing edge. Not an alignment guide: in this overlay a guide
        // had no effect (the tooltip stayed right of the crosshair), and in the shared stack this
        // used to be, it moved the hover area (see `body`).
        if x < plot.midX {
            tooltip(target)
                .fixedSize()
                .offset(x: x + 8, y: plot.minY + 4)
        } else {
            tooltip(target)
                .fixedSize()
                .frame(width: max(x - 8, 0), alignment: .trailing)
                .offset(y: plot.minY + 4)
        }
    }

    private func crosshairX(for target: ChartHoverTarget, plot: CGRect) -> CGFloat? {
        switch target {
        case .point(let index):
            guard dates.indices.contains(index), let x = proxy.position(forX: dates[index]) else { return nil }
            return plot.minX + x
        case .gap:
            return hover.gapPointerX
        }
    }

    /// SwiftUI re-runs hover after every layout change, so this must write state only when the
    /// result changed (and the hover region must never move with the state; see `body`).
    private func update(phase: HoverPhase, plot: CGRect) {
        #if DEBUG
        let phaseLabel = switch phase {
        case .active(let location): "active(\(Int(location.x)),\(Int(location.y))) plot.minX=\(Int(plot.minX)) width=\(Int(plot.width))"
        case .ended: "ended"
        }
        HoverDiagnostics.record { $0.handlerCalls += 1; $0.note("hover \(phaseLabel)") }
        // `--no-mouse` measurements mustn't depend on where the pointer happens to rest.
        if DebugOptions.ignoresMouse { return }
        #endif
        let location: CGPoint? = switch phase {
        case .active(let point): point
        case .ended: nil
        }
        let next = ChartHoverState.resolve(location: location, plot: plot, dates: dates, gaps: gaps) { x in
            proxy.value(atX: x)
        }
        guard next != hover else { return }
        hover = next
        #if DEBUG
        let label = switch next.target { case .gap: "gap"; case .point: "point"; case nil: "none" }
        let detail = switch next.target { case .gap(let gap): "gap(\(gap.start.timeIntervalSince1970))"; case .point(let index): "point(\(index))"; case nil: "none" }
        HoverDiagnostics.record { $0.stateWrites += 1; $0.lastTarget = label; $0.note("write target=\(detail)") }
        #endif
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
