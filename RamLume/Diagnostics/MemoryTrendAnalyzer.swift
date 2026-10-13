import Foundation

/// Recent memory behaviour summarized from raw samples. Every figure is derived from measured
/// samples; values are `nil` when there isn't enough data rather than estimated.
struct MemoryTrends: Sendable, Equatable {
    /// Seconds of uninterrupted monitoring ending at the newest sample (capped at the analysis window).
    var continuousCoverage: TimeInterval
    /// Samples in the analysis window.
    var sampleCount: Int

    /// Swap written to disk during the recent-activity window, or `nil` without counter data.
    var swapOutRecent: UInt64?
    var swapInRecent: UInt64?
    var pageOutRecent: UInt64?
    /// Seconds of counter data behind the `…Recent` values.
    var activityCoverage: TimeInterval

    /// Change in swap used over the change window (newest − oldest sample of the current segment).
    var swapUsedChange: Int64?
    var compressedChange: Int64?
    var usedChange: Int64?
    /// Seconds the change values span.
    var changeSpan: TimeInterval

    /// Seconds spent at warning or critical pressure during the pressure window.
    var elevatedPressureDuration: TimeInterval
    /// The most recent sample at warning or worse in the analysis window.
    var lastElevatedPressure: Date?

    static let empty = MemoryTrends(
        continuousCoverage: 0, sampleCount: 0,
        swapOutRecent: nil, swapInRecent: nil, pageOutRecent: nil, activityCoverage: 0,
        swapUsedChange: nil, compressedChange: nil, usedChange: nil, changeSpan: 0,
        elevatedPressureDuration: 0, lastElevatedPressure: nil
    )
}

enum MemoryTrendAnalyzer {
    /// Window for swap/paging activity totals.
    static let recentActivityWindow: TimeInterval = 300
    /// Window for "how much did swap/compression grow" (matches the raw history span).
    static let changeWindow: TimeInterval = 900
    /// Window for time spent under elevated pressure.
    static let pressureWindow: TimeInterval = 600
    /// Consecutive samples further apart than this belong to different segments.
    static let continuityThreshold: TimeInterval = HistoryTier.raw.continuityThreshold
    /// No single sample is credited with more than this many seconds of pressure.
    static let maximumSampleWeight: TimeInterval = 60

    /// - Parameter samples: raw samples in chronological order.
    static func analyze(samples: [HistoryPoint], gaps: [HistoryGap], now: Date) -> MemoryTrends {
        let windowStart = now.addingTimeInterval(-changeWindow)
        let window = samples.filter { $0.start >= windowStart && $0.start <= now }
        guard let newest = window.last else { return .empty }

        // Walk back from the newest sample to find the current uninterrupted segment.
        var segmentStartIndex = window.count - 1
        while segmentStartIndex > 0 {
            let previous = window[segmentStartIndex - 1]
            let current = window[segmentStartIndex]
            if !areContinuous(previous, current, gaps: gaps) { break }
            segmentStartIndex -= 1
        }
        let segment = Array(window[segmentStartIndex...])
        let segmentStart = segment.first?.start ?? newest.start

        var trends = MemoryTrends.empty
        trends.sampleCount = window.count
        trends.continuousCoverage = newest.start.timeIntervalSince(segmentStart)

        // Activity totals over the recent window.
        let activityStart = now.addingTimeInterval(-recentActivityWindow)
        let activities = window.filter { $0.start >= activityStart }.compactMap(\.activity)
        if !activities.isEmpty {
            let total = activities.dropFirst().reduce(activities[0]) { $0.adding($1) }
            trends.swapOutRecent = total.swapOutBytes
            trends.swapInRecent = total.swapInBytes
            trends.pageOutRecent = total.pageOutBytes
            trends.activityCoverage = total.interval
        }

        // Changes across the current segment.
        if let first = segment.first, segment.count >= 2 {
            trends.changeSpan = newest.start.timeIntervalSince(first.start)
            if let a = first.swapUsedPeak, let b = newest.swapUsedPeak {
                trends.swapUsedChange = MemoryUnits.signedDifference(b, a)
            }
            trends.compressedChange = MemoryUnits.signedDifference(UInt64(max(newest.compressed, 0)), UInt64(max(first.compressed, 0)))
            trends.usedChange = MemoryUnits.signedDifference(UInt64(max(newest.used, 0)), UInt64(max(first.used, 0)))
        }

        // Time at elevated pressure, weighting each sample by the time since the previous one.
        let pressureStart = now.addingTimeInterval(-pressureWindow)
        var elevated: TimeInterval = 0
        for (index, sample) in window.enumerated() where sample.start >= pressureStart {
            guard let level = sample.worstPressure, level.isElevated else { continue }
            let weight: TimeInterval
            if let interval = sample.activity?.interval {
                weight = interval
            } else if index > 0, areContinuous(window[index - 1], sample, gaps: gaps) {
                weight = sample.start.timeIntervalSince(window[index - 1].start)
            } else {
                weight = 0
            }
            elevated += min(max(weight, 0), maximumSampleWeight)
        }
        trends.elevatedPressureDuration = elevated
        trends.lastElevatedPressure = window.last { $0.worstPressure?.isElevated == true }?.start

        return trends
    }

    static func areContinuous(_ a: HistoryPoint, _ b: HistoryPoint, gaps: [HistoryGap]) -> Bool {
        let spacing = b.start.timeIntervalSince(a.end)
        if spacing > continuityThreshold { return false }
        return !gaps.contains { $0.start >= a.start && $0.start < b.start }
    }
}
