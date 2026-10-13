import Foundation
import Testing
@testable import RamLume

/// Builds pressure state and trends for scenario tests.
enum Scenario {
    static let now = Fixtures.reference

    /// Pressure that has been at `level` for `duration` (and, when elevated, elevated that long too).
    static func pressure(_ level: MemoryPressureLevel?, for duration: TimeInterval = 600, lowerBound: Bool = false, at date: Date = now) -> PressureState {
        guard let level else { return .unknown }
        let since = date.addingTimeInterval(-duration)
        return PressureState(
            level: level,
            source: .kernelLevel,
            observedSince: since,
            observedSinceIsLowerBound: lowerBound,
            elevatedSince: level.isElevated ? since : nil,
            elevatedSinceIsLowerBound: level.isElevated && lowerBound
        )
    }

    static func trends(
        swapOut: UInt64? = 0,
        coverage: TimeInterval = 300,
        swapChange: Int64? = 0,
        lastElevated: Date? = nil
    ) -> MemoryTrends {
        var trends = MemoryTrends.empty
        trends.continuousCoverage = 900
        trends.sampleCount = 180
        trends.swapOutRecent = swapOut
        trends.swapInRecent = 0
        trends.pageOutRecent = 0
        trends.activityCoverage = swapOut == nil ? 0 : coverage
        trends.swapUsedChange = swapChange
        trends.changeSpan = 900
        trends.lastElevatedPressure = lastElevated
        return trends
    }
}

@Suite("Health rules")
struct HealthRulesTests {
    let now = Scenario.now

    // Scenario 1: high utilization with low pressure.
    @Test func highUtilizationWithNormalPressureIsHealthy() {
        let snapshot = Fixtures.snapshot(usedFraction: 0.85)
        let assessment = HealthRules.assess(snapshot: snapshot, readError: nil, pressure: Scenario.pressure(.normal), trends: Scenario.trends(), now: now)
        #expect(assessment.state == .healthy)
        #expect(assessment.explanation.contains("normal"))
        #expect(assessment.explanation.contains("Most of your memory is in use"))
    }

    @Test func moderateUsageExplanationReadsCleanly() {
        let assessment = HealthRules.assess(snapshot: Fixtures.snapshot(usedFraction: 0.5), readError: nil, pressure: Scenario.pressure(.normal), trends: Scenario.trends(), now: now)
        #expect(assessment.explanation == "There's been no notable swapping, and your Mac has memory available for more apps.")
        #expect(assessment.headline == "Memory pressure is normal")
    }

    @Test(arguments: [0.5, 0.75, 0.9, 0.98])
    func utilizationAloneNeverDegradesHealth(usedFraction: Double) {
        let snapshot = Fixtures.snapshot(usedFraction: usedFraction)
        let assessment = HealthRules.assess(snapshot: snapshot, readError: nil, pressure: Scenario.pressure(.normal), trends: Scenario.trends(), now: now)
        #expect(assessment.state == .healthy)
    }

    // Scenario 2: persistent pressure warnings.
    @Test func warningPressureIsUnderPressureAndReportsDuration() {
        let assessment = HealthRules.assess(
            snapshot: Fixtures.snapshot(usedFraction: 0.9),
            readError: nil,
            pressure: Scenario.pressure(.warning, for: 900),
            trends: Scenario.trends(swapOut: 400 * Fixtures.mib),
            now: now
        )
        #expect(assessment.state == .underPressure)
        #expect(assessment.explanation.contains("15 min"))
        #expect(assessment.explanation.contains("swap"))
    }

    @Test func pressureAlreadyActiveAtLaunchIsReportedAsLowerBound() {
        let assessment = HealthRules.assess(
            snapshot: Fixtures.snapshot(),
            readError: nil,
            pressure: Scenario.pressure(.warning, for: 300, lowerBound: true),
            trends: Scenario.trends(),
            now: now
        )
        #expect(assessment.explanation.contains("at least 5 min"))
    }

