import Foundation
import Testing
@testable import RamLume

/// The data behind the history charts: what each mark covers and how tall it is.
@MainActor
@Suite("Chart data")
struct ChartDataTests {
    let start = Date(timeIntervalSince1970: 1_790_000_100)

    private func series(_ points: [HistoryPoint], segments: [Int]? = nil, resolution: TimeInterval = 0) -> HistorySeries {
        let chartPoints = points.enumerated().map { index, point in
            ChartPoint(id: index, segment: segments?[index] ?? 0, point: point)
        }
        return HistorySeries(range: .fifteenMinutes, start: start.addingTimeInterval(-300), end: start.addingTimeInterval(600),
                             points: chartPoints, gaps: [], resolution: resolution)
    }

    /// An aggregated point with the given number of samples at each pressure level.
    private func bucket(at offset: TimeInterval, duration: TimeInterval, normal: Int, warning: Int = 0, critical: Int = 0,
                        activity: MemoryActivity? = nil) -> HistoryPoint {
        var point = Fixtures.point(at: start.addingTimeInterval(offset), activity: activity)
        point.duration = duration
        point.sampleCount = normal + warning + critical
        point.pressureSampleCount = normal + warning + critical
        point.elevatedPressureSamples = warning + critical
        point.criticalPressureSamples = critical
        point.worstPressure = critical > 0 ? .critical : (warning > 0 ? .warning : .normal)
        return point
    }

    // MARK: Swap activity

    @Test func swapBarsCoverTheTimeTheirCountersCover() throws {
        let raw = Fixtures.point(at: start, activity: Fixtures.activity(interval: 5, swapOut: 50 * Fixtures.mib))
        let aggregated = bucket(at: 60, duration: 60, normal: 12, activity: Fixtures.activity(interval: 60, swapOut: 120 * Fixtures.mib))
        let afterGap = Fixtures.point(at: start.addingTimeInterval(200), activity: nil)
        let bars = SwapActivityChart.bars(for: series([raw, aggregated, afterGap]))
        #expect(bars.count == 2)   // no counters, no bar (rather than a zero)

        let first = try #require(bars.first)
        #expect(first.start == start.addingTimeInterval(-5))
        #expect(first.end == start)
        #expect(first.writeRate == Double(10 * Fixtures.mib))

        let second = try #require(bars.last)
        #expect(second.start == start.addingTimeInterval(60))
        #expect(second.end == start.addingTimeInterval(120))
        #expect(second.writeRate == Double(2 * Fixtures.mib))
        #expect(second.written == 120 * Fixtures.mib)
    }

    @Test func swapBarHeightsDontDependOnTheSamplingInterval() {
        // 1 MB/s of swap writes, sampled every second or every five seconds.
        let everySecond = (1...10).map {
            Fixtures.point(at: start.addingTimeInterval(Double($0)), activity: Fixtures.activity(interval: 1, swapOut: Fixtures.mib))
        }
        let everyFiveSeconds = (1...2).map {
            Fixtures.point(at: start.addingTimeInterval(Double($0) * 5), activity: Fixtures.activity(interval: 5, swapOut: 5 * Fixtures.mib))
        }
        let bars = SwapActivityChart.bars(for: series(everySecond)) + SwapActivityChart.bars(for: series(everyFiveSeconds))
        #expect(bars.count == 12)
        #expect(bars.allSatisfy { $0.writeRate == Double(Fixtures.mib) })
    }

    @Test func swapChartIsTallEnoughForAllocatedSwap() {
        let point = Fixtures.point(at: start, swapUsed: 332 * Fixtures.mib, swapTotal: 2 * Fixtures.gib)
        #expect(SwapChart.yMaximum(for: series([point])) == Double(2 * Fixtures.gib))
        #expect(point.swapUsed == Double(332 * Fixtures.mib))
        let small = Fixtures.point(at: start, swapUsed: 0, swapTotal: 0)
        #expect(SwapChart.yMaximum(for: series([small])) == Double(Fixtures.gib))
    }

