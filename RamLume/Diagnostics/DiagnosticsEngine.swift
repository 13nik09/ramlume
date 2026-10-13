import Foundation

/// Everything the insight rules may look at.
struct DiagnosticsInput: Sendable {
    var now: Date
    var snapshot: MemorySnapshot?
    var pressure: PressureState
    var health: HealthAssessment
    var trends: MemoryTrends
    var processes: ProcessSnapshot?
    var growthFindings: [ProcessGrowthFinding]
}

/// Deterministic, rule-based insights. Each rule is a pure function of the input, so the same
/// measurements always produce the same explanations, and every rule has unit tests.
///
/// Wording guidelines enforced here:
/// - Describe what the numbers mean before suggesting anything.
/// - Separate information (`.info`) from suggestions and warnings.
/// - Never call compression or allocated swap a problem by themselves.
/// - Never recommend restarting the Mac to clear swap.
/// - Use cautious language for possible leaks and for causes RamLume can't observe.
enum DiagnosticsEngine {
    static func insights(for input: DiagnosticsInput, thresholds: HealthThresholds = .standard) -> [Insight] {
        guard input.snapshot != nil else { return [] }
        let rules: [(DiagnosticsInput, HealthThresholds) -> [Insight]] = [
            { [criticalPressure($0, $1)].compactMap { $0 } },
            { [sustainedPressure($0, $1)].compactMap { $0 } },
            { [elevatedPressure($0, $1)].compactMap { $0 } },
            { [recentSwapping($0, $1)].compactMap { $0 } },
            { [largestConsumer($0, $1)].compactMap { $0 } },
            processGrowth,
            { [recoveredFromPressure($0, $1)].compactMap { $0 } },
            { [highUtilizationLowPressure($0, $1)].compactMap { $0 } },
            { [swapRetained($0, $1)].compactMap { $0 } },
            { [compressionWorking($0, $1)].compactMap { $0 } },
            { [pressureUnavailable($0, $1)].compactMap { $0 } },
        ]
        let insights = rules.flatMap { $0(input, thresholds) }
        // Stable sort: most severe first, rule order within the same kind.
        return insights.enumerated()
            .sorted { lhs, rhs in
                lhs.element.kind != rhs.element.kind ? lhs.element.kind > rhs.element.kind : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: - Rules

    static func criticalPressure(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Insight? {
        guard input.pressure.level == .critical else { return nil }
        var recommendation = "Save your work, then quit apps you don't need."
        if let top = topConsumer(input) {
            recommendation += " The largest is \(top.displayName) (\(MemoryFormatter.string(fromBytes: top.totalFootprint, style: .compact)))."
        }
        return Insight(
            id: "critical-pressure",
            kind: .critical,
            title: "Critical memory pressure",
            message: "macOS reports critical memory pressure. Apps may become unresponsive, and macOS may close apps to free memory.",
            recommendation: recommendation,
            evidence: [pressureEvidence(input)]
        )
    }

    static func sustainedPressure(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Insight? {
        guard input.pressure.level == .warning,
              let duration = input.pressure.elevatedDuration(at: input.now),
              duration >= thresholds.sustainedPressureDuration else { return nil }
        // The same swap test as the health assessment, so the two never disagree.
        let hasActivity = input.trends.activityCoverage >= thresholds.minimumActivityCoverage
        let swapOut = hasActivity ? (input.trends.swapOutRecent ?? 0) : 0
        guard let swapSentence = HealthRules.swapSentence(trends: input.trends, swapOut: swapOut, thresholds: thresholds) else { return nil }

        var evidence = [pressureEvidence(input)]
        evidence.append(EvidenceItem(
            label: "Elevated pressure, last 10 min",
            value: MemoryFormatter.duration(input.trends.elevatedPressureDuration),
            provenance: .measured
        ))
        if swapOut > 0 {
            evidence.append(EvidenceItem(label: "Swap written, last 5 min", value: MemoryFormatter.string(fromBytes: swapOut, style: .compact), provenance: .measured))
        }
        if let growth = input.trends.swapUsedChange, growth > 0 {
            evidence.append(EvidenceItem(label: "Swap growth, last \(MemoryFormatter.duration(input.trends.changeSpan))", value: MemoryFormatter.signedChange(bytes: growth), provenance: .measured))
        }
        var recommendation = "Closing unnecessary applications could improve performance."
        if let top = topConsumer(input) {
            recommendation += " \(top.displayName) is currently the largest (\(MemoryFormatter.string(fromBytes: top.totalFootprint, style: .compact)))."
        }
        let lasted = "\(input.pressure.elevatedSinceIsLowerBound ? "at least " : "")\(MemoryFormatter.duration(duration))"
        return Insight(
            id: "sustained-pressure",
            kind: .warning,
            title: "Sustained memory pressure",
            message: "Your Mac may be experiencing sustained memory pressure: macOS has reported elevated pressure for \(lasted). \(swapSentence)",
            recommendation: recommendation,
            evidence: evidence
        )
    }

    /// Warning-level pressure without notable swapping (or not yet sustained).
    static func elevatedPressure(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Insight? {
        guard input.pressure.level == .warning, sustainedPressure(input, thresholds) == nil else { return nil }
        let duration = input.pressure.elevatedDuration(at: input.now) ?? 0
        let message: String
        if duration < thresholds.sustainedPressureDuration {
            message = "macOS is compressing memory to make room for apps. Short periods like this are common when you open large apps or documents."
        } else {
            let lasted = "\(input.pressure.elevatedSinceIsLowerBound ? "at least " : "")\(MemoryFormatter.duration(duration))"
            message = "macOS has reported elevated pressure for \(lasted) and is compressing memory to make room. There's been little swapping so far."
        }
        return Insight(
            id: "elevated-pressure",
            kind: .suggestion,
            title: "Memory pressure is elevated",
            message: message,
            recommendation: "If your Mac feels slow, closing apps you aren't using will help.",
            evidence: [pressureEvidence(input)]
        )
    }

    /// Swapping while the kernel says pressure is normal.
    static func recentSwapping(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Insight? {
        guard input.pressure.level == .normal,
              input.trends.activityCoverage >= thresholds.minimumActivityCoverage,
              let swapOut = input.trends.swapOutRecent, swapOut >= thresholds.notableSwapOut else { return nil }
        return Insight(
            id: "recent-swapping",
            kind: .suggestion,
            title: "Recent swapping",
            message: "Your Mac wrote \(MemoryFormatter.string(fromBytes: swapOut, style: .compact)) to swap in the last 5 minutes, although memory pressure is normal right now. Occasional bursts are normal; sustained swapping can slow things down.",
            recommendation: nil,
            evidence: [
                pressureEvidence(input),
                EvidenceItem(label: "Swap written, last 5 min", value: MemoryFormatter.string(fromBytes: swapOut, style: .compact), provenance: .measured),
            ]
        )
    }

    static func largestConsumer(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Insight? {
        guard let snapshot = input.snapshot, let top = topConsumer(input) else { return nil }
        let total = snapshot.breakdown.total
        let share = MemoryUnits.fraction(top.totalFootprint, of: total) ?? 0
        let minimum = max(UInt64(1.5 * Double(MemoryUnits.gibibyte)), total / 10)
        guard top.totalFootprint >= minimum else { return nil }

        let executableName = top.processes.first.map { ($0.executablePath ?? $0.name) }.map { ($0 as NSString).lastPathComponent }
        let advice = KnownApplications.advice(forBundleIdentifier: top.bundleIdentifier, executableName: executableName)
        let size = MemoryFormatter.string(fromBytes: top.totalFootprint, style: .compact)
        let processes = top.processes.count == 1 ? "" : " across \(top.accessibleCount) processes"

        var message = "\(top.displayName) is the largest memory user RamLume can measure: \(size)\(processes) (\(MemoryFormatter.percent(share)) of RAM)."
        if let context = advice?.context {
            message += " " + context
        }
        let attention = (input.pressure.level ?? .normal) >= .warning || share >= 0.25
        return Insight(
            id: "largest-consumer:\(top.id)",
            kind: attention ? .suggestion : .info,
            title: "\(top.displayName) is using \(size)",
            message: message,
            recommendation: advice?.suggestion,
            evidence: [
                EvidenceItem(label: "\(top.displayName) footprint", value: size, provenance: .derived),
                EvidenceItem(label: "Processes measured", value: "\(top.accessibleCount) of \(top.processes.count)", provenance: .measured),
            ]
        )
    }

    static func processGrowth(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> [Insight] {
        input.growthFindings.prefix(2).map { finding in
            let from = MemoryFormatter.string(fromBytes: finding.startBytes, style: .compact)
            let to = MemoryFormatter.string(fromBytes: finding.endBytes, style: .compact)
            return Insight(
                id: "process-growth:\(finding.id)",
                kind: .suggestion,
                title: "\(finding.displayName)'s memory keeps growing",
                message: "\(finding.displayName) grew from \(from) to \(to) over the last \(MemoryFormatter.duration(finding.duration)). Steady growth can be expected for some workloads, such as large documents or long builds, but it can also be a sign of a memory leak.",
                recommendation: "If \(finding.displayName) becomes slow, saving your work and reopening it will release the memory.",
                evidence: [
                    EvidenceItem(label: "Growth", value: MemoryFormatter.signedChange(bytes: Int64(clamping: finding.growth)), provenance: .derived),
                    EvidenceItem(label: "Observed for", value: MemoryFormatter.duration(finding.duration), provenance: .measured),
                ]
            )
        }
    }

    static func recoveredFromPressure(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Insight? {
        guard input.pressure.level == .normal,
              let last = input.trends.lastElevatedPressure,
              input.now.timeIntervalSince(last) <= thresholds.recoveryWindow else { return nil }
        return Insight(
            id: "recovered-from-pressure",
            kind: .info,
            title: "Pressure is back to normal",
            message: "Memory pressure was elevated recently and has returned to normal. Swap written during the busy period may stay allocated for a while; that's expected and doesn't need a restart.",
            recommendation: nil,
            evidence: [pressureEvidence(input)]
        )
    }

    static func highUtilizationLowPressure(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Insight? {
        guard let snapshot = input.snapshot,
              input.pressure.level == .normal,
              snapshot.breakdown.usedFraction >= thresholds.highUtilizationFraction,
              (input.trends.swapOutRecent ?? 0) < thresholds.notableSwapOut else { return nil }
        return Insight(
            id: "high-utilization-low-pressure",
            kind: .info,
            title: "High usage is normal here",
            message: "Your Mac is using most of its RAM, but memory pressure appears low. This is usually normal because macOS uses available memory efficiently.",
            recommendation: nil,
            evidence: [
                EvidenceItem(label: "Memory in use", value: MemoryFormatter.percent(snapshot.breakdown.usedFraction), provenance: .estimated),
                pressureEvidence(input),
            ]
        )
    }

    static func swapRetained(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Insight? {
        guard let snapshot = input.snapshot, let swap = snapshot.swap,
              input.pressure.level == .normal,
              swap.used >= 256 * MemoryUnits.mebibyte,
              input.trends.activityCoverage >= thresholds.minimumActivityCoverage,
              (input.trends.swapOutRecent ?? .max) < thresholds.notableSwapOut / 4,
              (input.trends.swapUsedChange ?? 0) < thresholds.notableSwapGrowth / 4 else { return nil }

        var message = "Swap is currently allocated (\(MemoryFormatter.string(fromBytes: swap.used, style: .compact)) in use), but this doesn't necessarily mean your Mac is running low on memory. macOS may retain swapped-out inactive data after earlier demand."
        let cached = snapshot.breakdown.cachedFiles
        if cached >= MemoryUnits.gibibyte {
            message += " About \(MemoryFormatter.string(fromBytes: cached, style: .compact)) of cached files can also be reclaimed if apps need memory."
        }
        return Insight(
            id: "swap-retained",
            kind: .info,
            title: "Swap is allocated but quiet",
            message: message,
            recommendation: "No action needed. Restarting just to clear swap isn't necessary.",
            evidence: [
                EvidenceItem(label: "Swap in use", value: MemoryFormatter.string(fromBytes: swap.used), provenance: .measured),
                EvidenceItem(label: "Swap written, last 5 min", value: MemoryFormatter.string(fromBytes: input.trends.swapOutRecent ?? 0, style: .compact), provenance: .measured),
                pressureEvidence(input),
            ]
        )
    }

    static func compressionWorking(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Insight? {
        guard let breakdown = input.snapshot?.breakdown,
              input.pressure.level == .normal,
              breakdown.compressed >= 512 * MemoryUnits.mebibyte,
              let ratio = breakdown.compressionRatio, ratio >= 1.5 else { return nil }
        let stored = MemoryFormatter.string(fromBytes: breakdown.compressedOriginal, style: .compact)
        let occupied = MemoryFormatter.string(fromBytes: breakdown.compressed, style: .compact)
        return Insight(
            id: "compression-working",
            kind: .info,
            title: "Compression is saving memory",
            message: "macOS is storing \(stored) of data in \(occupied) of memory (\(ratio.formatted(.number.precision(.fractionLength(1))))× smaller). Compression is a normal, efficient way for macOS to make room; it isn't a problem by itself.",
            recommendation: nil,
            evidence: [
                EvidenceItem(label: "Compressed data", value: stored, provenance: .measured),
                EvidenceItem(label: "Memory it occupies", value: occupied, provenance: .measured),
            ]
        )
    }

    static func pressureUnavailable(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Insight? {
        guard input.pressure.level == nil else { return nil }
        return Insight(
            id: "pressure-unavailable",
            kind: .info,
            title: "Pressure level not reported",
            message: "macOS hasn't reported a memory pressure level to RamLume, so health is assessed from swap activity alone. RamLume will update as soon as macOS reports a level.",
            recommendation: nil,
            evidence: []
        )
    }

    // MARK: - Helpers

    static func topConsumer(_ input: DiagnosticsInput) -> ProcessGroup? {
        input.processes?.largestAccessibleGroup
    }

    static func pressureEvidence(_ input: DiagnosticsInput) -> EvidenceItem {
        EvidenceItem(label: "macOS memory pressure", value: input.pressure.level?.displayName ?? "Not reported", provenance: .measured)
    }
}
