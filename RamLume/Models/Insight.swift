import Foundation

/// A plain-English observation produced by the diagnostics engine.
struct Insight: Sendable, Equatable, Identifiable {
    enum Kind: Int, Sendable, Comparable, CaseIterable {
        /// Explains what the numbers mean; nothing to do.
        case info = 0
        /// An optional suggestion.
        case suggestion = 1
        /// Something that likely deserves attention.
        case warning = 2
        /// Immediate attention recommended.
        case critical = 3

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }

        var isActionable: Bool { self >= .warning }

        var label: String {
            switch self {
            case .info: "Info"
            case .suggestion: "Suggestion"
            case .warning: "Attention"
            case .critical: "Critical"
            }
        }

        var symbolName: String {
            switch self {
            case .info: "info.circle"
            case .suggestion: "lightbulb"
            case .warning: "exclamationmark.triangle"
            case .critical: "exclamationmark.octagon"
            }
        }
    }

    /// Stable identifier of the rule (plus subject) that produced the insight.
    var id: String
    var kind: Kind
    var title: String
    var message: String
    var recommendation: String?
    var evidence: [EvidenceItem]
}
