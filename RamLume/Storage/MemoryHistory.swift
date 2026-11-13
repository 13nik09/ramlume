import Foundation

/// Resolutions at which history is kept.
enum HistoryTier: String, Sendable, Codable, CaseIterable {
    /// Individual samples, newest 15 minutes.
    case raw
    /// 10-second buckets, newest hour.
    case tenSeconds
    /// 1-minute buckets, newest 24 hours.
    case oneMinute
    /// 5-minute buckets, newest 7 days.
    case fiveMinutes

    /// Bucket width in seconds (0 for raw samples).
    var resolution: TimeInterval {
        switch self {
        case .raw: 0
        case .tenSeconds: 10
        case .oneMinute: 60
        case .fiveMinutes: 300
        }
    }

    /// How far back the tier reaches.
    var span: TimeInterval {
        switch self {
        case .raw: 900
        case .tenSeconds: 3_600
        case .oneMinute: 86_400
        case .fiveMinutes: 604_800
        }
    }

    /// Maximum points kept. Raw allows for 1-second sampling plus headroom; aggregated tiers
    /// hold exactly `span / resolution` buckets.
    var capacity: Int {
        switch self {
        case .raw: 1_200
        case .tenSeconds: 360
        case .oneMinute: 1_440
        case .fiveMinutes: 2_016
        }
    }

    /// Consecutive points further apart than this are drawn as separate line segments.
    /// The raw threshold covers the slowest sampling interval (60 s) with margin.
    var continuityThreshold: TimeInterval {
        switch self {
        case .raw: 150
        case .tenSeconds: 150
        case .oneMinute: 180
        case .fiveMinutes: 900
        }
    }

    static let aggregated: [HistoryTier] = [.tenSeconds, .oneMinute, .fiveMinutes]

    /// Aggregated tiers kept for a retention setting.
    static func aggregatedTiers(for retention: HistoryRetention) -> [HistoryTier] {
        aggregated.filter { $0.span <= retention.duration || $0 == .tenSeconds }
    }
}

/// A chart-ready point: an aggregated history point plus the line segment it belongs to.
struct ChartPoint: Sendable, Equatable, Identifiable {
    var id: Int
    var segment: Int
    var point: HistoryPoint

    var date: Date { point.plotDate }
}

/// History prepared for one chart range.
struct HistorySeries: Sendable, Equatable {
    var range: ChartRange
    var start: Date
    var end: Date
    var points: [ChartPoint]
    var gaps: [HistoryGap]
    /// Width each point represents (0 for raw samples).
    var resolution: TimeInterval

    var isEmpty: Bool { points.isEmpty }
    var totalMemory: UInt64? { points.last?.point.total }
}

/// Multi-resolution, bounded memory history. A value type with no I/O, so it is easy to test.
struct MemoryHistory: Sendable, Equatable {
    private(set) var raw = RingBuffer<HistoryPoint>(capacity: HistoryTier.raw.capacity)
    private(set) var tiers: [HistoryTier: RingBuffer<HistoryPoint>] = [:]
    /// In-progress buckets that haven't closed yet.
    private(set) var pending: [HistoryTier: HistoryPoint] = [:]
    private(set) var gaps = RingBuffer<HistoryGap>(capacity: 512)
    private(set) var openGap: OpenGap?
    private(set) var retention: HistoryRetention

    struct OpenGap: Sendable, Equatable, Codable {
        var start: Date
        var reason: HistoryGap.Reason
    }

    init(retention: HistoryRetention = .oneDay) {
        self.retention = retention
        for tier in HistoryTier.aggregated {
            tiers[tier] = RingBuffer(capacity: tier.capacity)
        }
    }

    var activeTiers: [HistoryTier] { HistoryTier.aggregatedTiers(for: retention) }

    func points(in tier: HistoryTier) -> [HistoryPoint] {
        tier == .raw ? raw.elements : (tiers[tier]?.elements ?? [])
    }

    // MARK: - Recording

    /// A sample this far before the newest one means the system clock was set back.
    static let clockStepTolerance: TimeInterval = 5

    /// Adds one sample. Samples arrive in chronological order; an exact or near duplicate is
    /// ignored, and a large step backwards (the clock was changed) discards the now-"future" data
    /// so the history stays chronological instead of rejecting every new sample.
    mutating func append(_ sample: HistoryPoint) {
        if let last = raw.last, sample.start <= last.start {
            guard last.start.timeIntervalSince(sample.start) > Self.clockStepTolerance else { return }
            discardData(after: sample.start)
        }
        if openGap != nil { endGap(at: sample.start) }
        raw.append(sample)

        for tier in activeTiers {
            let bucketStart = Self.bucketStart(for: sample.start, resolution: tier.resolution)
            if let current = pending[tier] {
                if current.start == bucketStart {
                    pending[tier] = current.merged(with: sample).aligned(to: bucketStart, duration: tier.resolution)
                    continue
                }
                tiers[tier]?.append(current)
            }
            pending[tier] = sample.aligned(to: bucketStart, duration: tier.resolution)
        }
    }

