import Foundation
import Testing
@testable import RamLume

@Suite("Memory breakdown")
struct MemoryBreakdownTests {
    @Test func realReadingPartitionsInstalledMemoryExactly() {
        let breakdown = MemoryBreakdown(statistics: Fixtures.statistics())
        #expect(breakdown.total == Fixtures.physicalMemory)
        #expect(breakdown.reserved == Fixtures.physicalMemory - Fixtures.usableMemory)
        // Every page is counted exactly once: nothing double-counted, nothing missing.
        #expect(breakdown.accounted == breakdown.total)
        #expect(breakdown.unaccounted == 0)
    }

    @Test func categoriesUseTheDocumentedFormulas() {
        let p = Fixtures.realPages
        let page = Fixtures.pageSize
        let breakdown = MemoryBreakdown(statistics: Fixtures.statistics())
        #expect(breakdown.wired == p.wired * page)
        #expect(breakdown.compressed == p.compressorOccupied * page)
        #expect(breakdown.compressedOriginal == p.compressorStored * page)
        #expect(breakdown.app == (p.anonymous - p.purgeable) * page)
        #expect(breakdown.cachedFiles == (p.fileBacked + p.purgeable) * page)
        // free_count already includes speculative pages, so they're subtracted, not added.
        #expect(breakdown.free == (p.free - p.speculative) * page)
        // Used is everything that isn't cached or free (hardware-reserved memory included).
        #expect(breakdown.used == breakdown.app + breakdown.wired + breakdown.compressed + breakdown.systemReserved)
        #expect(breakdown.used + breakdown.cachedFiles + breakdown.free == breakdown.total)
    }

    @Test func compressedMemoryIsCountedOnce() {
        let breakdown = MemoryBreakdown(statistics: Fixtures.statistics())
        // The uncompressed size is informational and never part of "used".
        #expect(breakdown.used < breakdown.total)
        #expect(breakdown.compressionRatio.map { $0 > 1.8 && $0 < 1.9 } == true)
        #expect(breakdown.compressionSavings == breakdown.compressedOriginal - breakdown.compressed)
    }

    @Test func usedFractionMatchesReading() {
        let breakdown = MemoryBreakdown(statistics: Fixtures.statistics())
        // 3.74 GB app + 2.35 GB wired + 5.74 GB compressed + 0.62 GB reserved ≈ 12.44 GB of 16 GB.
        #expect(abs(breakdown.usedFraction - 0.7774) < 0.001)
        #expect(breakdown.availableEstimate == breakdown.cachedFiles + breakdown.free)
    }

    @Test func clampsInconsistentCounters() {
        var pages = Fixtures.realPages
        pages.purgeable = pages.anonymous + 10   // read at slightly different instants
        pages.speculative = pages.free + 5
        let breakdown = MemoryBreakdown(statistics: Fixtures.statistics(pages: pages))
        #expect(breakdown.app == 0)
        #expect(breakdown.free == 0)
        #expect(breakdown.cachedFiles == (pages.fileBacked + pages.anonymous) * Fixtures.pageSize)
    }

    @Test func missingUsableMemoryBecomesUnaccounted() {
        let breakdown = MemoryBreakdown(statistics: Fixtures.statistics(usableMemory: nil))
        #expect(breakdown.reserved == nil)
        #expect(breakdown.unaccounted == Fixtures.physicalMemory - Fixtures.usableMemory)
    }

    @Test func zeroMemoryDoesNotCrash() {
        let pages = VMPageCounts(free: 0, active: 0, inactive: 0, speculative: 0, throttled: 0, wired: 0, purgeable: 0,
                                 fileBacked: 0, anonymous: 0, compressorOccupied: 0, compressorStored: 0)
        let breakdown = MemoryBreakdown(statistics: Fixtures.statistics(pages: pages, physicalMemory: 0, usableMemory: nil))
        #expect(breakdown.usedFraction == 0)
        #expect(breakdown.compressionRatio == nil)
    }

    @Test(arguments: [4_096 as UInt64, 16_384])
    func worksWithBothPageSizes(pageSize: UInt64) {
        let statistics = Fixtures.statistics(pageSize: pageSize, usableMemory: nil)
        let breakdown = MemoryBreakdown(statistics: statistics)
        #expect(breakdown.wired == Fixtures.realPages.wired * pageSize)
    }
}

