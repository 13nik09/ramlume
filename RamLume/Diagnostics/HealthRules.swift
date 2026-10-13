import Foundation

/// Tunable limits used by the health and insight rules. Kept in one place so the reasoning is
/// easy to audit; see docs/diagnostics.md for the rationale behind each value.
struct HealthThresholds: Sendable, Equatable {
    /// Swap written within the recent-activity window (5 minutes) that signals real memory demand.
    var notableSwapOut: UInt64 = 256 * MemoryUnits.mebibyte
    /// Swap written within 5 minutes that indicates heavy swapping.
    var heavySwapOut: UInt64 = MemoryUnits.gibibyte
    /// Pressure must stay at warning this long before RamLume calls it sustained.
    var sustainedPressureDuration: TimeInterval = 120
    /// After pressure returns to normal, RamLume reports "Elevated" for this long.
    var recoveryWindow: TimeInterval = 600
    /// Minimum seconds of counter data before swap activity is used in conclusions.
    var minimumActivityCoverage: TimeInterval = 20
    /// Without a pressure level, "no notable swapping" is the only evidence of health, and swap
    /// writes come in bursts: require most of the 5-minute window before calling memory healthy.
    var swapOnlyVerdictCoverage: TimeInterval = 240
    /// Used fraction above which RamLume explains that high utilization is normal.
    var highUtilizationFraction: Double = 0.75
    /// Swap growth across the change window that counts as "growing".
    var notableSwapGrowth: Int64 = Int64(512 * MemoryUnits.mebibyte)

    static let standard = HealthThresholds()
}

/// Turns measurements into a `HealthAssessment`.
///
/// Principles:
/// - The kernel's pressure level is the primary signal; RamLume reports it, it doesn't compute it.
/// - Measured swap activity can raise a normal reading to *Elevated*, never to *Critical*.
/// - High utilization on its own never makes the state worse than *Healthy*.
/// - Without a pressure level or enough activity data, the state is *Insufficient data*.
enum HealthRules {
    static func assess(
        snapshot: MemorySnapshot?,
        readError: MemoryReadError?,
        pressure: PressureState,
        trends: MemoryTrends,
        now: Date,
        thresholds: HealthThresholds = .standard
    ) -> HealthAssessment {
        guard let snapshot else {
            if let readError {
                return HealthAssessment(
                    state: .insufficientData,
                    headline: "Statistics unavailable",
                    explanation: "RamLume couldn't read memory statistics from macOS. \(readError.description)",
                    evidence: []
                )
            }
            return .initial
        }

        let evidence = makeEvidence(snapshot: snapshot, pressure: pressure, trends: trends, now: now)
        let hasActivity = trends.activityCoverage >= thresholds.minimumActivityCoverage
        let swapOut = hasActivity ? (trends.swapOutRecent ?? 0) : 0

        switch pressure.level {
        case .critical:
            return HealthAssessment(
                state: .critical,
                headline: "Memory pressure is critical",
                explanation: "macOS reports critical memory pressure. Apps may slow down or be closed by the system; quitting apps you aren't using frees memory fastest.",
                evidence: evidence
            )

        case .warning:
            var sentences = ["macOS reports elevated memory pressure."]
            sentences.append(swapSentence(trends: trends, swapOut: swapOut, thresholds: thresholds)
                ?? "It's compressing memory to make room and may swap to disk if demand keeps growing.")
            if let duration = pressure.elevatedDuration(at: now), duration >= thresholds.sustainedPressureDuration {
                let prefix = pressure.elevatedSinceIsLowerBound ? "at least " : ""
                sentences.append("This has lasted \(prefix)\(MemoryFormatter.duration(duration)).")
            }
            return HealthAssessment(
                state: .underPressure,
                headline: "Memory pressure is elevated",
                explanation: sentences.joined(separator: " "),
                evidence: evidence
            )

        case .normal:
            if swapOut >= thresholds.notableSwapOut {
                let heavy = swapOut >= thresholds.heavySwapOut
                return HealthAssessment(
                    state: .elevated,
                    headline: heavy ? "Heavy swapping" : "Recent swapping",
                    explanation: "Memory pressure is normal, but your Mac wrote \(MemoryFormatter.string(fromBytes: swapOut, style: .compact)) to swap in the last 5 minutes — a sign that memory demand has been high.",
                    evidence: evidence
                )
            }
            if let last = trends.lastElevatedPressure, now.timeIntervalSince(last) <= thresholds.recoveryWindow {
                let ago = max(now.timeIntervalSince(last), 0)
                return HealthAssessment(
                    state: .elevated,
                    headline: "Recovering from pressure",
                    explanation: "Memory pressure returned to normal \(ago < 60 ? "moments" : MemoryFormatter.duration(ago)) ago. Swap written during the busy period may stay allocated for a while; that's expected.",
                    evidence: evidence
                )
            }
            return HealthAssessment(
                state: .healthy,
                headline: "Memory pressure is normal",
                explanation: healthyExplanation(snapshot: snapshot, hasActivity: hasActivity, thresholds: thresholds),
                evidence: evidence
            )

        case nil:
            // No pressure level from the kernel or from events: rely on swap activity only.
            // Notable swapping is reported as soon as it's measured; "healthy" needs more data.
            if hasActivity, swapOut >= thresholds.notableSwapOut {
                return HealthAssessment(
                    state: .elevated,
                    headline: "Recent swapping",
                    explanation: "Your Mac wrote \(MemoryFormatter.string(fromBytes: swapOut, style: .compact)) to swap in the last 5 minutes. macOS didn't report a pressure level, so this assessment is based on swap activity only.",
                    evidence: evidence
                )
            }
            guard trends.activityCoverage >= thresholds.swapOnlyVerdictCoverage else {
                return HealthAssessment(
                    state: .insufficientData,
                    headline: "Collecting data",
                    explanation: "macOS hasn't reported a memory pressure level, so RamLume judges memory health from swap activity, which takes a few minutes of measurements.",
                    evidence: evidence
                )
            }
            return HealthAssessment(
                state: .healthy,
                headline: "No signs of strain",
                explanation: "There's been no notable swapping in the last 5 minutes. macOS didn't report a pressure level, so this assessment is based on swap activity only.",
                evidence: evidence
            )
        }
    }

