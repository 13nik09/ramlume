import Foundation

/// Watches the largest process groups for steady, sustained memory growth.
///
/// This is a heuristic for *possible* leaks. It only reports growth that is large, mostly
/// monotonic, and observed over a long window, and the resulting insight says that such growth
/// can also be expected behaviour.
struct ProcessGrowthTracker: Sendable, Equatable {
    struct Sample: Sendable, Equatable {
        var date: Date
        var bytes: UInt64
    }

    struct Series: Sendable, Equatable {
        var displayName: String
        var samples: [Sample]
    }

    struct Configuration: Sendable, Equatable {
        /// Analysis window.
        var window: TimeInterval = 3_600
        /// Growth must be observed over at least this long.
        var minimumSpan: TimeInterval = 1_200
        var minimumSamples = 8
        var minimumGrowth: UInt64 = MemoryUnits.gibibyte
        /// Growth must also be at least this fraction of the starting size.
        var minimumRelativeGrowth = 0.5
        /// Fraction of steps that must not decrease.
        var minimumNonDecreasingFraction = 0.7
        /// Largest allowed temporary decline, as a fraction of the overall growth.
        var maximumDrawdownFraction = 0.15
        /// A drop to below this fraction of the previous sample is treated as a relaunch.
        var restartDropFraction = 0.5
        /// Groups tracked per scan (largest first).
        var groupsPerScan = 15
        var maximumTrackedGroups = 40
        var maximumSamplesPerGroup = 400
    }

    var configuration = Configuration()
    private(set) var series: [String: Series] = [:]

    mutating func record(_ snapshot: ProcessSnapshot) {
        let now = snapshot.timestamp
        let accessible = snapshot.accessibleGroups
        var present: [String: ProcessGroup] = [:]
        for group in accessible { present[group.id] = group }

        var keys = Set(series.keys).filter { present[$0] != nil }
        keys.formUnion(accessible.prefix(configuration.groupsPerScan).map(\.id))

        var updated: [String: Series] = [:]
        for key in keys {
            guard let group = present[key] else { continue }
            var entry = series[key] ?? Series(displayName: group.displayName, samples: [])
            if let last = entry.samples.last,
               Double(group.totalFootprint) < Double(last.bytes) * configuration.restartDropFraction {
                entry.samples.removeAll()
            }
            entry.displayName = group.displayName
            entry.samples.append(Sample(date: now, bytes: group.totalFootprint))
            let cutoff = now.addingTimeInterval(-configuration.window * 1.5)
            entry.samples.removeAll { $0.date < cutoff }
            if entry.samples.count > configuration.maximumSamplesPerGroup {
                entry.samples.removeFirst(entry.samples.count - configuration.maximumSamplesPerGroup)
            }
            updated[key] = entry
        }

        if updated.count > configuration.maximumTrackedGroups {
            let kept = updated
                .sorted { ($0.value.samples.last?.bytes ?? 0) > ($1.value.samples.last?.bytes ?? 0) }
                .prefix(configuration.maximumTrackedGroups)
            updated = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        series = updated
    }

    mutating func reset() {
        series = [:]
    }

    func findings(now: Date) -> [ProcessGrowthFinding] {
        series
            .compactMap { analyze(id: $0.key, series: $0.value, now: now) }
            .sorted { $0.growth > $1.growth }
    }

    func analyze(id: String, series: Series, now: Date) -> ProcessGrowthFinding? {
        let cutoff = now.addingTimeInterval(-configuration.window)
        let samples = series.samples.filter { $0.date >= cutoff }
        guard samples.count >= configuration.minimumSamples,
              let first = samples.first, let last = samples.last else { return nil }
        let span = last.date.timeIntervalSince(first.date)
        guard span >= configuration.minimumSpan else { return nil }

        // Medians of the first and last three samples resist single outliers.
        let startBytes = Self.median(samples.prefix(3).map(\.bytes))
        let endBytes = Self.median(samples.suffix(3).map(\.bytes))
        guard endBytes > startBytes else { return nil }
        let growth = endBytes - startBytes
        guard growth >= configuration.minimumGrowth,
              Double(growth) >= Double(startBytes) * configuration.minimumRelativeGrowth else { return nil }

        let steps = zip(samples, samples.dropFirst())
        let nonDecreasing = steps.filter { $0.1.bytes >= $0.0.bytes }.count
        guard Double(nonDecreasing) / Double(samples.count - 1) >= configuration.minimumNonDecreasingFraction else { return nil }

        var peak: UInt64 = 0
        var drawdown: UInt64 = 0
        for sample in samples {
            peak = max(peak, sample.bytes)
            drawdown = max(drawdown, peak - sample.bytes)
        }
        guard Double(drawdown) <= Double(growth) * configuration.maximumDrawdownFraction else { return nil }

        return ProcessGrowthFinding(id: id, displayName: series.displayName, startBytes: startBytes, endBytes: endBytes, duration: span)
    }

    static func median(_ values: [UInt64]) -> UInt64 {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
