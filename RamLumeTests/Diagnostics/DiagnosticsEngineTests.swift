import Foundation
import Testing
@testable import RamLume

@Suite("Diagnostics engine")
struct DiagnosticsEngineTests {
    let now = Scenario.now

    private func insights(
        snapshot: MemorySnapshot = Fixtures.snapshot(),
        pressure: PressureState = Scenario.pressure(.normal),
        trends: MemoryTrends = Scenario.trends(),
        processes: ProcessSnapshot? = nil,
        growth: [ProcessGrowthFinding] = []
    ) -> [Insight] {
        let health = HealthRules.assess(snapshot: snapshot, readError: nil, pressure: pressure, trends: trends, now: now)
        return DiagnosticsEngine.insights(for: DiagnosticsInput(
            now: now, snapshot: snapshot, pressure: pressure, health: health,
            trends: trends, processes: processes, growthFindings: growth
        ))
    }

    // Scenario 1: high utilization with low pressure.
    @Test func explainsHighUtilizationWithLowPressure() throws {
        let result = insights(snapshot: Fixtures.snapshot(usedFraction: 0.85))
        let insight = try #require(result.first { $0.id == "high-utilization-low-pressure" })
        #expect(insight.kind == .info)
        #expect(insight.message == "Your Mac is using most of its RAM, but memory pressure appears low. This is usually normal because macOS uses available memory efficiently.")
        #expect(!result.contains { $0.kind.isActionable })
    }

    // Scenario 2: persistent pressure warnings.
    @Test func persistentPressureProducesAWarning() throws {
        let result = insights(
            snapshot: Fixtures.snapshot(usedFraction: 0.92),
            pressure: Scenario.pressure(.warning, for: 600),
            trends: Scenario.trends(swapOut: 600 * Fixtures.mib, swapChange: Int64(Fixtures.gib)),
            processes: Fixtures.braveSnapshot()
        )
        let insight = try #require(result.first)
        #expect(insight.id == "sustained-pressure")
        #expect(insight.kind == .warning)
        #expect(insight.message.contains("may be experiencing sustained memory pressure"))
        #expect(insight.recommendation?.contains("Closing unnecessary applications could improve performance.") == true)
        #expect(insight.recommendation?.contains("Brave Browser") == true)
    }

    @Test func briefWarningWithoutSwappingIsOnlyASuggestion() {
        let result = insights(pressure: Scenario.pressure(.warning, for: 30), trends: Scenario.trends(swapOut: 0))
        #expect(result.contains { $0.id == "elevated-pressure" && $0.kind == .suggestion })
        #expect(!result.contains { $0.id == "sustained-pressure" })
    }

    // Health and the sustained-pressure insight share one swap test, so they can't disagree.
    @Test(arguments: [
        (UInt64(0), Int64(0)),                      // no swapping
        (400 * Fixtures.mib, Int64(0)),             // swap writes
        (UInt64(0), Int64(Fixtures.gib)),           // swap growth only
    ])
    func healthAndSustainedInsightAgreeAboutSwapping(swapOut: UInt64, swapChange: Int64) {
        let pressure = Scenario.pressure(.warning, for: 600)
        let trends = Scenario.trends(swapOut: swapOut, swapChange: swapChange)
        let health = HealthRules.assess(snapshot: Fixtures.snapshot(), readError: nil, pressure: pressure, trends: trends, now: now)
        let result = insights(pressure: pressure, trends: trends)
        let sustained = result.first { $0.id == "sustained-pressure" }
        let sentence = HealthRules.swapSentence(trends: trends, swapOut: swapOut, thresholds: .standard)
        #expect((sentence == nil) == (swapOut == 0 && swapChange == 0))
        if let sentence {
            #expect(health.explanation.contains(sentence))
            #expect(sustained?.message.contains(sentence) == true)
        } else {
            #expect(sustained == nil)
            #expect(health.explanation.contains("may swap to disk if demand keeps growing"))
            let elevated = result.first { $0.id == "elevated-pressure" }
            #expect(elevated?.message.contains("little swapping so far") == true)
        }
    }

