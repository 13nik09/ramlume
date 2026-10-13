import SwiftUI

/// One segment of physical memory.
struct CompositionSegment: Identifiable, Equatable {
    enum Category: String, CaseIterable {
        case app, wired, compressed, reserved, cached, free

        var title: String {
            switch self {
            case .app: "App"
            case .wired: "Wired"
            case .compressed: "Compressed"
            case .cached: "Cached files"
            case .reserved: "Reserved"
            case .free: "Free"
            }
        }

        var color: Color {
            switch self {
            case .app: Palette.app
            case .wired: Palette.wired
            case .compressed: Palette.compressed
            case .cached: Palette.cached
            case .reserved: Palette.reserved
            case .free: Palette.track
            }
        }

        var help: String {
            switch self {
            case .app: "Anonymous memory used by apps and processes, excluding purgeable memory. Derived from internal − purgeable pages."
            case .wired: "Memory the kernel locked in RAM; it can't be compressed or swapped. Measured."
            case .compressed: "Physical memory occupied by compressed data. Measured."
            case .cached: "File-backed and purgeable memory that macOS can usually reclaim. An estimate of reclaimable memory."
            case .reserved: "Memory reserved by hardware and firmware (hw.memsize − hw.memsize_usable), plus anything the VM statistics don't report. Counted as used: apps can't use it."
            case .free: "Pages not in use at all (excludes speculative read-ahead pages)."
            }
        }
    }

    var category: Category
    var bytes: UInt64
    var id: Category { category }

    static func segments(for breakdown: MemoryBreakdown) -> [CompositionSegment] {
        [
            CompositionSegment(category: .app, bytes: breakdown.app),
            CompositionSegment(category: .wired, bytes: breakdown.wired),
            CompositionSegment(category: .compressed, bytes: breakdown.compressed),
            CompositionSegment(category: .reserved, bytes: breakdown.systemReserved),
            CompositionSegment(category: .cached, bytes: breakdown.cachedFiles),
            CompositionSegment(category: .free, bytes: breakdown.free),
        ]
    }
}

/// A stacked bar of physical memory, separated by 2 pt gaps in the surface color.
struct MemoryCompositionBar: View, Equatable {
    var figures: MemoryFigures
    var height: CGFloat = 10

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    nonisolated static func == (lhs: MemoryCompositionBar, rhs: MemoryCompositionBar) -> Bool {
        lhs.figures.segments == rhs.figures.segments && lhs.height == rhs.height
    }

    var body: some View {
        let segments = figures.segments.filter { $0.fraction > 0 }
        GeometryReader { geometry in
            let gaps = Metrics.barGap * CGFloat(max(segments.count - 1, 0))
            let available = max(geometry.size.width - gaps, 0)
            HStack(spacing: Metrics.barGap) {
                ForEach(segments) { segment in
                    UnevenRoundedRectangle(
                        topLeadingRadius: segment.id == segments.first?.id ? height / 2 : 1.5,
                        bottomLeadingRadius: segment.id == segments.first?.id ? height / 2 : 1.5,
                        bottomTrailingRadius: segment.id == segments.last?.id ? height / 2 : 1.5,
                        topTrailingRadius: segment.id == segments.last?.id ? height / 2 : 1.5,
                        style: .continuous
                    )
                    .fill(segment.category.color)
                    .frame(width: max(available * segment.fraction, 1))
                    .help("\(segment.category.title): \(segment.value)")
                }
            }
            // Animate only noticeable changes (2% of RAM); animating every 1-second sample would
            // keep the window redrawing at display refresh rate.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: figures.animationStep)
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory composition")
        .accessibilityValue(figures.accessibilitySummary)
    }
}

/// Legend for the composition bar: swatch beside text; values in text colors.
struct CompositionLegend: View, Equatable {
    var figures: MemoryFigures
    var columns = 3

    nonisolated static func == (lhs: CompositionLegend, rhs: CompositionLegend) -> Bool {
        lhs.figures.segments == rhs.figures.segments && lhs.columns == rhs.columns
    }

    var body: some View {
        let rows = stride(from: 0, to: figures.segments.count, by: columns).map {
            Array(figures.segments[$0..<min($0 + columns, figures.segments.count)])
        }
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    ForEach(rows[index]) { segment in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(segment.category.color)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(segment.category.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(segment.value)
                                    .font(.callout.weight(.medium))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .help(segment.category.help)
                    }
                }
            }
        }
    }
}
