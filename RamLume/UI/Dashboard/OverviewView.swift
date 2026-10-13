import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let monitor = app.monitor
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let snapshot = monitor.snapshot {
                    let figures = MemoryFigures(snapshot)
                    AdaptiveRow(threshold: 720) {
                        MemoryHeroCard(figures: figures)
                            .equatable()
                        HealthDetailCard(assessment: monitor.health)
                            .equatable()
                    }
                    UsageHistoryCard()
                    KeyFiguresGrid(model: KeyFigures(figures: figures, pressure: monitor.pressure, trends: monitor.trends))
                        .equatable()
                    AdaptiveRow(threshold: 760) {
                        TopAppsCard()
                        InsightsSummaryCard()
                    }
                } else {
                    DashboardUnavailableView(error: monitor.readError)
                }
            }
            .padding(20)
        }
    }
}

struct DashboardUnavailableView: View {
    var error: MemoryReadError?

    var body: some View {
        if let error {
            ContentUnavailableView {
                Label("Memory statistics unavailable", systemImage: "exclamationmark.triangle")
            } description: {
                Text("\(error.description) RamLume will keep trying, and shows nothing rather than guessing.")
            }
        } else {
            // Static on purpose: an animated spinner redraws every frame, and the first reading
            // normally arrives within a second anyway.
            Label("Taking the first measurement…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 200)
        }
    }
}

private struct MemoryHeroCard: View, Equatable {
    var figures: MemoryFigures

    var body: some View {
        DashboardCard("Memory", subtitle: "Installed: \(figures.total)") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(figures.used)
                        .font(.system(size: 48, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("in use (estimate)")
                            .foregroundStyle(.secondary)
                        Text("\(figures.percent) of \(figures.total)")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                .accessibilityElement(children: .combine)
                .help("Estimated memory in use = App + Wired + Compressed + Reserved, i.e. everything except cached files and free memory. Activity Monitor's Memory Used uses Apple's own, unpublished formula and may differ slightly.")
                MemoryCompositionBar(figures: figures, height: 12)
                    .equatable()
                CompositionLegend(figures: figures, columns: 3)
                    .equatable()
                Divider()
                HStack(alignment: .top, spacing: 24) {
                    summary("Available", "≈ \(figures.available)", "Available without swapping: cached files + free memory. An upper bound — not every cached page can be reclaimed instantly.")
                    if let savings = figures.savings {
                        summary("Compression saves", savings, "Data held by the compressor minus the memory it occupies.")
                    }
                    if let swapUsed = figures.swapUsed {
                        summary("Swap in use", swapUsed, "From vm.swapusage.")
                    }
                }
            }
        }
    }
}

private func summary(_ label: String, _ value: String, _ help: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(label)
            .font(.caption)
            .foregroundStyle(.secondary)
        Text(value)
            .font(.title3.weight(.semibold))
    }
    .accessibilityElement(children: .combine)
    .help(help)
}

struct HealthDetailCard: View, Equatable {
    var assessment: HealthAssessment

