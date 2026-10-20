import SwiftUI

extension Palette {
    static func recommendation(_ recommendation: Recommendation) -> Color {
        switch recommendation.priority {
        case .status: recommendation.id == "checking" ? unknown : good
        case .tip, .suggested: Color.accentColor
        case .important: serious
        case .urgent: critical
        }
    }
}

extension Recommendation.Priority {
    /// A small tag, or `nil` for reassurance.
    var tag: String? {
        switch self {
        case .status: nil
        case .tip: "Optional"
        case .suggested: "Suggested"
        case .important: "Important"
        case .urgent: "Urgent"
        }
    }
}

/// The app's icon when the tip is about an app, otherwise its symbol.
struct RecommendationIcon: View {
    var recommendation: Recommendation
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let path = recommendation.appIconPath {
                ProcessIcon(path: path, size: size)
            } else {
                Image(systemName: recommendation.symbolName)
                    .font(.system(size: size * 0.62, weight: .medium))
                    .foregroundStyle(Palette.recommendation(recommendation))
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A recommendation in full: what, why, what to do, and how.
struct RecommendationCard: View {
    @Environment(AppModel.self) private var app
    var recommendation: Recommendation
    @State private var showsInstructions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                RecommendationIcon(recommendation: recommendation, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(recommendation.title)
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if let tag = recommendation.priority.tag {
                            Text(tag)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Palette.recommendation(recommendation))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Palette.recommendation(recommendation).opacity(0.12), in: Capsule())
                        }
                    }
                    Text(recommendation.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let suggestion = recommendation.suggestion {
                Label {
                    Text(suggestion).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: recommendation.priority == .status ? "checkmark.circle.fill" : "arrow.forward.circle.fill")
                        .foregroundStyle(Palette.recommendation(recommendation))
                }
                .font(.callout.weight(.medium))
                .padding(.leading, 42)
            }
            if showsInstructions {
                InstructionSteps(steps: recommendation.steps)
                    .padding(.leading, 42)
                    .transition(.opacity)
            }
            Text("\(Text("Why you're seeing this:").fontWeight(.medium)) \(recommendation.reason)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 42)
            if !recommendation.steps.isEmpty || !recommendation.actions.isEmpty {
                HStack(spacing: 8) {
                    if !recommendation.steps.isEmpty {
                        Button(showsInstructions ? "Hide Instructions" : "Show Instructions") {
                            withAnimation(.smooth(duration: 0.25)) { showsInstructions.toggle() }
                        }
                    }
                    ForEach(recommendation.actions, id: \.self) { action in
                        Button {
                            app.perform(action)
                        } label: {
                            Label(action.title, systemImage: action.symbolName)
                        }
                    }
                }
                .controlSize(.regular)
                .padding(.leading, 42)
            }
        }
        .card(.window, padding: 16)
        .accessibilityElement(children: .contain)
    }
}

/// Numbered steps.
struct InstructionSteps: View {
    var steps: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 16, alignment: .trailing)
                    Text(step)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.callout)
    }
}

/// One recommendation, briefly, for the menu bar panel and Home.
struct RecommendationSummaryView: View {
    var recommendation: Recommendation
    /// Optional tips not shown, so a reassuring status can still point to them.
    var moreCount = 0
    /// Where it's drawn as a card; `nil` when it's already inside one.
    var context: CardContext? = .panel
    var open: () -> Void

    var body: some View {
        if let context {
            content.card(context)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                RecommendationIcon(recommendation: recommendation, size: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(recommendation.title)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(recommendation.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(context == .panel ? 4 : 5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let title = buttonTitle {
                Button(title, action: open)
                    .controlSize(.small)
                    .padding(.leading, 34)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var buttonTitle: String? {
        switch recommendation.priority {
        case .urgent, .important, .suggested: "How to Fix"
        case .tip: "Learn How"
        case .status: moreCount > 0 ? "\(moreCount) optional tip\(moreCount == 1 ? "" : "s")" : nil
        }
    }
}