    @Test func pressureCaptionDoesNotCallAFirstReadingAChange() {
        let figures = MemoryFigures(Fixtures.snapshot())
        let now = Scenario.now
        var firstReading = PressureState.unknown
        _ = firstReading.update(level: .normal, source: .kernelLevel, at: now.addingTimeInterval(-10))
        #expect(KeyFigures(figures: figures, pressure: firstReading, trends: .empty, now: now).pressureCaption == "from macOS")

        var changed = firstReading
        _ = changed.update(level: .warning, source: .kernelLevel, at: now.addingTimeInterval(-5))
        #expect(KeyFigures(figures: figures, pressure: changed, trends: .empty, now: now).pressureCaption == "just changed")
        #expect(KeyFigures(figures: figures, pressure: firstReading, trends: .empty, now: now.addingTimeInterval(400)).pressureCaption == "for at least 6 min")
    }

    // MARK: Pressure timeline

    @Test func pressureColumnsShowTheShareOfSamplesAtEachLevel() throws {
        let point = bucket(at: 0, duration: 300, normal: 52, warning: 6, critical: 2)
        let columns = PressureTimeline.columns(for: series([point], resolution: 300))
        let column = try #require(columns.first)
        #expect(column.end == start.addingTimeInterval(300))
        #expect(abs(column.warning - 0.1) < 1e-9)
        #expect(abs(column.critical - 2.0 / 60) < 1e-9)
        // 8 of 60 samples elevated over five minutes: about 40 seconds, not the whole bucket.
        #expect(abs(column.elevatedSeconds - 40) < 1e-6)
        #expect(PressureTimeline.accessibilitySummary(columns) == "Elevated for about 40 s")

        let slices = PressureTimeline.slices(for: columns)
        #expect(slices.map(\.level) == [.critical, .warning, .normal])
        #expect(slices.first?.lower == 0)
        #expect(abs((slices.last?.upper ?? 0) - 1) < 1e-9)
        for (lower, upper) in zip(slices, slices.dropFirst()) {
            #expect(abs(lower.upper - upper.lower) < 1e-9)
        }
    }

    @Test func rawSamplesLastUntilTheNextSampleInTheirSegment() {
        let offsets: [TimeInterval] = [0, 5, 10, 400]
        let points = offsets.map { Fixtures.point(at: start.addingTimeInterval($0), pressure: $0 == 5 ? .warning : .normal) }
        let columns = PressureTimeline.columns(for: series(points, segments: [0, 0, 0, 1]))
        // The last sample before a gap, and the newest sample, aren't stretched over unknown time.
        #expect(columns.map { $0.end.timeIntervalSince($0.start) } == [5, 5, 1, 1])
        #expect(PressureTimeline.accessibilitySummary(columns) == "Elevated for about 5 s")
    }

    @Test func adjacentColumnsWithTheSameSharesShareOneMark() {
        let points = [
            bucket(at: 0, duration: 30, normal: 6),
            bucket(at: 30, duration: 30, normal: 6),
            bucket(at: 60, duration: 30, normal: 5, warning: 1),
            bucket(at: 120, duration: 30, normal: 6),    // after a gap: separate
        ]
        let columns = PressureTimeline.columns(for: series(points, resolution: 30))
        #expect(columns.count == 4)   // hover still reports each point
        let slices = PressureTimeline.slices(for: columns)
        #expect(slices.map(\.level) == [.normal, .warning, .normal, .normal])
        #expect(slices[0].start == start && slices[0].end == start.addingTimeInterval(60))
        #expect(slices[3].start == start.addingTimeInterval(120))
    }

    @Test func unknownPressureIsLeftBlank() {
        let points = [Fixtures.point(at: start, pressure: nil), Fixtures.point(at: start.addingTimeInterval(5), pressure: .normal)]
        let columns = PressureTimeline.columns(for: series(points))
        #expect(columns.count == 1)
        #expect(columns.first?.start == start.addingTimeInterval(5))
        #expect(PressureTimeline.accessibilitySummary(columns) == "Normal throughout")
        #expect(PressureTimeline.accessibilitySummary([]) == "No data")
    }
}

/// The crosshair's hover logic. The view writes its state only when `resolve` returns something
/// different, so these properties are what keep hover from causing extra redraws.
@Suite("Chart hover")
struct ChartHoverStateTests {
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    /// The plot starts 40 pt in; each point of x is one second after `start`.
    let plot = CGRect(x: 40, y: 10, width: 800, height: 300)
    var dates: [Date] { stride(from: 0.0, through: 800, by: 100).map { start.addingTimeInterval($0) } }
    var gap: HistoryGap { HistoryGap(start: start.addingTimeInterval(320), end: start.addingTimeInterval(480), reason: .appNotRunning) }