    @Test func swapWritesNeedEnoughCounterDataEverywhere() {
        let pressure = Scenario.pressure(.warning, for: 600)
        let trends = Scenario.trends(swapOut: 400 * Fixtures.mib, coverage: 10)
        let health = HealthRules.assess(snapshot: Fixtures.snapshot(), readError: nil, pressure: pressure, trends: trends, now: now)
        #expect(!health.explanation.contains("wrote"))
        #expect(!insights(pressure: pressure, trends: trends).contains { $0.id == "sustained-pressure" })
    }

    @Test func sustainedPressureIncludesTimeAtCritical() throws {
        // Warning for one minute, after fourteen minutes at critical: elevated for 15 minutes.
        var pressure = Scenario.pressure(.warning, for: 60)
        pressure.elevatedSince = now.addingTimeInterval(-900)
        let result = insights(pressure: pressure, trends: Scenario.trends(swapOut: 400 * Fixtures.mib))
        let insight = try #require(result.first { $0.id == "sustained-pressure" })
        #expect(insight.message.contains("elevated pressure for 15 min"))
    }

    // Scenario 3: growing swap with increasing activity.
    @Test func growingSwapWithActivityIsFlagged() {
        let normal = insights(trends: Scenario.trends(swapOut: 700 * Fixtures.mib, swapChange: Int64(2 * Fixtures.gib)))
        #expect(normal.contains { $0.id == "recent-swapping" })
        let pressured = insights(pressure: Scenario.pressure(.warning, for: 400), trends: Scenario.trends(swapOut: 700 * Fixtures.mib, swapChange: Int64(2 * Fixtures.gib)))
        #expect(pressured.first?.id == "sustained-pressure")
    }

    // Scenario 4: swap remaining allocated after pressure normalizes.
    @Test func explainsRetainedSwapWithoutRecommendingRestart() throws {
        let snapshot = Fixtures.snapshot(usedFraction: 0.7, swapUsed: 2_560 * Fixtures.mib, swapTotal: 3 * Fixtures.gib)
        let result = insights(snapshot: snapshot, trends: Scenario.trends(swapOut: 0, lastElevated: now.addingTimeInterval(-300)))
        let swap = try #require(result.first { $0.id == "swap-retained" })
        #expect(swap.kind == .info)
        #expect(swap.message.contains("doesn't necessarily mean your Mac is running low on memory"))
        #expect(swap.message.contains("macOS may retain swapped-out inactive data after earlier demand"))
        #expect(swap.recommendation == "No action needed. Restarting just to clear swap isn't necessary.")
        #expect(result.contains { $0.id == "recovered-from-pressure" })
    }

    // Scenario 5: missing or inaccessible process statistics.
    @Test func noConsumerInsightWhenProcessesAreRestricted() {
        let restrictedOnly = Fixtures.processSnapshot(records: [
            Fixtures.process(pid: 1, path: "/sbin/launchd", footprint: nil),
            Fixtures.process(pid: 2, path: "/usr/sbin/WindowServer", footprint: nil),
        ])
        let result = insights(processes: restrictedOnly)
        #expect(!result.contains { $0.id.hasPrefix("largest-consumer") })
        let noScanYet = insights(processes: nil)
        #expect(!noScanYet.contains { $0.id.hasPrefix("largest-consumer") })
    }

