import SwiftUI

/// The first page: is my Mac healthy, what uses my RAM, and what should I do?
struct HomeView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let monitor = app.monitor
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let snapshot = monitor.snapshot {
                    let figures = MemoryFigures(snapshot)
                    HomeHealthCard(summary: HealthSummary(assessment: monitor.health, figures: figures, pressure: monitor.pressure.level))
                        .equatable()
                    HomeDetailsCard(figures: figures, pressure: monitor.pressure.level)
                    HomeUsageCard()
                    AdaptiveRow(threshold: 760) {
                        HomeTopAppsCard()
                        HomeRecommendationCard()
                    }
                } else {
                    DashboardUnavailableView(error: monitor.readError)
                }
            }
            .padding(24)
            .frame(maxWidth: 1_000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct HomeHealthCard: View, Equatable {
    var summary: HealthSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                HealthSummaryView(summary: summary)
                Spacer(minLength: 12)
                HealthBadge(state: summary.state)
            }
            Text("This status is RamLume's assessment, based on the memory pressure macOS reports (\(summary.pressure)) and recent swap activity.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(.window, padding: 20)
    }
}

/// Activity Monitor's memory figures, for people who want the numbers behind the status.
private struct HomeDetailsCard: View {
    @Environment(AppModel.self) private var app
    var figures: MemoryFigures
    var pressure: MemoryPressureLevel?

    var body: some View {
        DashboardCard("Memory details", accessory: {
            Button("More Details") {
                app.advancedPage = .memory
                app.dashboardSection = .advanced
            }
            .controlSize(.small)
        }) {
            MemoryDetailsGrid(
                figures: figures,
                pressure: pressure,
                items: [.physical, .inUse, .swap, .pressure, .app, .wired, .compressed, .cached]
            )
            .equatable()
        }
    }
}

private struct HomeUsageCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let range = app.settings.dashboardRange
        DashboardCard("Memory in use", subtitle: range.accessibilityTitle) {
            HistorySeriesReader(range: range) { series in
                MemoryUsageChart(series: series, style: .simple)
                    .frame(height: 170)
            }
        }
    }
}

private struct HomeTopAppsCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let monitor = app.monitor
        DashboardCard("Apps using the most memory", accessory: {
            Button("See All") { app.dashboardSection = .applications }
                .controlSize(.small)
        }) {
            TopAppsList(snapshot: monitor.processes, totalMemory: monitor.current.snapshot?.breakdown.total ?? 0, limit: 5, iconSize: 22)
        }
    }
}

private struct HomeRecommendationCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let recommendations = app.monitor.recommendations
        DashboardCard("Recommendation", accessory: {
            Button("See All") { app.dashboardSection = .recommendations }
                .controlSize(.small)
        }) {
            if let first = recommendations.first {
                RecommendationSummaryView(
                    recommendation: first,
                    moreCount: recommendations.dropFirst().filter { $0.priority == .tip }.count,
                    context: nil
                ) {
                    app.dashboardSection = .recommendations
                }
            } else {
                Text("Recommendations appear once RamLume has measurements.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
