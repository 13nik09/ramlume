import Foundation

/// A plain-English tip produced by `RecommendationEngine`: what's going on, why RamLume thinks
/// so, and what (if anything) to do about it.
struct Recommendation: Sendable, Equatable, Identifiable {
    enum Priority: Int, Sendable, Comparable {
        /// Reassurance or explanation; nothing to do.
        case status = 0
        /// Optional; worth knowing, never a problem.
        case tip = 1
        /// Likely to help if the Mac feels slow.
        case suggested = 2
        /// Memory is short; acting will help.
        case important = 3
        /// Memory is critically short.
        case urgent = 4

        static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }

        /// Whether this asks the person to do something.
        var isActionable: Bool { self >= .suggested }
    }

    /// Something the person can do from the recommendation itself. Nothing here changes the
    /// system: actions only navigate or open Apple's own tools.
    enum Action: Sendable, Hashable {
        case viewApplications
        case openActivityMonitor
        case openLoginItemsSettings
        case viewMemoryDetails

        var title: String {
            switch self {
            case .viewApplications: "View Applications"
            case .openActivityMonitor: "Open Activity Monitor"
            case .openLoginItemsSettings: "Open Login Items Settings"
            case .viewMemoryDetails: "Learn More"
            }
        }

        var symbolName: String {
            switch self {
            case .viewApplications: "square.grid.2x2"
            case .openActivityMonitor: "gauge.with.dots.needle.33percent"
            case .openLoginItemsSettings: "gearshape"
            case .viewMemoryDetails: "info.circle"
            }
        }
    }

    /// Stable identifier of the rule (plus subject) that produced it.
    var id: String
    var priority: Priority
    var symbolName: String
    var title: String
    /// One or two sentences in plain English.
    var summary: String
    /// The measurements behind it ("Why am I seeing this?").
    var reason: String
    /// The suggested action in one sentence, if there is one.
    var suggestion: String?
    /// Step-by-step instructions.
    var steps: [String] = []
    var actions: [Action] = []
    /// The app this is about, for its icon.
    var appIconPath: String?
}