    @Test func criticalPressureIsCritical() {
        let assessment = HealthRules.assess(snapshot: Fixtures.snapshot(), readError: nil, pressure: Scenario.pressure(.critical), trends: Scenario.trends(), now: now)
        #expect(assessment.state == .critical)
    }

    @Test func swappingWithNormalPressureIsElevatedNotCritical() {
        let assessment = HealthRules.assess(
            snapshot: Fixtures.snapshot(),
            readError: nil,
            pressure: Scenario.pressure(.normal),
            trends: Scenario.trends(swapOut: 2 * Fixtures.gib),
            now: now
        )
        #expect(assessment.state == .elevated)
        #expect(assessment.headline == "Heavy swapping")
    }

    @Test func recentPressureKeepsElevatedDuringRecovery() {
        let recent = HealthRules.assess(snapshot: Fixtures.snapshot(), readError: nil, pressure: Scenario.pressure(.normal),
                                        trends: Scenario.trends(lastElevated: now.addingTimeInterval(-120)), now: now)
        #expect(recent.state == .elevated)
        let longAgo = HealthRules.assess(snapshot: Fixtures.snapshot(), readError: nil, pressure: Scenario.pressure(.normal),
                                         trends: Scenario.trends(lastElevated: now.addingTimeInterval(-3_600)), now: now)
        #expect(longAgo.state == .healthy)
    }

    // Scenario 4 (health side): swap left allocated after pressure normalizes.
    @Test func allocatedButIdleSwapIsHealthy() {
        let snapshot = Fixtures.snapshot(usedFraction: 0.7, swapUsed: 2_560 * Fixtures.mib, swapTotal: 3 * Fixtures.gib)
        let assessment = HealthRules.assess(snapshot: snapshot, readError: nil, pressure: Scenario.pressure(.normal), trends: Scenario.trends(swapOut: 0), now: now)
        #expect(assessment.state == .healthy)
    }

    @Test func unknownPressureWithoutActivityIsInsufficientData() {
        let assessment = HealthRules.assess(snapshot: Fixtures.snapshot(), readError: nil, pressure: .unknown,
                                            trends: Scenario.trends(swapOut: nil), now: now)
        #expect(assessment.state == .insufficientData)
    }

    @Test func unknownPressureWithActivityStatesItsBasis() {
        let assessment = HealthRules.assess(snapshot: Fixtures.snapshot(), readError: nil, pressure: .unknown, trends: Scenario.trends(swapOut: 0), now: now)
        #expect(assessment.state == .healthy)
        #expect(assessment.explanation.contains("swap activity only"))
        // Without a kernel level RamLume never claims "critical".
        let heavy = HealthRules.assess(snapshot: Fixtures.snapshot(), readError: nil, pressure: .unknown, trends: Scenario.trends(swapOut: 4 * Fixtures.gib), now: now)
        #expect(heavy.state == .elevated)
    }

    @Test func swapOnlyHealthyNeedsMinutesOfDataButSwappingShowsAtOnce() {
        // A minute of quiet counters isn't enough to call memory healthy without a pressure level…
        let early = HealthRules.assess(snapshot: Fixtures.snapshot(), readError: nil, pressure: .unknown,
                                       trends: Scenario.trends(swapOut: 0, coverage: 60), now: now)
        #expect(early.state == .insufficientData)
        #expect(early.explanation.contains("few minutes"))
        // …but measured swapping is reported as soon as there are 20 seconds of data.
        let swapping = HealthRules.assess(snapshot: Fixtures.snapshot(), readError: nil, pressure: .unknown,
                                          trends: Scenario.trends(swapOut: 400 * Fixtures.mib, coverage: 30), now: now)
        #expect(swapping.state == .elevated)
    }

