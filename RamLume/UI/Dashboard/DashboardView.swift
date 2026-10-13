import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $app.dashboardSection) {
                ForEach(DashboardSection.allCases) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) {
                MonitoringStatusFooter()
            }
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle(app.dashboardSection?.title ?? "RamLume")
        .toolbar {
            if usesRange {
                ToolbarItem(placement: .primaryAction) {
                    RangePicker()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    app.togglePause()
                } label: {
                    Label(app.monitor.isPausedByUser ? "Resume Monitoring" : "Pause Monitoring",
                          systemImage: app.monitor.isPausedByUser ? "play.fill" : "pause.fill")
                }
                .help(app.monitor.isPausedByUser ? "Resume monitoring" : "Pause monitoring")
            }
        }
    }

    private var usesRange: Bool {
        switch app.dashboardSection {
        case .overview?, .history?: true
        default: false
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch app.dashboardSection ?? .overview {
        case .overview: OverviewView()
        case .history: HistoryView()
        case .processes: ProcessesView()
        case .insights: InsightsView()
        case .events: EventsView()
        case .metrics: MetricsGuideView()
        }
    }
}

/// The single time-range control; it scopes every chart on the page.
struct RangePicker: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Picker("Time range", selection: $settings.dashboardRange) {
            ForEach(ChartRange.available(for: app.settings.historyRetention)) { range in
                Text(range.shortTitle)
                    .tag(range)
                    .accessibilityLabel(range.accessibilityTitle)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help("Time range for the charts")
    }
}

private struct MonitoringStatusFooter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let monitor = app.monitor
        HStack(spacing: 6) {
            Circle()
                .fill(monitor.status == .running ? Palette.good : Palette.unknown)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var statusText: String {
        let monitor = app.monitor
        switch monitor.status {
        case .running:
            let interval = monitor.scheduler.cadence.memoryInterval
            return "Live · every \(MemoryFormatter.duration(interval))"
        case .pausedByUser: return "Monitoring paused"
        case .systemAsleep: return "Paused while asleep"
        case .stopped: return "Not monitoring"
        }
    }
}

/// Provides history for a range, refreshing on every sample for short ranges and on a slower
/// timer for long ones (their buckets change slowly, so redrawing every second would be waste).
struct HistorySeriesReader<Content: View>: View {
    @Environment(AppModel.self) private var app
    var range: ChartRange
    var maxPoints = 120
    @ViewBuilder var content: (HistorySeries) -> Content

    var body: some View {
        let store = app.monitor.history
        if !app.monitor.isPresenting {
            // Hidden or covered: render once, without a refresh timer.
            content(store.history.series(for: range, now: Date(), maxPoints: maxPoints))
        } else if let interval = Self.refreshInterval(for: range) {
            TimelineView(.periodic(from: .now, by: interval)) { context in
                content(store.history.series(for: range, now: context.date, maxPoints: maxPoints))
            }
        } else {
            let _ = store.revision
            content(store.history.series(for: range, now: Date(), maxPoints: maxPoints))
        }
    }

    /// How often charts for a range redraw. Samples still arrive every second; redrawing a
    /// stacked chart that often costs several percent of a CPU core for no visible benefit.
    static func refreshInterval(for range: ChartRange) -> TimeInterval? {
        switch range {
        case .fiveMinutes: 2
        case .fifteenMinutes: 3
        case .oneHour: 10
        case .oneDay: 30
        case .sevenDays: 60
        }
    }
}

/// Lays out its content side by side when there's room and stacked otherwise, without
/// building both arrangements (as `ViewThatFits` would).
struct AdaptiveRow<Content: View>: View {
    var threshold: CGFloat = 900
    @ViewBuilder var content: () -> Content
    @State private var width: CGFloat = 1_000

    var body: some View {
        let layout = width >= threshold
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        layout(content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// A titled card used throughout the dashboard.
struct DashboardCard<Content: View, Accessory: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                accessory()
            }
            content()
        }
        .card(.window, padding: 16)
    }
}