    var body: some View {
        DashboardCard("Health", accessory: { HealthBadge(state: assessment.state) }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(assessment.headline)
                    .font(.title3.weight(.semibold))
                Text(assessment.explanation)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !assessment.evidence.isEmpty {
                    Divider().padding(.vertical, 2)
                    EvidenceList(items: assessment.evidence)
                }
                Text("RamLume's assessment combines the pressure level macOS reports with recent swap activity. It isn't Apple's Memory Pressure graph.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct UsageHistoryCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let range = app.settings.dashboardRange
        DashboardCard("Memory usage", subtitle: range.accessibilityTitle) {
            HistorySeriesReader(range: range) { series in
                VStack(alignment: .leading, spacing: 8) {
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
                        Spacer()
                        Text("Stacked; the top line is estimated use")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

/// The values shown in the key-figures grid, formatted.
struct KeyFigures: Equatable {
    var pressureLevel: MemoryPressureLevel?
    var pressureCaption: String?
    var compressed: String
    var compressedCaption: String?
    var swapUsed: String
    var swapCaption: String?
    var swapWritten: String
    var swapReadCaption: String?
    var cached: String
    var free: String
    var freeCaption: String?

    init(figures: MemoryFigures, pressure: PressureState, trends: MemoryTrends, now: Date = Date()) {
        pressureLevel = pressure.level
        if pressure.level != nil, let duration = pressure.duration(at: now) {
            if duration < 60 {
                // A first reading (after launch, sleep, or a pause) isn't a change.
                pressureCaption = pressure.observedSinceIsLowerBound ? "from macOS" : "just changed"
            } else {
                let minutes = MemoryFormatter.duration((duration / 60).rounded(.down) * 60)
                pressureCaption = pressure.observedSinceIsLowerBound ? "for at least \(minutes)" : "for \(minutes)"
            }
        }
        compressed = figures.compressed
        if let original = figures.compressedOriginal {
            compressedCaption = figures.compressionRatio.map { "holds \(original) · \($0)" } ?? "holds \(original)"
        }
        swapUsed = figures.swapUsed ?? "Unavailable"
        swapCaption = figures.swapTotal.map { "of \($0) allocated\(figures.swapEncrypted ? " · encrypted" : "")" }
        swapWritten = trends.swapOutRecent.map { MemoryFormatter.string(fromBytes: $0, style: .compact) } ?? "Collecting…"
        swapReadCaption = trends.swapInRecent.map { "read \(MemoryFormatter.string(fromBytes: $0, style: .compact))" }
        cached = figures.cached
        free = figures.free
        freeCaption = figures.kernelFreePercentage.map { "macOS reports \($0)% available" }
    }
}

private struct KeyFiguresGrid: View, Equatable {
    var model: KeyFigures

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 170), spacing: 12)]
        LazyVGrid(columns: columns, spacing: 12) {
            StatTile(label: "macOS pressure", value: model.pressureLevel?.displayName ?? "Not reported",
                     caption: model.pressureCaption, swatch: Palette.pressure(model.pressureLevel),
                     help: "The memory pressure level reported by macOS.", context: .window)
            StatTile(label: "Compressed", value: model.compressed, caption: model.compressedCaption,
                     swatch: Palette.compressed, help: CompositionSegment.Category.compressed.help, context: .window)
            StatTile(label: "Swap used", value: model.swapUsed, caption: model.swapCaption,
                     swatch: Palette.swap, help: "From vm.swapusage. Allocated swap can remain after demand drops; that's normal.", context: .window)
            StatTile(label: "Swap written · 5 min", value: model.swapWritten, caption: model.swapReadCaption,
                     help: "Swap I/O measured from the kernel's swapouts and swapins counters.", context: .window)
            StatTile(label: "Cached files", value: model.cached, caption: "usually reclaimable", provenance: .estimated,
                     swatch: Palette.cached, help: CompositionSegment.Category.cached.help, context: .window)
            StatTile(label: "Free", value: model.free, caption: model.freeCaption,
                     help: "Pages not in use at all. The caption shows kern.memorystatus_level, the kernel's own availability percentage.", context: .window)
        }
    }
}

private struct TopAppsCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let monitor = app.monitor
        DashboardCard("Top apps", subtitle: monitor.processes.map { "Physical footprint · \($0.accessibleCount) of \($0.totalCount) processes measurable" }, accessory: {
            Button("All Processes") { app.dashboardSection = .processes }
                .controlSize(.small)
        }) {
            TopAppsList(snapshot: monitor.processes, totalMemory: monitor.snapshot?.breakdown.total ?? 0, limit: 6, iconSize: 20)
        }
    }
}

private struct InsightsSummaryCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let insights = app.monitor.insights
        DashboardCard("Insights", accessory: {
            Button("Details") { app.dashboardSection = .insights }
                .controlSize(.small)
        }) {
            if insights.isEmpty {
                Text("Nothing to report right now.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(insights.prefix(3)) { insight in
                        InsightRow(insight: insight)
                    }
                }
            }
        }
    }
}