    @Test func largestConsumerUsesAppSpecificAdvice() throws {
        let result = insights(snapshot: Fixtures.snapshot(usedFraction: 0.8), processes: Fixtures.braveSnapshot())
        let brave = try #require(result.first { $0.id.hasPrefix("largest-consumer") })
        #expect(brave.title.contains("Brave Browser"))
        #expect(brave.message.contains("Its tabs, extensions, and renderer processes may contribute to this usage."))
        #expect(brave.recommendation?.contains("Memory Saver") == true)
        // ~3.9 GB is 24% of 16 GB: worth knowing, but with normal pressure it's information.
        #expect(brave.kind == .info)

        // The same consumer while macOS reports pressure becomes a suggestion.
        let pressured = insights(snapshot: Fixtures.snapshot(usedFraction: 0.9), pressure: Scenario.pressure(.warning, for: 30), processes: Fixtures.braveSnapshot())
        #expect(pressured.first { $0.id.hasPrefix("largest-consumer") }?.kind == .suggestion)
    }

    /// An app with a helper RamLume can't measure (say, one that runs as root).
    @Test func consumerWithOneMeasurableProcessIsNotDescribedAsSeveral() throws {
        let mixed = Fixtures.processSnapshot(records: [
            Fixtures.process(pid: 9, path: Fixtures.braveMain, footprint: 3 * Fixtures.gib),
            Fixtures.process(pid: 10, path: Fixtures.braveGPU, footprint: nil),
        ])
        let insight = try #require(insights(processes: mixed).first { $0.id.hasPrefix("largest-consumer") })
        #expect(!insight.message.contains("across"))
        #expect(insight.message.contains("3 GB (19% of RAM)"))
    }

    @Test func smallConsumersAreNotFlagged() {
        let small = Fixtures.processSnapshot(records: [Fixtures.process(pid: 9, path: Fixtures.braveMain, footprint: 300 * Fixtures.mib)])
        #expect(!insights(processes: small).contains { $0.id.hasPrefix("largest-consumer") })
    }

    @Test func compressionIsNeverCalledAProblem() throws {
        let result = insights(snapshot: Fixtures.snapshot(usedFraction: 0.7))
        let compression = try #require(result.first { $0.id == "compression-working" })
        #expect(compression.kind == .info)
        #expect(compression.message.contains("isn't a problem by itself"))
    }

    @Test func possibleLeakWordingIsCautious() throws {
        let finding = ProcessGrowthFinding(id: "app:/Applications/Foo.app", displayName: "Foo", startBytes: Fixtures.gib, endBytes: 3 * Fixtures.gib, duration: 2_400)
        let insight = try #require(insights(growth: [finding]).first { $0.id.hasPrefix("process-growth") })
        #expect(insight.kind == .suggestion)
        #expect(insight.message.contains("can be expected for some workloads"))
        #expect(insight.message.contains("can also be a sign of a memory leak"))
        #expect(!insight.message.localizedCaseInsensitiveContains("is leaking"))
    }

    @Test func criticalPressureComesFirst() throws {
        let result = insights(pressure: Scenario.pressure(.critical), trends: Scenario.trends(swapOut: 2 * Fixtures.gib), processes: Fixtures.braveSnapshot())
        let first = try #require(result.first)
        #expect(first.kind == .critical)
        #expect(result.map(\.kind) == result.map(\.kind).sorted(by: >))
    }

    @Test func neverRecommendsRestartingTheMac() {
        let scenarios: [(PressureState, MemoryTrends, MemorySnapshot)] = [
            (Scenario.pressure(.critical), Scenario.trends(swapOut: 3 * Fixtures.gib), Fixtures.snapshot(usedFraction: 0.97, swapUsed: 6 * Fixtures.gib, swapTotal: 7 * Fixtures.gib)),
            (Scenario.pressure(.warning, for: 3_600), Scenario.trends(swapOut: Fixtures.gib, swapChange: Int64(3 * Fixtures.gib)), Fixtures.snapshot(usedFraction: 0.9)),
            (Scenario.pressure(.normal), Scenario.trends(swapOut: 0), Fixtures.snapshot(usedFraction: 0.6, swapUsed: 4 * Fixtures.gib, swapTotal: 5 * Fixtures.gib)),
        ]
        for (pressure, trends, snapshot) in scenarios {
            for insight in insights(snapshot: snapshot, pressure: pressure, trends: trends, processes: Fixtures.braveSnapshot()) {
                let text = [insight.message, insight.recommendation ?? ""].joined(separator: " ").lowercased()
                #expect(!text.contains("restart your mac"))
                #expect(!text.contains("reboot"))
            }
        }
    }