@Suite("Memory activity (counter deltas)")
struct MemoryActivityTests {
    @Test func computesDeltasAndRates() throws {
        let old = Fixtures.statistics(uptime: 100)
        var counters = Fixtures.realCounters
        counters.swapOuts += 640      // 640 pages × 16 KB = 10 MB
        counters.swapIns += 64
        counters.compressions += 5_000
        let new = Fixtures.statistics(uptime: 105, counters: counters)
        let activity = try #require(MemoryActivity.between(old, new, maximumInterval: 300))
        #expect(activity.interval == 5)
        #expect(activity.swapOutBytes == 10 * MemoryUnits.mebibyte)
        #expect(activity.swapInBytes == MemoryUnits.mebibyte)
        #expect(activity.compressedPages == 5_000)
        #expect(activity.swapOutRate == Double(2 * MemoryUnits.mebibyte))
    }

    @Test func rejectsCounterResets() {
        let old = Fixtures.statistics(uptime: 100)
        var counters = Fixtures.realCounters
        counters.pageIns -= 1
        let new = Fixtures.statistics(uptime: 105, counters: counters)
        #expect(MemoryActivity.between(old, new, maximumInterval: 300) == nil)
    }

    @Test func rejectsInvalidIntervals() {
        let old = Fixtures.statistics(uptime: 100)
        #expect(MemoryActivity.between(old, Fixtures.statistics(uptime: 100), maximumInterval: 300) == nil)
        #expect(MemoryActivity.between(old, Fixtures.statistics(uptime: 90), maximumInterval: 300) == nil)
        #expect(MemoryActivity.between(old, Fixtures.statistics(uptime: 1_000), maximumInterval: 300) == nil)
        #expect(MemoryActivity.between(old, Fixtures.statistics(uptime: 105, pageSize: 4_096), maximumInterval: 300) == nil)
    }

    @Test func trackerResetsBaselineAcrossGaps() {
        var tracker = ActivityTracker(maximumInterval: 300)
        #expect(tracker.record(Fixtures.statistics(uptime: 100)) == nil)
        #expect(tracker.record(Fixtures.statistics(uptime: 101)) != nil)
        tracker.reset()   // e.g. system sleep
        #expect(tracker.record(Fixtures.statistics(uptime: 102)) == nil)
        #expect(tracker.record(Fixtures.statistics(uptime: 103)) != nil)
    }

    @Test func addingSumsAndSaturates() {
        let a = Fixtures.activity(interval: 1, swapOut: 10, swapIn: .max)
        let b = Fixtures.activity(interval: 2, swapOut: 5, swapIn: 1)
        let sum = a.adding(b)
        #expect(sum.interval == 3)
        #expect(sum.swapOutBytes == 15)
        #expect(sum.swapInBytes == .max)
    }
}

@Suite("Memory pressure")
struct MemoryPressureTests {
    @Test(arguments: [(Int32(1), MemoryPressureLevel.normal), (2, .warning), (4, .critical)])
    func mapsKernelValues(raw: Int32, expected: MemoryPressureLevel) {
        #expect(MemoryPressureLevel(kernelValue: raw) == expected)
    }

    @Test(arguments: [Int32(0), 3, 8, -1, 100])
    func rejectsUnknownKernelValues(raw: Int32) {
        #expect(MemoryPressureLevel(kernelValue: raw) == nil)
    }

    @Test func mapsDispatchEvents() {
        #expect(PressureEventReading(event: .normal) == .level(.normal))
        #expect(PressureEventReading(event: .warning) == .level(.warning))
        #expect(PressureEventReading(event: .critical) == .level(.critical))
        // Merged transitions: the order is lost, so the current level is unknown.
        #expect(PressureEventReading(event: [.warning, .normal]) == .ambiguous)
        #expect(PressureEventReading(event: [.warning, .critical]) == .ambiguous)
        #expect(PressureEventReading(event: []) == nil)
    }

    @Test func orderingFollowsSeverity() {
        #expect(MemoryPressureLevel.normal < .warning)
        #expect(MemoryPressureLevel.warning < .critical)
        #expect(!MemoryPressureLevel.normal.isElevated)
    }

    @Test func stateTracksTransitions() {
        var state = PressureState.unknown
        let t0 = Fixtures.reference

        let first = state.update(level: .warning, source: .kernelLevel, at: t0)
        #expect(first.changed && first.previous == nil)
        // Already elevated when monitoring began: the start time is only a lower bound.
        #expect(state.observedSinceIsLowerBound)

        let same = state.update(level: .warning, source: .systemEvent, at: t0.addingTimeInterval(30))
        #expect(!same.changed)
        #expect(state.duration(at: t0.addingTimeInterval(60)) == 60)

        let change = state.update(level: .normal, source: .systemEvent, at: t0.addingTimeInterval(90))
        #expect(change.changed && change.previous == .warning)
        #expect(!state.observedSinceIsLowerBound)
        #expect(state.duration(at: t0.addingTimeInterval(100)) == 10)
    }
}
