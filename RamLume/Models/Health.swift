import Foundation

/// RamLume's heuristic assessment of memory health.
///
/// This is *not* Apple's Memory Pressure reading. It combines the kernel-reported pressure
/// level (measured) with recent swap activity (measured) using the rules in `HealthRules`.
/// High memory utilization alone never makes the state worse than `.healthy`.
enum HealthState: String, Sendable, Codable, CaseIterable {
    case healthy
    case elevated
    case underPressure
    case critical
    case insufficientData

    var title: String {
        switch self {
        case .healthy: "Healthy"
        case .elevated: "Elevated"
        case .underPressure: "Under pressure"
        case .critical: "Critical"
        case .insufficientData: "Insufficient data"
        }
    }

    /// Ordering for "worse than" comparisons; insufficient data is not a severity.
    var severity: Int {
        switch self {
        case .insufficientData: -1
        case .healthy: 0
        case .elevated: 1
        case .underPressure: 2
        case .critical: 3
        }
    }

    var symbolName: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .elevated: "exclamationmark.circle.fill"
        case .underPressure: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        case .insufficientData: "questionmark.circle"
        }
    }
}

/// How a displayed value was obtained.
enum Provenance: String, Sendable, Codable {
    /// Reported directly by macOS.
    case measured
    /// Simple arithmetic on measured values (for example a sum or a difference of counters).
    case derived
    /// An approximation of a concept macOS doesn't report directly.
    case estimated
    /// A judgement made by RamLume's rules.
    case heuristic

    var label: String {
        switch self {
        case .measured: "Measured"
        case .derived: "Derived"
        case .estimated: "Estimate"
        case .heuristic: "Heuristic"
        }
    }
}

/// One fact that supports an assessment or insight.
struct EvidenceItem: Sendable, Equatable, Identifiable {
    var label: String
    var value: String
    var provenance: Provenance

    var id: String { label }
}

struct HealthAssessment: Sendable, Equatable {
    var state: HealthState
    /// A short headline, such as "Memory pressure is normal".
    var headline: String
    /// One or two plain-English sentences.
    var explanation: String
    var evidence: [EvidenceItem]

    static let initial = HealthAssessment(
        state: .insufficientData,
        headline: "Collecting data",
        explanation: "RamLume is taking its first measurements.",
        evidence: []
    )
}
