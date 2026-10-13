import Foundation

/// How much paging, swapping, and compression happened between two readings.
///
/// Every value is a difference between two measured cumulative counters. Byte values are
/// page counts multiplied by the kernel page size. For swap, the kernel counts the pages of
/// compressed segments written to or read from the swap files, so the byte figures describe
/// swap I/O, not the uncompressed size of the data.
struct MemoryActivity: Sendable, Equatable, Codable {
    /// Awake seconds covered by these deltas.
    var interval: TimeInterval
    var swapInBytes: UInt64
    var swapOutBytes: UInt64
    var pageInBytes: UInt64
    var pageOutBytes: UInt64
    /// Pages compressed / decompressed by the memory compressor.
    var compressedPages: UInt64
    var decompressedPages: UInt64
    var faults: UInt64

    // Short keys keep the on-disk history compact.
    enum CodingKeys: String, CodingKey {
        case interval = "i"
        case swapInBytes = "si"
        case swapOutBytes = "so"
        case pageInBytes = "pi"
        case pageOutBytes = "po"
        case compressedPages = "cp"
        case decompressedPages = "dp"
        case faults = "fa"
    }

    static let zero = MemoryActivity(
        interval: 0, swapInBytes: 0, swapOutBytes: 0, pageInBytes: 0, pageOutBytes: 0,
        compressedPages: 0, decompressedPages: 0, faults: 0
    )

    /// Computes the activity between two readings, or `nil` when the readings are not comparable:
    /// a non-positive or excessively long interval, a page-size change, or any counter that went
    /// backwards. No value is estimated in those cases.
    static func between(
        _ old: MemoryStatistics,
        _ new: MemoryStatistics,
        maximumInterval: TimeInterval
    ) -> MemoryActivity? {
        let interval = new.uptime - old.uptime
        guard interval > 0, interval <= maximumInterval, old.pageSize == new.pageSize else { return nil }

        let a = old.counters
        let b = new.counters
        guard
            let swapIns = MemoryUnits.counterDelta(from: a.swapIns, to: b.swapIns),
            let swapOuts = MemoryUnits.counterDelta(from: a.swapOuts, to: b.swapOuts),
            let pageIns = MemoryUnits.counterDelta(from: a.pageIns, to: b.pageIns),
            let pageOuts = MemoryUnits.counterDelta(from: a.pageOuts, to: b.pageOuts),
            let compressions = MemoryUnits.counterDelta(from: a.compressions, to: b.compressions),
            let decompressions = MemoryUnits.counterDelta(from: a.decompressions, to: b.decompressions),
            let faults = MemoryUnits.counterDelta(from: a.faults, to: b.faults)
        else { return nil }

        return MemoryActivity(
            interval: interval,
            swapInBytes: new.bytes(fromPages: swapIns),
            swapOutBytes: new.bytes(fromPages: swapOuts),
            pageInBytes: new.bytes(fromPages: pageIns),
            pageOutBytes: new.bytes(fromPages: pageOuts),
            compressedPages: compressions,
            decompressedPages: decompressions,
            faults: faults
        )
    }

    /// Sums two activity records (used when aggregating history).
    func adding(_ other: MemoryActivity) -> MemoryActivity {
        MemoryActivity(
            interval: interval + other.interval,
            swapInBytes: MemoryUnits.saturatingAdd(swapInBytes, other.swapInBytes),
            swapOutBytes: MemoryUnits.saturatingAdd(swapOutBytes, other.swapOutBytes),
            pageInBytes: MemoryUnits.saturatingAdd(pageInBytes, other.pageInBytes),
            pageOutBytes: MemoryUnits.saturatingAdd(pageOutBytes, other.pageOutBytes),
            compressedPages: MemoryUnits.saturatingAdd(compressedPages, other.compressedPages),
            decompressedPages: MemoryUnits.saturatingAdd(decompressedPages, other.decompressedPages),
            faults: MemoryUnits.saturatingAdd(faults, other.faults)
        )
    }

    private func perSecond(_ value: UInt64) -> Double {
        interval > 0 ? Double(value) / interval : 0
    }

    var swapInRate: Double { perSecond(swapInBytes) }
    var swapOutRate: Double { perSecond(swapOutBytes) }
    var pageInRate: Double { perSecond(pageInBytes) }
    var pageOutRate: Double { perSecond(pageOutBytes) }
    var compressionRate: Double { perSecond(compressedPages) }
    var decompressionRate: Double { perSecond(decompressedPages) }
    var faultRate: Double { perSecond(faults) }
}

/// Keeps the previous reading so consecutive samples can be turned into `MemoryActivity`.
struct ActivityTracker: Sendable {
    /// Readings further apart than this are treated as a discontinuity.
    var maximumInterval: TimeInterval
    private(set) var baseline: MemoryStatistics?

    init(maximumInterval: TimeInterval = 300) {
        self.maximumInterval = maximumInterval
    }

    /// Forgets the baseline, e.g. after sleep or a pause, so no rate spans the gap.
    mutating func reset() {
        baseline = nil
    }

    /// Records a reading and returns the activity since the previous one, if comparable.
    mutating func record(_ statistics: MemoryStatistics) -> MemoryActivity? {
        defer { baseline = statistics }
        guard let baseline else { return nil }
        return MemoryActivity.between(baseline, statistics, maximumInterval: maximumInterval)
    }
}