    @Test func noInsightsWithoutData() {
        let result = DiagnosticsEngine.insights(for: DiagnosticsInput(
            now: now, snapshot: nil, pressure: .unknown, health: .initial, trends: .empty, processes: nil, growthFindings: []
        ))
        #expect(result.isEmpty)
    }

    @Test func missingPressureLevelIsExplained() {
        #expect(insights(pressure: .unknown).contains { $0.id == "pressure-unavailable" })
    }
}

@Suite("Process growth (possible leaks)")
struct ProcessGrowthTrackerTests {
    let start = Fixtures.reference

    private func snapshot(at offset: TimeInterval, bytes: UInt64?) -> ProcessSnapshot {
        Fixtures.processSnapshot(
            timestamp: start.addingTimeInterval(offset),
            records: [Fixtures.process(pid: 10, path: Fixtures.braveMain, footprint: bytes)]
        )
    }

    @Test func detectsSteadySustainedGrowth() throws {
        var tracker = ProcessGrowthTracker()
        for minute in 0...30 {
            tracker.record(snapshot(at: Double(minute) * 60, bytes: Fixtures.gib + UInt64(minute) * 80 * Fixtures.mib))
        }
        let finding = try #require(tracker.findings(now: start.addingTimeInterval(1_800)).first)
        #expect(finding.displayName == "Brave Browser")
        #expect(finding.growth >= 2 * Fixtures.gib)
        #expect(finding.duration >= 1_740)
    }

    @Test func ignoresShortOrSmallGrowth() {
        var short = ProcessGrowthTracker()
        for minute in 0...10 {
            short.record(snapshot(at: Double(minute) * 60, bytes: Fixtures.gib + UInt64(minute) * 300 * Fixtures.mib))
        }
        #expect(short.findings(now: start.addingTimeInterval(600)).isEmpty)

        var small = ProcessGrowthTracker()
        for minute in 0...40 {
            small.record(snapshot(at: Double(minute) * 60, bytes: 4 * Fixtures.gib + UInt64(minute) * 10 * Fixtures.mib))
        }
        #expect(small.findings(now: start.addingTimeInterval(2_400)).isEmpty)
    }

    @Test func ignoresFluctuatingUsage() {
        var tracker = ProcessGrowthTracker()
        for minute in 0...40 {
            let wobble: UInt64 = minute.isMultiple(of: 2) ? 0 : 1_500 * Fixtures.mib
            tracker.record(snapshot(at: Double(minute) * 60, bytes: Fixtures.gib + wobble + UInt64(minute) * 40 * Fixtures.mib))
        }
        #expect(tracker.findings(now: start.addingTimeInterval(2_400)).isEmpty)
    }

    @Test func relaunchResetsTheSeries() {
        var tracker = ProcessGrowthTracker()
        for minute in 0...30 {
            tracker.record(snapshot(at: Double(minute) * 60, bytes: Fixtures.gib + UInt64(minute) * 80 * Fixtures.mib))
        }
        tracker.record(snapshot(at: 1_860, bytes: 200 * Fixtures.mib))   // quit and reopened
        #expect(tracker.findings(now: start.addingTimeInterval(1_860)).isEmpty)
    }

    @Test func forgetsGroupsThatDisappear() {
        var tracker = ProcessGrowthTracker()
        tracker.record(snapshot(at: 0, bytes: Fixtures.gib))
        #expect(tracker.series.count == 1)
        tracker.record(Fixtures.processSnapshot(timestamp: start.addingTimeInterval(60), records: []))
        #expect(tracker.series.isEmpty)
    }
}