    /// Removes everything from `date` on (used when the system clock steps backwards).
    mutating func discardData(after date: Date) {
        raw.retain { $0.start < date }
        for tier in HistoryTier.aggregated {
            let bucket = Self.bucketStart(for: date, resolution: tier.resolution)
            tiers[tier]?.retain { $0.start < bucket }
            if let current = pending[tier], current.end > bucket {
                pending[tier] = nil
            }
        }
        gaps.retain { $0.end <= date }
        if let openGap, openGap.start >= date {
            self.openGap = nil
        }
    }

    /// Starts a gap (sleep, pause, read failure). A bucket that contains the start of a gap keeps
    /// the samples from both sides of it; `segment` breaks the line there.
    mutating func beginGap(at date: Date, reason: HistoryGap.Reason) {
        guard openGap == nil else { return }
        openGap = OpenGap(start: date, reason: reason)
    }

    mutating func endGap(at date: Date) {
        guard let gap = openGap else { return }
        openGap = nil
        guard date > gap.start else { return }
        gaps.append(HistoryGap(start: gap.start, end: date, reason: gap.reason))
    }

    mutating func setRetention(_ newValue: HistoryRetention, now: Date) {
        retention = newValue
        for tier in HistoryTier.aggregated where !activeTiers.contains(tier) {
            tiers[tier]?.removeAll()
            pending[tier] = nil
        }
        prune(now: now)
    }

    /// Drops data older than the retention window.
    mutating func prune(now: Date) {
        let rawCutoff = now.addingTimeInterval(-HistoryTier.raw.span)
        raw.retain { $0.start >= rawCutoff }
        for tier in HistoryTier.aggregated {
            let cutoff = now.addingTimeInterval(-min(tier.span, max(retention.duration, HistoryTier.tenSeconds.span)))
            tiers[tier]?.retain { $0.end > cutoff }
        }
        let gapCutoff = now.addingTimeInterval(-retention.duration)
        gaps.retain { $0.end > gapCutoff }
    }

    mutating func clear() {
        raw.removeAll()
        for tier in HistoryTier.aggregated {
            tiers[tier]?.removeAll()
        }
        pending = [:]
        gaps.removeAll()
        openGap = nil
    }

    // MARK: - Queries

    /// Raw samples newer than `cutoff`, oldest first.
    func rawPoints(since cutoff: Date) -> [HistoryPoint] {
        raw.suffix { $0.start >= cutoff }
    }

    /// Gaps (including an open one, ending at `now`) overlapping `[start, end]`.
    func gaps(between start: Date, and end: Date, now: Date) -> [HistoryGap] {
        var result = gaps.elements.filter { $0.overlaps(start, end) }
        if let openGap, openGap.start < end {
            result.append(HistoryGap(start: openGap.start, end: max(now, openGap.start), reason: openGap.reason))
        }
        return result
    }

    /// The tier that serves a chart range.
    static func tier(for range: ChartRange) -> HistoryTier {
        switch range {
        case .fiveMinutes, .fifteenMinutes: .raw
        case .oneHour: .tenSeconds
        case .oneDay: .oneMinute
        case .sevenDays: .fiveMinutes
        }
    }

    /// Chart-ready history for a range, downsampled to at most `maxPoints` points and split into
    /// segments wherever data is missing.
    func series(for range: ChartRange, now: Date, maxPoints: Int = 360) -> HistorySeries {
        let start = now.addingTimeInterval(-range.duration)
        let tier = Self.tier(for: range)
        var points = points(in: tier).filter { $0.end >= start && $0.start <= now }
        if tier != .raw, let inProgress = pending[tier], inProgress.end >= start {
            points.append(inProgress)
        }

        var resolution = tier.resolution
        if points.count > maxPoints, maxPoints > 0 {
            let width = Self.downsampleWidth(range: range, tierResolution: tier.resolution, maxPoints: maxPoints)
            points = Self.downsample(points, width: width)
            resolution = width
        }

        let gaps = gaps(between: start, and: now, now: now)
        let threshold = max(tier.continuityThreshold, resolution * 2.5)
        let chartPoints = Self.segment(points, gaps: gaps, continuityThreshold: threshold)
        return HistorySeries(range: range, start: start, end: now, points: chartPoints, gaps: gaps, resolution: resolution)
    }

    // MARK: - Helpers (internal for tests)

