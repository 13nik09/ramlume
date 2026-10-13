import Foundation
import Testing
@testable import RamLume

@Suite("History aggregation")
struct MemoryHistoryTests {
    let start = Date(timeIntervalSince1970: 1_790_000_100)   // aligned to 10 s, 60 s, and 300 s

    @Test func aggregatesIntoAlignedBuckets() throws {
        var history = MemoryHistory(retention: .oneDay)
        // 25 seconds of 1 Hz samples: buckets [0,10), [10,20), and an in-progress [20,30).
        for second in 0..<25 {
            let used = Double(second) * Double(Fixtures.mib) + Double(4 * Fixtures.gib)
            history.append(Fixtures.point(at: start.addingTimeInterval(Double(second)), used: used))
        }
        let closed = history.points(in: .tenSeconds)
        #expect(closed.count == 2)
        let first = try #require(closed.first)
        #expect(first.start == start)
        #expect(first.duration == 10)
        #expect(first.sampleCount == 10)
        // Mean of 0…9 MB offsets = 4.5 MB above 4 GB; peak keeps the maximum.
        #expect(abs(first.used - (Double(4 * Fixtures.gib) + 4.5 * Double(Fixtures.mib))) < 1)
        #expect(first.usedPeak == 4 * Fixtures.gib + 9 * Fixtures.mib)

        // The in-progress bucket is included in chart series but not yet closed.
        #expect(history.pending[.tenSeconds]?.sampleCount == 5)
        #expect(history.pending[.oneMinute]?.sampleCount == 25)
    }

    @Test func mergingCombinesActivityAndWorstPressure() {
        let a = Fixtures.point(at: start, pressure: .normal, activity: Fixtures.activity(interval: 5, swapOut: 100))
        let b = Fixtures.point(at: start.addingTimeInterval(5), pressure: .warning, activity: Fixtures.activity(interval: 5, swapOut: 50))
        let c = Fixtures.point(at: start.addingTimeInterval(10), swapUsed: nil, pressure: nil, activity: nil)
        let merged = a.merged(with: b).merged(with: c)
        #expect(merged.sampleCount == 3)
        #expect(merged.activity?.swapOutBytes == 150)
        #expect(merged.activity?.interval == 10)
        #expect(merged.worstPressure == .warning)
        #expect(merged.pressureSampleCount == 2)
        #expect(merged.elevatedPressureSamples == 1)
        // Swap mean only covers samples where swap was readable.
        #expect(merged.swapSampleCount == 2)
    }

    @Test func criticalSamplesMergeIntoPressureShares() throws {
        let points = [
            Fixtures.point(at: start, pressure: .critical),
            Fixtures.point(at: start.addingTimeInterval(5), pressure: .warning),
            Fixtures.point(at: start.addingTimeInterval(10), pressure: .normal),
            Fixtures.point(at: start.addingTimeInterval(15), pressure: .normal),
            Fixtures.point(at: start.addingTimeInterval(20), pressure: nil),
        ]
        let merged = points.dropFirst().reduce(points[0]) { $0.merged(with: $1) }
        #expect(merged.criticalPressureSamples == 1)
        #expect(merged.elevatedPressureSamples == 2)
        #expect(merged.pressureSampleCount == 4)
        let shares = try #require(merged.pressureShares)
        #expect(shares.normal == 0.5)
        #expect(shares.warning == 0.25)
        #expect(shares.critical == 0.25)
        #expect(Fixtures.point(at: start, pressure: nil).pressureShares == nil)
    }