    @Test func readFailureIsInsufficientDataWithReason() {
        let assessment = HealthRules.assess(snapshot: nil, readError: .hostStatisticsFailed(code: 5), pressure: Scenario.pressure(.normal), trends: .empty, now: now)
        #expect(assessment.state == .insufficientData)
        #expect(assessment.explanation.contains("Mach error 5"))
    }

    @Test func evidenceSeparatesMeasuredFromEstimated() {
        let assessment = HealthRules.assess(snapshot: Fixtures.snapshot(), readError: nil, pressure: Scenario.pressure(.normal), trends: Scenario.trends(), now: now)
        let pressure = assessment.evidence.first { $0.label == "macOS memory pressure" }
        let used = assessment.evidence.first { $0.label == "Memory in use" }
        #expect(pressure?.provenance == .measured)
        #expect(used?.provenance == .estimated)
    }
}

@Suite("Trend analysis")
struct MemoryTrendAnalyzerTests {
    let now = Date(timeIntervalSince1970: 1_790_000_100)

    @Test func sumsRecentSwapActivity() {
        let samples = Fixtures.samples(ending: now, duration: 600, interval: 5) { date, _ in
            Fixtures.point(at: date, activity: Fixtures.activity(interval: 5, swapOut: 10 * Fixtures.mib))
        }
        let trends = MemoryTrendAnalyzer.analyze(samples: samples, gaps: [], now: now)
        // The 5-minute window holds 61 samples (inclusive of both ends).
        #expect(trends.swapOutRecent == 61 * 10 * Fixtures.mib)
        #expect(trends.activityCoverage == 305)
        #expect(trends.continuousCoverage == 600)
    }

    // Scenario 3: growing swap with increasing activity.
    @Test func measuresSwapGrowth() {
        let samples = Fixtures.samples(ending: now, duration: 900, interval: 10) { date, index in
            Fixtures.point(at: date, swapUsed: UInt64(index) * 20 * Fixtures.mib, pressure: .warning,
                           activity: Fixtures.activity(interval: 10, swapOut: UInt64(index) * Fixtures.mib))
        }
        let trends = MemoryTrendAnalyzer.analyze(samples: samples, gaps: [], now: now)
        #expect(trends.swapUsedChange == Int64(90 * 20 * Fixtures.mib))
        // 10 minutes at warning, ±one sample interval at the window edge.
        #expect(abs(trends.elevatedPressureDuration - 600) <= 10)
        #expect(trends.lastElevatedPressure == now)
    }

    // Scenario 6: sleep/wake gaps.
    @Test func trendsDoNotSpanAGap() {
        let beforeSleep = Fixtures.samples(ending: now.addingTimeInterval(-600), duration: 200, interval: 5) { date, index in
            Fixtures.point(at: date, swapUsed: UInt64(index) * Fixtures.gib)
        }
        let afterWake = Fixtures.samples(ending: now, duration: 60, interval: 5) { date, _ in
            Fixtures.point(at: date, swapUsed: 3 * Fixtures.gib)
        }
        let gap = HistoryGap(start: now.addingTimeInterval(-590), end: now.addingTimeInterval(-60), reason: .systemSleep)
        let trends = MemoryTrendAnalyzer.analyze(samples: beforeSleep + afterWake, gaps: [gap], now: now)
        // Only the segment after waking counts: 60 s of coverage and no swap change within it.
        #expect(trends.continuousCoverage == 60)
        #expect(trends.swapUsedChange == 0)
    }

    @Test func noSamplesMeansNoTrends() {
        #expect(MemoryTrendAnalyzer.analyze(samples: [], gaps: [], now: now) == .empty)
    }

    @Test func samplesWithoutCountersLeaveActivityUnknown() {
        let samples = Fixtures.samples(ending: now, duration: 60, interval: 5) { date, _ in Fixtures.point(at: date, activity: nil) }
        let trends = MemoryTrendAnalyzer.analyze(samples: samples, gaps: [], now: now)
        #expect(trends.swapOutRecent == nil)
        #expect(trends.activityCoverage == 0)
    }
}
