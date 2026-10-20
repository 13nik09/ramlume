import SwiftUI

/// What the simple health summary shows, formatted, so views re-render only when the text
/// people see changes.
struct HealthSummary: Equatable {
    var state: HealthState
    var sentence: String
    var detail: String
    /// "11.4 GB of 16 GB RAM in use"
    var usage: String
    var usedFraction: Double
    var pressure: String

    init(assessment: HealthAssessment, figures: MemoryFigures, pressure: MemoryPressureLevel?) {
        state = assessment.state
        sentence = assessment.state.sentence
        detail = assessment.plainDetail
        usage = "\(figures.used) of \(figures.total) RAM in use"
        // Whole percents: the bar never needs finer steps.
        usedFraction = (figures.usedFraction * 100).rounded() / 100
        self.pressure = pressure?.displayName ?? "not reported"
    }
}

/// The health state's symbol on a soft tinted circle.
struct HealthSymbol: View {
    var state: HealthState
    var size: CGFloat = 52

    var body: some View {
        Image(systemName: state.symbolName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(Palette.health(state))
            .frame(width: size, height: size)
            .background(Palette.health(state).opacity(0.13), in: Circle())
            .accessibilityHidden(true)
    }
}

/// One bar for memory in use; no breakdown.
struct UsageBar: View {
    var fraction: Double
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(Palette.app)
                    .frame(width: max(geometry.size.width * min(max(fraction, 0), 1), height))
            }
        }
        .frame(height: height)
        // Animate only noticeable changes (2 % steps), not every percent.
        .animation(.smooth(duration: 0.5), value: (fraction * 50).rounded())
        .accessibilityElement()
        .accessibilityLabel("Memory in use")
        .accessibilityValue(MemoryFormatter.percent(fraction))
    }
}

/// Status sentence, RAM in use, one bar, and a short explanation.
struct HealthSummaryView: View, Equatable {
    var summary: HealthSummary
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 12 : 18) {
            HealthSymbol(state: summary.state, size: compact ? 36 : 56)
            VStack(alignment: .leading, spacing: compact ? 5 : 8) {
                Text(summary.sentence)
                    .font(compact ? .headline : .title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(summary.usage)
                    .font(compact ? .callout : .title3)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                UsageBar(fraction: summary.usedFraction, height: compact ? 7 : 10)
                    .padding(.vertical, compact ? 2 : 4)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(summary.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    InfoButton(term: .pressure)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
