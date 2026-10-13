import Foundation

/// One point of memory history: a single sample (`sampleCount == 1`, `duration == 0`) or an
/// aggregate of consecutive samples covering `[start, start + duration)`.
///
/// Aggregates keep means and peaks. Merging is associative, so the same raw samples can feed
/// every history tier independently. Nothing is interpolated: a bucket exists only if at least
/// one real sample fell inside it.
struct HistoryPoint: Sendable, Equatable, Codable {
    var start: Date
    var duration: TimeInterval
    var sampleCount: Int

    /// Installed memory at the time (constant on a given Mac).
    var total: UInt64
    var used: Double
    var usedPeak: UInt64
    var app: Double
    var wired: Double
    var compressed: Double
    var compressedOriginal: Double
    var cachedFiles: Double
    var free: Double

    /// Mean swap used over samples where swap was readable; `nil` if it never was.
    var swapUsed: Double?
    var swapUsedPeak: UInt64?
    /// Largest swap allocation seen in this point.
    var swapTotal: UInt64?
    var swapSampleCount: Int

    /// Worst kernel pressure level observed; `nil` if the level was unknown for every sample.
    var worstPressure: MemoryPressureLevel?
    var pressureSampleCount: Int
    /// Samples at warning or critical.
    var elevatedPressureSamples: Int
    /// Samples at critical (a subset of `elevatedPressureSamples`).
    var criticalPressureSamples: Int = 0

    /// Summed counter deltas; `nil` when no sample in this point had comparable counters.
    var activity: MemoryActivity?

    var end: Date { start.addingTimeInterval(duration) }
    /// Where the point is drawn on a time axis.
    var plotDate: Date { start.addingTimeInterval(duration / 2) }

    /// The fraction of samples with known pressure that were at warning or worse.
    var elevatedPressureFraction: Double? {
        pressureSampleCount > 0 ? Double(elevatedPressureSamples) / Double(pressureSampleCount) : nil
    }

    /// Share of samples with known pressure at each level (normal, warning, critical), summing to 1.
    var pressureShares: (normal: Double, warning: Double, critical: Double)? {
        guard pressureSampleCount > 0 else { return nil }
        let total = Double(pressureSampleCount)
        let critical = Double(min(criticalPressureSamples, elevatedPressureSamples)) / total
        let warning = Double(elevatedPressureSamples) / total - critical
        return (max(1 - critical - warning, 0), max(warning, 0), critical)
    }
}

extension HistoryPoint {
    /// Creates a single-sample point from a snapshot.
    init(snapshot: MemorySnapshot, pressure: MemoryPressureLevel?) {
        let breakdown = snapshot.breakdown
        start = snapshot.timestamp
        duration = 0
        sampleCount = 1
        total = breakdown.total
        used = Double(breakdown.used)
        usedPeak = breakdown.used
        app = Double(breakdown.app)
        wired = Double(breakdown.wired)
        compressed = Double(breakdown.compressed)
        compressedOriginal = Double(breakdown.compressedOriginal)
        cachedFiles = Double(breakdown.cachedFiles)
        free = Double(breakdown.free)
        swapUsed = snapshot.swap.map { Double($0.used) }
        swapUsedPeak = snapshot.swap?.used
        swapTotal = snapshot.swap?.total
        swapSampleCount = snapshot.swap == nil ? 0 : 1
        worstPressure = pressure
        pressureSampleCount = pressure == nil ? 0 : 1
        elevatedPressureSamples = (pressure?.isElevated ?? false) ? 1 : 0
        criticalPressureSamples = pressure == .critical ? 1 : 0
        activity = snapshot.activity
    }

    /// Returns a point covering both inputs. `self` must not start after `other` ends for the
    /// covered interval to be meaningful; callers merge points in chronological order.
    func merged(with other: HistoryPoint) -> HistoryPoint {
        let count = sampleCount + other.sampleCount
        func mean(_ a: Double, _ b: Double) -> Double {
            count > 0 ? (a * Double(sampleCount) + b * Double(other.sampleCount)) / Double(count) : 0
        }

        var result = self
        let newStart = min(start, other.start)
        let newEnd = max(end, other.end)
        result.start = newStart
        result.duration = newEnd.timeIntervalSince(newStart)
        result.sampleCount = count
        result.total = max(total, other.total)
        result.used = mean(used, other.used)
        result.usedPeak = max(usedPeak, other.usedPeak)
        result.app = mean(app, other.app)
        result.wired = mean(wired, other.wired)
        result.compressed = mean(compressed, other.compressed)
        result.compressedOriginal = mean(compressedOriginal, other.compressedOriginal)
        result.cachedFiles = mean(cachedFiles, other.cachedFiles)
        result.free = mean(free, other.free)

        let swapCount = swapSampleCount + other.swapSampleCount
        switch (swapUsed, other.swapUsed) {
        case let (a?, b?):
            result.swapUsed = (a * Double(swapSampleCount) + b * Double(other.swapSampleCount)) / Double(max(swapCount, 1))
        case let (a?, nil): result.swapUsed = a
        case let (nil, b?): result.swapUsed = b
        case (nil, nil): result.swapUsed = nil
        }
        result.swapUsedPeak = Self.maxOptional(swapUsedPeak, other.swapUsedPeak)
        result.swapTotal = Self.maxOptional(swapTotal, other.swapTotal)
        result.swapSampleCount = swapCount

        result.worstPressure = Self.maxOptional(worstPressure, other.worstPressure)
        result.pressureSampleCount = pressureSampleCount + other.pressureSampleCount
        result.elevatedPressureSamples = elevatedPressureSamples + other.elevatedPressureSamples
        result.criticalPressureSamples = criticalPressureSamples + other.criticalPressureSamples

        switch (activity, other.activity) {
        case let (a?, b?): result.activity = a.adding(b)
        case let (a?, nil): result.activity = a
        case let (nil, b?): result.activity = b
        case (nil, nil): result.activity = nil
        }
        return result
    }