    @Test func historyWrittenBeforeCriticalCountsDecodes() throws {
        let point = Fixtures.point(at: start, pressure: .critical)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(point)) as? [String: Any])
        #expect(object["pc"] as? Int == 1)
        object["pc"] = nil
        let legacy = try JSONDecoder().decode(HistoryPoint.self, from: JSONSerialization.data(withJSONObject: object))
        // Without the critical count, elevated samples are shown as warning: never overstated.
        #expect(legacy.criticalPressureSamples == 0)
        #expect(legacy.pressureShares?.warning == 1)
        #expect(legacy.pressureShares?.critical == 0)
    }

    @Test func clockSetBackwardsDiscardsFutureData() {
        var history = MemoryHistory(retention: .oneDay)
        for second in stride(from: 0, to: 600, by: 5) {
            history.append(Fixtures.point(at: start.addingTimeInterval(Double(second))))
        }
        #expect(history.points(in: .raw).count == 120)

        // A reading a couple of seconds early is treated as a duplicate and ignored.
        history.append(Fixtures.point(at: start.addingTimeInterval(593)))
        #expect(history.points(in: .raw).count == 120)

        // The clock jumps back five minutes: data now in the "future" is dropped and recording continues.
        let stepped = start.addingTimeInterval(295)
        history.append(Fixtures.point(at: stepped))
        let raw = history.points(in: .raw)
        #expect(raw.count == 60)
        #expect(raw.last?.start == stepped)
        #expect(raw.allSatisfy { $0.start <= stepped })
        #expect(history.points(in: .tenSeconds).allSatisfy { $0.end <= stepped })
        #expect(history.points(in: .oneMinute).allSatisfy { $0.end <= stepped })

        history.append(Fixtures.point(at: stepped.addingTimeInterval(5)))
        #expect(history.points(in: .raw).count == 61)
    }

    @Test func rawTierIsBounded() {
        var history = MemoryHistory(retention: .sevenDays)
        for second in 0..<(HistoryTier.raw.capacity + 500) {
            history.append(Fixtures.point(at: start.addingTimeInterval(Double(second))))
        }
        #expect(history.points(in: .raw).count == HistoryTier.raw.capacity)
        #expect(history.points(in: .tenSeconds).count <= HistoryTier.tenSeconds.capacity)
    }

    @Test func aggregatedTiersAreBoundedOverLongRuns() {
        var history = MemoryHistory(retention: .sevenDays)
        // Eight days at one sample per minute.
        for minute in 0..<(8 * 24 * 60) {
            history.append(Fixtures.point(at: start.addingTimeInterval(Double(minute) * 60)))
        }
        #expect(history.points(in: .tenSeconds).count <= HistoryTier.tenSeconds.capacity)
        #expect(history.points(in: .oneMinute).count <= HistoryTier.oneMinute.capacity)
        #expect(history.points(in: .fiveMinutes).count <= HistoryTier.fiveMinutes.capacity)
    }

    @Test func ignoresOutOfOrderSamples() {
        var history = MemoryHistory()
        history.append(Fixtures.point(at: start.addingTimeInterval(10)))
        history.append(Fixtures.point(at: start))
        #expect(history.points(in: .raw).count == 1)
    }

    @Test func retentionLimitsTiers() {
        var history = MemoryHistory(retention: .oneHour)
        #expect(history.activeTiers == [.tenSeconds])
        for minute in 0..<10 {
            history.append(Fixtures.point(at: start.addingTimeInterval(Double(minute) * 60)))
        }
        #expect(history.points(in: .oneMinute).isEmpty)

        history.setRetention(.sevenDays, now: start.addingTimeInterval(600))
        #expect(history.activeTiers == [.tenSeconds, .oneMinute, .fiveMinutes])
        history.setRetention(.oneHour, now: start.addingTimeInterval(600))
        #expect(history.points(in: .fiveMinutes).isEmpty)
    }

    @Test func pruneDropsExpiredData() {
        var history = MemoryHistory(retention: .oneHour)
        for second in stride(from: 0, to: 4_000, by: 10) {
            history.append(Fixtures.point(at: start.addingTimeInterval(Double(second))))
        }
        let now = start.addingTimeInterval(4_000)
        history.prune(now: now)
        #expect(history.points(in: .raw).allSatisfy { $0.start >= now.addingTimeInterval(-HistoryTier.raw.span) })
        #expect(history.points(in: .tenSeconds).allSatisfy { $0.end > now.addingTimeInterval(-3_600) })
    }

    // Scenario: sleep/wake gaps in history.
    @Test func sleepGapSplitsSegmentsAndIsReported() throws {
        var history = MemoryHistory()
        for second in stride(from: 0, through: 60, by: 5) {
            history.append(Fixtures.point(at: start.addingTimeInterval(Double(second))))
        }
        history.beginGap(at: start.addingTimeInterval(62), reason: .systemSleep)
        // The Mac sleeps for 20 minutes; the first sample after waking closes the gap.
        let wake = start.addingTimeInterval(62 + 1_200)
        for second in stride(from: 0, through: 30, by: 5) {
            history.append(Fixtures.point(at: wake.addingTimeInterval(Double(second))))
        }
        let now = wake.addingTimeInterval(30)
        let series = history.series(for: .oneHour, now: now)
        #expect(series.gaps.count == 1)
        #expect(series.gaps.first?.reason == .systemSleep)
        let segments = Set(series.points.map(\.segment))
        #expect(segments.count == 2)
        // Nothing is drawn inside the gap.
        let gap = try #require(series.gaps.first)
        #expect(!series.points.contains { $0.point.start > gap.start && $0.point.end < gap.end })
    }

    @Test func gapStartingInsideABucketDoesNotSplitIt() {
        let bucketA = Fixtures.point(at: start).aligned(to: start, duration: 10)
        let bucketB = Fixtures.point(at: start.addingTimeInterval(10)).aligned(to: start.addingTimeInterval(10), duration: 10)
        let bucketC = Fixtures.point(at: start.addingTimeInterval(600)).aligned(to: start.addingTimeInterval(600), duration: 10)
        let gap = HistoryGap(start: start.addingTimeInterval(12), end: start.addingTimeInterval(602), reason: .systemSleep)
        let segmented = MemoryHistory.segment([bucketA, bucketB, bucketC], gaps: [gap], continuityThreshold: 1_000)
        // Spacing alone wouldn't split B and C here (threshold 1,000 s); the recorded gap does.
        #expect(segmented.map(\.segment) == [0, 0, 1])
    }

    @Test func unexplainedSpacingAlsoStartsNewSegment() {
        let points = [
            Fixtures.point(at: start),
            Fixtures.point(at: start.addingTimeInterval(5)),
            Fixtures.point(at: start.addingTimeInterval(500)),   // App Nap or a suspended process
        ]
        let segmented = MemoryHistory.segment(points, gaps: [], continuityThreshold: 150)
        #expect(segmented.map(\.segment) == [0, 0, 1])
    }

    @Test func downsamplingNeverMergesAcrossBuckets() {
        let points = (0..<100).map { Fixtures.point(at: start.addingTimeInterval(Double($0))) }
            + (0..<10).map { Fixtures.point(at: start.addingTimeInterval(1_000 + Double($0))) }
        let downsampled = MemoryHistory.downsample(points, width: 10)
        #expect(downsampled.count == 11)
        #expect(downsampled.allSatisfy { $0.sampleCount == 10 })
        #expect(downsampled.last?.start == start.addingTimeInterval(1_000))
    }

    @Test func seriesIsCappedAndCoversRequestedRange() {
        var history = MemoryHistory()
        for second in 0..<900 {
            history.append(Fixtures.point(at: start.addingTimeInterval(Double(second))))
        }
        let now = start.addingTimeInterval(899)
        let series = history.series(for: .fifteenMinutes, now: now, maxPoints: 120)
        #expect(series.points.count <= 120)
        #expect(series.start == now.addingTimeInterval(-900))
        #expect(series.end == now)
        #expect(series.resolution > 0)
    }

    @Test func emptyHistoryProducesEmptySeries() {
        let series = MemoryHistory().series(for: .oneDay, now: start)
        #expect(series.isEmpty)
        #expect(series.gaps.isEmpty)
    }

    @Test func archiveRoundTripsAndRecordsDowntime() throws {
        var history = MemoryHistory(retention: .oneDay)
        for second in stride(from: 0, to: 180, by: 5) {
            history.append(Fixtures.point(at: start.addingTimeInterval(Double(second))))
        }
        let savedAt = start.addingTimeInterval(180)
        let archive = history.archive(savedAt: savedAt)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(MemoryHistory.Archive.self, from: encoder.encode(archive))
        // Means are written rounded to whole bytes; everything else round-trips exactly.
        #expect(decoded.tiers.keys == archive.tiers.keys)
        for (tier, points) in archive.tiers {
            let restored = try #require(decoded.tiers[tier])
            #expect(restored.count == points.count)
            for (a, b) in zip(points, restored) {
                #expect(a.start == b.start && a.sampleCount == b.sampleCount && a.usedPeak == b.usedPeak)
                #expect(abs(a.used - b.used) <= 0.5 && abs(a.compressed - b.compressed) <= 0.5)
            }
        }
        #expect(decoded.gaps == archive.gaps)

        // Relaunch an hour later: the downtime is recorded as a gap, not drawn as data.
        let relaunch = savedAt.addingTimeInterval(3_600)
        let restored = MemoryHistory(archive: decoded, retention: .oneDay, now: relaunch)
        #expect(restored.points(in: .oneMinute).count >= 2)
        #expect(restored.gaps.elements.contains { $0.reason == .appNotRunning && $0.end == relaunch })
        #expect(restored.points(in: .raw).isEmpty)
    }

    @Test func clearRemovesEverything() {
        var history = MemoryHistory()
        history.append(Fixtures.point(at: start))
        history.beginGap(at: start.addingTimeInterval(1), reason: .monitoringPaused)
        history.clear()
        #expect(history.points(in: .raw).isEmpty)
        #expect(history.pending.isEmpty)
        #expect(history.openGap == nil)
    }
}