    /// Describes recent swapping, or `nil` if there hasn't been notable swapping. Shared with the
    /// insights so the health text and the insights never disagree.
    static func swapSentence(trends: MemoryTrends, swapOut: UInt64, thresholds: HealthThresholds) -> String? {
        if swapOut >= thresholds.notableSwapOut {
            return "Your Mac wrote \(MemoryFormatter.string(fromBytes: swapOut, style: .compact)) to swap in the last 5 minutes, which can slow things down."
        }
        if let growth = trends.swapUsedChange, growth >= thresholds.notableSwapGrowth {
            return "Swap use grew by \(MemoryFormatter.string(fromBytes: UInt64(growth), style: .compact)) over the last \(MemoryFormatter.duration(trends.changeSpan)), which can slow things down."
        }
        return nil
    }

    static func healthyExplanation(snapshot: MemorySnapshot, hasActivity: Bool, thresholds: HealthThresholds) -> String {
        if snapshot.breakdown.usedFraction >= thresholds.highUtilizationFraction {
            let quiet = hasActivity ? ", and there's been no notable swapping" : ""
            return "Most of your memory is in use, which is normal — macOS keeps memory busy with apps and file caches\(quiet)."
        }
        return hasActivity
            ? "There's been no notable swapping, and your Mac has memory available for more apps."
            : "Your Mac has memory available for more apps."
    }

    static func makeEvidence(snapshot: MemorySnapshot, pressure: PressureState, trends: MemoryTrends, now: Date) -> [EvidenceItem] {
        let breakdown = snapshot.breakdown
        var items: [EvidenceItem] = []

        if let level = pressure.level {
            var value = level.displayName
            if let duration = pressure.duration(at: now), duration >= 60 {
                let minutes = (duration / 60).rounded(.down) * 60
                value += pressure.observedSinceIsLowerBound ? " for at least \(MemoryFormatter.duration(minutes))" : " for \(MemoryFormatter.duration(minutes))"
            }
            items.append(EvidenceItem(label: "macOS memory pressure", value: value, provenance: .measured))
        } else {
            items.append(EvidenceItem(label: "macOS memory pressure", value: "Not reported", provenance: .measured))
        }

        items.append(EvidenceItem(
            label: "Memory in use",
            value: "\(MemoryFormatter.string(fromBytes: breakdown.used)) of \(MemoryFormatter.string(fromBytes: breakdown.total, style: .compact)) (\(MemoryFormatter.percent(breakdown.usedFraction)))",
            provenance: .estimated
        ))

        if let swapOut = trends.swapOutRecent {
            // A stable label; partial coverage is stated in whole minutes so the text doesn't
            // change every second.
            let window = MemoryTrendAnalyzer.recentActivityWindow
            var value = MemoryFormatter.string(fromBytes: swapOut, style: .compact)
            if trends.activityCoverage < window - 10 {
                let minutes = Int(trends.activityCoverage / 60)
                value += minutes < 1 ? " (under 1 min of data)" : " (\(minutes) min of data)"
            }
            items.append(EvidenceItem(label: "Swap written, last 5 min", value: value, provenance: .measured))
        }

        if let swap = snapshot.swap {
            items.append(EvidenceItem(label: "Swap in use", value: MemoryFormatter.string(fromBytes: swap.used), provenance: .measured))
        }

        if breakdown.compressed > 0 {
            items.append(EvidenceItem(
                label: "Compressed",
                value: "\(MemoryFormatter.string(fromBytes: breakdown.compressedOriginal, style: .compact)) stored in \(MemoryFormatter.string(fromBytes: breakdown.compressed, style: .compact))",
                provenance: .measured
            ))
        }
        return items
    }
}