    /// Re-labels the point as covering a whole aligned bucket.
    func aligned(to bucketStart: Date, duration bucketDuration: TimeInterval) -> HistoryPoint {
        var copy = self
        copy.start = bucketStart
        copy.duration = bucketDuration
        return copy
    }

    private static func maxOptional<T: Comparable>(_ a: T?, _ b: T?) -> T? {
        switch (a, b) {
        case let (a?, b?): max(a, b)
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(Date.self, forKey: .start)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        sampleCount = try container.decode(Int.self, forKey: .sampleCount)
        total = try container.decode(UInt64.self, forKey: .total)
        used = try container.decode(Double.self, forKey: .used)
        usedPeak = try container.decode(UInt64.self, forKey: .usedPeak)
        app = try container.decode(Double.self, forKey: .app)
        wired = try container.decode(Double.self, forKey: .wired)
        compressed = try container.decode(Double.self, forKey: .compressed)
        compressedOriginal = try container.decode(Double.self, forKey: .compressedOriginal)
        cachedFiles = try container.decode(Double.self, forKey: .cachedFiles)
        free = try container.decode(Double.self, forKey: .free)
        swapUsed = try container.decodeIfPresent(Double.self, forKey: .swapUsed)
        swapUsedPeak = try container.decodeIfPresent(UInt64.self, forKey: .swapUsedPeak)
        swapTotal = try container.decodeIfPresent(UInt64.self, forKey: .swapTotal)
        swapSampleCount = try container.decode(Int.self, forKey: .swapSampleCount)
        worstPressure = try container.decodeIfPresent(MemoryPressureLevel.self, forKey: .worstPressure)
        pressureSampleCount = try container.decode(Int.self, forKey: .pressureSampleCount)
        elevatedPressureSamples = try container.decode(Int.self, forKey: .elevatedPressureSamples)
        criticalPressureSamples = try container.decodeIfPresent(Int.self, forKey: .criticalPressureSamples) ?? 0
        activity = try container.decodeIfPresent(MemoryActivity.self, forKey: .activity)
    }

    /// Writes averages rounded to whole bytes: sub-byte fractions carry no information and would
    /// roughly double the size of the history file.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(start, forKey: .start)
        try container.encode(duration, forKey: .duration)
        try container.encode(sampleCount, forKey: .sampleCount)
        try container.encode(total, forKey: .total)
        try container.encode(used.rounded(), forKey: .used)
        try container.encode(usedPeak, forKey: .usedPeak)
        try container.encode(app.rounded(), forKey: .app)
        try container.encode(wired.rounded(), forKey: .wired)
        try container.encode(compressed.rounded(), forKey: .compressed)
        try container.encode(compressedOriginal.rounded(), forKey: .compressedOriginal)
        try container.encode(cachedFiles.rounded(), forKey: .cachedFiles)
        try container.encode(free.rounded(), forKey: .free)
        try container.encodeIfPresent(swapUsed?.rounded(), forKey: .swapUsed)
        try container.encodeIfPresent(swapUsedPeak, forKey: .swapUsedPeak)
        try container.encodeIfPresent(swapTotal, forKey: .swapTotal)
        try container.encode(swapSampleCount, forKey: .swapSampleCount)
        try container.encodeIfPresent(worstPressure, forKey: .worstPressure)
        try container.encode(pressureSampleCount, forKey: .pressureSampleCount)
        try container.encode(elevatedPressureSamples, forKey: .elevatedPressureSamples)
        if criticalPressureSamples > 0 {
            try container.encode(criticalPressureSamples, forKey: .criticalPressureSamples)
        }
        try container.encodeIfPresent(activity, forKey: .activity)
    }

    // Short keys keep the on-disk history compact (thousands of points).
    enum CodingKeys: String, CodingKey {
        case start = "t", duration = "d", sampleCount = "n", total = "tot"
        case used = "u", usedPeak = "up", app = "a", wired = "w", compressed = "c"
        case compressedOriginal = "co", cachedFiles = "cf", free = "f"
        case swapUsed = "su", swapUsedPeak = "sp", swapTotal = "st", swapSampleCount = "sn"
        case worstPressure = "p", pressureSampleCount = "pn", elevatedPressureSamples = "pe"
        case criticalPressureSamples = "pc"
        case activity = "act"
    }
}