@Suite("History persistence")
struct HistoryPersistenceTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "RamLumeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "History.json")
    }

    @Test func savesAndLoads() throws {
        let persistence = HistoryPersistence(fileURL: temporaryURL())
        defer { try? FileManager.default.removeItem(at: persistence.fileURL.deletingLastPathComponent()) }

        var history = MemoryHistory()
        history.append(Fixtures.point(at: Fixtures.reference))
        let file = HistoryFile(
            history: history.archive(savedAt: Fixtures.reference),
            events: [MemoryEvent(date: Fixtures.reference, kind: .monitoringStarted, title: "Monitoring started")]
        )
        try persistence.save(file)
        guard case .loaded(let loaded) = persistence.load() else {
            Issue.record("Expected a loaded history file")
            return
        }
        #expect(loaded == file)
        #expect((persistence.fileSize() ?? 0) > 0)
        try persistence.delete()
        guard case .missing = persistence.load() else {
            Issue.record("Expected the history file to be deleted")
            return
        }
    }

    @Test func corruptFileIsSetAside() throws {
        let persistence = HistoryPersistence(fileURL: temporaryURL())
        defer { try? FileManager.default.removeItem(at: persistence.fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: persistence.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: persistence.fileURL)

        guard case .unreadable = persistence.load() else {
            Issue.record("Expected an unreadable result")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: persistence.fileURL.path))
        let setAside = persistence.fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
        #expect(FileManager.default.fileExists(atPath: setAside.path))
    }
}

@MainActor
@Suite("History store")
struct HistoryStoreTests {
    let start = Fixtures.reference

    @Test func savingDropsEventsOutsideRetention() {
        let store = HistoryStore(retention: .oneHour, persistence: nil, now: start)
        store.record(MemoryEvent(date: start, kind: .monitoringStarted, title: "Monitoring started"))
        store.record(MemoryEvent(date: start.addingTimeInterval(5_000), kind: .systemSleep, title: "Mac went to sleep"))
        store.save(now: start.addingTimeInterval(7_200))
        #expect(store.events.elements.map(\.kind) == [.systemSleep])
    }

    @Test func shorterRetentionDropsOlderEvents() {
        let store = HistoryStore(retention: .oneDay, persistence: nil, now: start)
        store.record(MemoryEvent(date: start, kind: .monitoringStarted, title: "Monitoring started"))
        store.setRetention(.oneHour, now: start.addingTimeInterval(4_000))
        #expect(store.events.isEmpty)
    }
}
