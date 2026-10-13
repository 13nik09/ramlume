import SwiftUI

/// The panel shown from the menu bar item.
struct MenuPanelView: View {
    @Environment(AppModel.self) private var app
    /// Height of the content; the scroll view matches it until the screen runs out of room.
    @State private var contentHeight: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader()
            Divider()
            // One copy of the content (`ViewThatFits` would build and update two). It only
            // scrolls on displays too short to show everything.
            ScrollView {
                PanelContent()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, maxContentHeight))
            Divider()
            PanelFooter()
        }
        .frame(width: Metrics.panelWidth)
    }

    /// Keeps the panel within the screen on small displays; content scrolls beyond this.
    private var maxContentHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return max(screenHeight - 140, 320)
    }
}

private struct PanelHeader: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text(AppInfo.name)
                .font(.headline)
            Spacer()
            HealthBadge(state: app.monitor.health.state, compact: true)
            Menu {
                Button("Open Dashboard") { app.openDashboard() }
                Button("Settings…") { app.openSettings() }
                Divider()
                Button(app.monitor.isPausedByUser ? "Resume Monitoring" : "Pause Monitoring") { app.togglePause() }
                Divider()
                Button("About RamLume") { app.showAbout() }
                Button("Quit RamLume") { app.quit() }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings and actions")
            .accessibilityLabel("Settings and actions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct PanelContent: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let monitor = app.monitor
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            if !app.settings.hasShownWelcome {
                WelcomeNote()
            }
            if monitor.isPausedByUser {
                PausedNote()
            }
            if let snapshot = monitor.snapshot {
                let figures = MemoryFigures(snapshot)
                MemorySummaryCard(figures: figures)
                StatsGrid(figures: figures, pressure: monitor.pressure.level)
                    .equatable()
                HealthCard(assessment: monitor.health)
                    .equatable()
                TopAppsSection()
                InsightsSection()
            } else {
                UnavailableCard(error: monitor.readError)
            }
        }
        .padding(14)
    }
}

private struct WelcomeNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.wave")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Welcome to RamLume")
                    .font(.callout.weight(.semibold))
                Text("RamLume lives in your menu bar. Click the memory chip icon any time to check on your Mac's memory. Everything stays on your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(.panel)
    }
}

private struct PausedNote: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Monitoring is paused. Values below are from \(lastUpdate).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Resume") { app.togglePause() }
                .controlSize(.small)
        }
        .card(.panel)
    }

    private var lastUpdate: String {
        app.monitor.snapshot?.timestamp.formatted(date: .omitted, time: .shortened) ?? "earlier"
    }
}

private struct UnavailableCard: View {
    var error: MemoryReadError?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error {
                Label("Memory statistics unavailable", systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.semibold))
                Text(error.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("RamLume will keep trying. No values are shown rather than guessing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Taking the first measurement…", systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .card(.panel)
    }
}

private struct MemorySummaryCard: View {
    var figures: MemoryFigures

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelHeadline(figures: figures)
                .equatable()
            MemoryCompositionBar(figures: figures, height: 8)
                .equatable()
            PanelMiniChart()
                .frame(height: 52)
                .padding(.top, 2)
            HStack {
                Text("Last 5 minutes")
                Spacer()
                Text("Used ≈ everything except cached and free")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .card(.panel)
    }
}

private struct PanelHeadline: View, Equatable {
    var figures: MemoryFigures

    nonisolated static func == (lhs: PanelHeadline, rhs: PanelHeadline) -> Bool {
        lhs.figures.used == rhs.figures.used && lhs.figures.total == rhs.figures.total && lhs.figures.percent == rhs.figures.percent
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(figures.used)
                .font(.system(size: 26, weight: .semibold))
            Text("of \(figures.total) in use")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(figures.percent)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("About \(figures.used) of \(figures.total) in use, \(figures.percent)")
        .help("Estimated memory in use: App + Wired + Compressed + Reserved — everything except cached files and free memory.")
    }
}

/// The last five minutes; refreshes with each new sample while the panel is open.
private struct PanelMiniChart: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let history = app.monitor.history
        let _ = history.revision
        MemoryUsageChart(series: history.history.series(for: .fiveMinutes, now: Date(), maxPoints: 60), style: .compact)
    }
}

private struct StatsGrid: View, Equatable {
    var figures: MemoryFigures
    var pressure: MemoryPressureLevel?

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        LazyVGrid(columns: columns, spacing: 8) {
            StatTile(label: "App", value: figures.app,
                     provenance: .derived, swatch: Palette.app, help: CompositionSegment.Category.app.help)
            StatTile(label: "Wired", value: figures.wired,
                     swatch: Palette.wired, help: CompositionSegment.Category.wired.help)
            StatTile(label: "Compressed", value: figures.compressed,
                     caption: figures.compressedOriginal.map { "holds \($0)" },
                     swatch: Palette.compressed, help: CompositionSegment.Category.compressed.help)
            StatTile(label: "Cached", value: figures.cached,
                     caption: "reclaimable", provenance: .estimated, swatch: Palette.cached,
                     help: CompositionSegment.Category.cached.help)
            StatTile(label: "Swap", value: figures.swapUsed ?? "—",
                     caption: figures.swapTotal.map { "\($0) allocated" } ?? "unavailable",
                     help: "Swap in use, from vm.swapusage. macOS can keep swap allocated after memory demand drops; that's normal.")
            StatTile(label: "Pressure", value: pressure?.displayName ?? "—", caption: "from macOS",
                     swatch: Palette.pressure(pressure),
                     help: "The memory pressure level macOS reports (normal, warning, or critical).")
        }
    }
}

private struct HealthCard: View, Equatable {
    var assessment: HealthAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: assessment.state.symbolName)
                    .foregroundStyle(Palette.health(assessment.state))
                    .accessibilityHidden(true)
                Text(assessment.headline)
                    .font(.callout.weight(.semibold))
            }
            Text(assessment.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(.panel)
        .accessibilityElement(children: .combine)
    }
}

private struct TopAppsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let monitor = app.monitor
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(
                title: "Top apps",
                trailing: monitor.processes.map { "\($0.accessibleCount) of \($0.totalCount) processes measured" }
            )
            TopAppsList(snapshot: monitor.processes, totalMemory: monitor.snapshot?.breakdown.total ?? 0, limit: 3)
        }
    }
}

private struct InsightsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let all = app.monitor.insights
        if let first = all.first {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeading(title: "Insights")
                    if all.count > 1 {
                        Button("\(all.count - 1) more") { app.openDashboard(.insights) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                InsightRow(insight: first, lineLimit: 4)
            }
        }
    }
}

private struct PanelFooter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack {
            Button {
                app.openDashboard()
            } label: {
                Label("Open Dashboard", systemImage: "macwindow")
            }
            .keyboardShortcut("d", modifiers: .command)
            Spacer()
            Button("Quit") { app.quit() }
                .keyboardShortcut("q", modifiers: .command)
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
