import SwiftUI

/// Personalized tips, most important first, each with what to do and how.
struct RecommendationsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let recommendations = app.monitor.recommendations
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.heading(for: recommendations))
                        .font(.title2.weight(.semibold))
                    Text("Based on what RamLume measures on your Mac right now. RamLume never changes settings or quits apps for you.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 4)
                ForEach(recommendations) { recommendation in
                    RecommendationCard(recommendation: recommendation)
                }
                GoodToKnowCard()
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    static func heading(for recommendations: [Recommendation]) -> String {
        if recommendations.first?.id == "checking" { return "Checking your Mac's memory" }
        let actionable = recommendations.filter { $0.priority.isActionable }.count
        switch actionable {
        case 0: return "Everything looks good"
        case 1: return "1 suggestion for your Mac"
        default: return "\(actionable) suggestions for your Mac"
        }
    }
}

/// Explanations from the insights that don't call for action.
private struct GoodToKnowCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let notes = app.monitor.insights.filter { $0.kind == .info }
        if !notes.isEmpty {
            DashboardCard("Good to know") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(notes.enumerated()), id: \.element.id) { index, insight in
                        if index > 0 { Divider() }
                        InsightRow(insight: insight, showsEvidence: true)
                    }
                }
            }
        }
    }
}
