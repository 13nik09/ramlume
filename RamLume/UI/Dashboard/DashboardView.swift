import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(selection: $app.dashboardSection) {
                ForEach(DashboardSection.allCases) { section in
                    Label(section.title, systemImage: section.symbolName)
                        .badge(section == .recommendations ? actionableCount : 0)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) {
                MonitoringStatusFooter()
            }
        } detail: {
            FillingLayout {
                detail
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle(app.dashboardSection?.title ?? "RamLume")
        .toolbar {
            if app.dashboardSection == .advanced {
                ToolbarItem(placement: .principal) {
                    AdvancedPagePicker()
                }
            }
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

    /// Suggestions worth acting on, for the sidebar badge.
    private var actionableCount: Int {
        app.monitor.recommendations.filter(\.priority.isActionable).count
    }

    private var usesRange: Bool {
        switch app.dashboardSection ?? .home {
        case .home: true
        case .advanced: app.advancedPage == .history
        case .applications, .recommendations: false
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch app.dashboardSection ?? .home {
        case .home: HomeView()
        case .applications: ProcessesView()
        case .recommendations: RecommendationsView()
        case .advanced: AdvancedView()
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

/// Provides history for a range, on a timer that suits the range: long ranges change slowly, and
/// even a short one doesn't need redrawing with every sample. Changes that must show at once (a
/// pause or another gap, a new retention setting, cleared history) don't wait for the timer.
struct HistorySeriesReader<Content: View>: View {
    @Environment(AppModel.self) private var app
    var range: ChartRange
    var maxPoints = 120
    @ViewBuilder var content: (HistorySeries) -> Content

    var body: some View {
        let store = app.monitor.history
        let _ = store.revision
        if !app.monitor.isPresenting {
            // Hidden or covered: render once, without a refresh timer.
            content(store.history.series(for: range, now: Date(), maxPoints: maxPoints))
        } else {
            TimelineView(.periodic(from: .now, by: Self.refreshInterval(for: range))) { context in
                content(store.history.series(for: range, now: context.date, maxPoints: maxPoints))
            }
        }
    }

    /// How often charts for a range redraw. Samples still arrive every second; redrawing a
    /// stacked chart that often costs several percent of a CPU core for no visible benefit.
    static func refreshInterval(for range: ChartRange) -> TimeInterval {
        switch range {
        case .fiveMinutes: 2
        case .fifteenMinutes: 3
        case .oneHour: 10
        case .oneDay: 30
        case .sevenDays: 60
        }
    }
}

/// Fills the space it's offered without asking its content how large it would like to be.
///
/// The dashboard's detail column always fills the window, whatever is in it. Behind a flexible
/// frame, every size question from AppKit and SwiftUI (minimum size, ideal size, alignment) was
/// passed on to the page's scroll view, which measured its whole content again for each one, with
/// a different proposal every time. On a page that updates every second, in a large window, that
/// was about half of the main thread's work. Nothing depends on the answers, so this layout
/// doesn't ask.
struct FillingLayout: Layout {
    /// Used for a dimension nobody proposed. The window sets the real size.
    static let nominalSize = CGSize(width: 640, height: 480)

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: Self.nominalSize)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        }
    }

    // No alignment guides of its own. The default implementations place the subviews for whatever
    // size is being asked about, to merge their guides, which measures the page after all.
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        nil
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        nil
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