    func dateAtX(_ x: CGFloat) -> Date? { start.addingTimeInterval(Double(x)) }

    func resolve(_ location: CGPoint?, dates: [Date]? = nil, gaps: [HistoryGap]? = nil) -> ChartHoverState {
        ChartHoverState.resolve(location: location, plot: plot, dates: dates ?? self.dates, gaps: gaps ?? [gap], dateAtX: dateAtX)
    }

    @Test func repeatedIdenticalPositionsAreNotChanges() {
        let first = resolve(CGPoint(x: 140, y: 100))
        #expect(first.target == .point(1))
        for _ in 0..<100 {
            #expect(resolve(CGPoint(x: 140, y: 100)) == first)
        }
        // Moving while staying nearest to the same point isn't a change either.
        #expect(resolve(CGPoint(x: 152, y: 40)) == first)
    }

    @Test func enteringLeavingAndEdges() {
        #expect(resolve(nil) == .idle)
        #expect(resolve(CGPoint(x: 30, y: 100)) == .idle)
        #expect(resolve(CGPoint(x: 841, y: 100)) == .idle)
        #expect(resolve(CGPoint(x: 40, y: 100)).target == .point(0))
        #expect(resolve(CGPoint(x: 840, y: 100)).target == .point(8))
    }

    @Test func gapsTargetTheGapAndIgnoreSubPointJitter() {
        let over = resolve(CGPoint(x: 440.2, y: 100))
        #expect(over.target == .gap(gap))
        #expect(over.gapPointerX == 440)
        #expect(resolve(CGPoint(x: 440.4, y: 100)) == over)
        #expect(resolve(CGPoint(x: 441, y: 100)) != over)
        #expect(resolve(CGPoint(x: 359, y: 100)).target == .point(3))
    }

    @Test func emptyAndSinglePointSeries() {
        #expect(resolve(CGPoint(x: 400, y: 100), dates: [], gaps: []) == .idle)
        let single = [start.addingTimeInterval(500)]
        #expect(resolve(CGPoint(x: 100, y: 100), dates: single, gaps: []).target == .point(0))
        #expect(resolve(CGPoint(x: 800, y: 100), dates: single, gaps: []).target == .point(0))
    }

    @Test func noDateOrNoPlotMeansNoTarget() {
        #expect(ChartHoverState.resolve(location: CGPoint(x: 400, y: 100), plot: plot, dates: dates, gaps: [], dateAtX: { _ in nil }) == .idle)
        #expect(ChartHoverState.resolve(location: CGPoint(x: 400, y: 100), plot: .zero, dates: dates, gaps: [], dateAtX: dateAtX) == .idle)
    }

    @Test func aFastSweepWritesOnlyWhenTheTargetChanges() {
        var state = ChartHoverState.idle
        var writes = 0
        var events = 0
        for x in stride(from: 0.0, through: 900, by: 3) {
            events += 1
            let next = resolve(CGPoint(x: x, y: 100))
            if next != state {
                state = next
                writes += 1
            }
        }
        // 9 points, the pointer moving across the 160 pt gap in 3 pt steps, and leaving the plot.
        #expect(writes <= 9 + 54 + 3)
        #expect(writes < events / 4)
    }

    @Test func dataArrivingWhileHovering() {
        let location = CGPoint(x: 540, y: 100)
        let before = resolve(location)
        #expect(before.target == .point(5))
        // A new sample on the right doesn't change what's under the pointer…
        #expect(resolve(location, dates: dates + [start.addingTimeInterval(900)]) == before)
        // …and when the oldest drops off, the same position maps to the shifted index.
        #expect(resolve(location, dates: Array(dates.dropFirst())).target == .point(4))
    }

    @Test func rangeChangesResolveIndependentlyOfThePreviousState() {
        let coarse = stride(from: 0.0, through: 800, by: 400).map { start.addingTimeInterval($0) }
        #expect(resolve(CGPoint(x: 300, y: 100), dates: coarse, gaps: []).target == .point(1))
        #expect(resolve(CGPoint(x: 300, y: 100), dates: dates, gaps: []).target == .point(3))
    }
}
