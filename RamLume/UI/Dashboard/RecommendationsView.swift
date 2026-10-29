import SwiftUI

/// Personalized tips, most important first, each with what to do and how.
struct RecommendationsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let recommendations = app.monitor.recommendations
        let actionable = recommendations.filter(\.priority.isActionable).count
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recommendations.first?.id == "checking" ? "Checking your Mac's memory"
                        : actionable == 0 ? "Everything looks good"
                        : "\(actionable) suggestion\(actionable == 1 ? "" : "s") for your Mac")
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