    static func bucketStart(for date: Date, resolution: TimeInterval) -> Date {
        guard resolution > 0 else { return date }
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (seconds / resolution).rounded(.down) * resolution)
    }

    static func downsampleWidth(range: ChartRange, tierResolution: TimeInterval, maxPoints: Int) -> TimeInterval {
        let ideal = range.duration / Double(maxPoints)
        guard tierResolution > 0 else { return ideal.rounded(.up) }
        return (ideal / tierResolution).rounded(.up) * tierResolution
    }

    /// Merges points into fixed-width, aligned buckets. Points from different buckets are never
    /// merged, so gaps survive downsampling.
    static func downsample(_ points: [HistoryPoint], width: TimeInterval) -> [HistoryPoint] {
        guard width > 0 else { return points }
        var result: [HistoryPoint] = []
        var current: HistoryPoint?
        for point in points {
            let bucket = bucketStart(for: point.start, resolution: width)
            if let existing = current, existing.start == bucket {
                current = existing.merged(with: point).aligned(to: bucket, duration: width)
            } else {
                if let existing = current { result.append(existing) }
                current = point.aligned(to: bucket, duration: width)
            }
        }
        if let current { result.append(current) }
        return result
    }

    /// Assigns segment numbers, starting a new segment after a recorded gap or when consecutive
    /// points are further apart than `continuityThreshold`.
    static func segment(_ points: [HistoryPoint], gaps: [HistoryGap], continuityThreshold: TimeInterval) -> [ChartPoint] {
        var result: [ChartPoint] = []
        result.reserveCapacity(points.count)
        var segment = 0
        var previous: HistoryPoint?
        for (index, point) in points.enumerated() {
            if let previous {
                let spacing = point.start.timeIntervalSince(previous.end)
                // A gap separates two points only if it begins after the earlier point started and
                // before the later one starts (a gap that begins inside a bucket belongs to it).
                let crossesGap = gaps.contains { $0.start >= previous.start && $0.start < point.start && $0.end > previous.end }
                if spacing > continuityThreshold || crossesGap {
                    segment += 1
                }
            }
            result.append(ChartPoint(id: index, segment: segment, point: point))
            previous = point
        }
        return result
    }
}

// MARK: - Persistence representation

extension MemoryHistory {
    /// The on-disk form. Raw samples aren't persisted; they're only useful for 15 minutes.
    struct Archive: Sendable, Codable, Equatable {
        static let currentVersion = 1

        var version: Int
        var savedAt: Date
        var retention: HistoryRetention
        var tiers: [String: [HistoryPoint]]
        var pending: [String: HistoryPoint]
        var gaps: [HistoryGap]
    }

    func archive(savedAt: Date) -> Archive {
        var tierPoints: [String: [HistoryPoint]] = [:]
        var pendingPoints: [String: HistoryPoint] = [:]
        for tier in activeTiers {
            tierPoints[tier.rawValue] = tiers[tier]?.elements ?? []
            if let point = pending[tier] { pendingPoints[tier.rawValue] = point }
        }
        var allGaps = gaps.elements
        if let openGap, savedAt > openGap.start {
            allGaps.append(HistoryGap(start: openGap.start, end: savedAt, reason: openGap.reason))
        }
        return Archive(version: Archive.currentVersion, savedAt: savedAt, retention: retention,
                       tiers: tierPoints, pending: pendingPoints, gaps: allGaps)
    }

    /// Restores an archive and records the time since it was saved as a gap.
    init(archive: Archive, retention: HistoryRetention, now: Date) {
        self.init(retention: retention)
        for tier in activeTiers {
            let stored = archive.tiers[tier.rawValue] ?? []
            tiers[tier] = RingBuffer(capacity: tier.capacity, elements: stored.sorted { $0.start < $1.start })
            if let point = archive.pending[tier.rawValue] {
                // A bucket whose period has ended is complete; otherwise keep filling it.
                if point.end <= now {
                    tiers[tier]?.append(point)
                } else {
                    pending[tier] = point
                }
            }
        }
        gaps = RingBuffer(capacity: gaps.capacity, elements: archive.gaps.sorted { $0.start < $1.start })
        // Saved while the clock was ahead: drop what's now dated in the future, as `append` does
        // when the clock is set back while RamLume runs, so the history stays chronological.
        if archive.savedAt.timeIntervalSince(now) > Self.clockStepTolerance {
            discardData(after: now)
        }
        // RamLume stopped observing when the archive was saved (bucket ends can lie later than
        // the last sample, so they don't mark the start of the downtime).
        if now > archive.savedAt {
            gaps.append(HistoryGap(start: archive.savedAt, end: now, reason: .appNotRunning))
        }
        prune(now: now)
    }
}

extension Date {
    /// Whether `interval` has passed since this date. A clock set back since then (a negative
    /// elapsed time) counts as passed, so periodic work doesn't stop until the clock catches up.
    func hasElapsed(_ interval: TimeInterval, by now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(self)
        return elapsed < 0 || elapsed >= interval
    }
}
