import Foundation
@testable import RamLume

/// Test fixtures. These values exist only in the test target; the shipping app never contains
/// sample or placeholder metrics.
enum Fixtures {
    static let gib = MemoryUnits.gibibyte
    static let mib = MemoryUnits.mebibyte
    static let reference = Date(timeIntervalSince1970: 1_790_000_000)

    /// Page counts captured from a real 16 GB Apple silicon Mac (16 KB pages). Together with
    /// `usableMemory` they account for every page exactly, which the breakdown tests rely on.
    static let realPages = VMPageCounts(
        free: 25_713,
        active: 236_910,
        inactive: 215_761,
        speculative: 19_981,
        throttled: 0,
        wired: 153_795,
        purgeable: 2_094,
        fileBacked: 225_595,
        anonymous: 247_057,
        compressorOccupied: 375_925,
        compressorStored: 711_340
    )

    static let realCounters = VMCounters(
        pageIns: 13_751_383, pageOuts: 19_835, swapIns: 1_636_907, swapOuts: 2_110_531,
        compressions: 91_581_729, decompressions: 76_012_379, faults: 378_028_149,
        copyOnWriteFaults: 9_227_994, zeroFilled: 343_748_925, reactivations: 76_674_133, purges: 13_686_833
    )

    static let pageSize: UInt64 = 16_384
    static let physicalMemory: UInt64 = 17_179_869_184
    static let usableMemory: UInt64 = 16_516_775_936

    static func statistics(
        timestamp: Date = reference,
        uptime: TimeInterval = 1_000,
        pages: VMPageCounts = realPages,
        counters: VMCounters = realCounters,
        pageSize: UInt64 = pageSize,
        physicalMemory: UInt64 = physicalMemory,
        usableMemory: UInt64? = usableMemory
    ) -> MemoryStatistics {
        MemoryStatistics(
            timestamp: timestamp,
            uptime: uptime,
            pageSize: pageSize,
            physicalMemory: physicalMemory,
            usableMemory: usableMemory,
            pages: pages,
            counters: counters
        )
    }

    /// Page counts for a given fraction of used memory on a 16 GB machine (used includes the
    /// hardware-reserved memory), keeping the partition consistent.
    static func pages(usedFraction: Double, compressedFraction: Double = 0.1) -> VMPageCounts {
        let usablePages = usableMemory / pageSize
        let totalPages = physicalMemory / pageSize
        let reservedPages = totalPages - usablePages
        let target = UInt64(Double(totalPages) * usedFraction)
        let used = target > reservedPages ? target - reservedPages : 0
        let compressed = UInt64(Double(totalPages) * compressedFraction)
        let wired = UInt64(Double(totalPages) * 0.1)
        let app = used > compressed + wired ? used - compressed - wired : 0
        let remaining = usablePages - min(usablePages, app + compressed + wired)
        let cached = remaining * 2 / 3
        let free = remaining - cached
        return VMPageCounts(
            free: free, active: app / 2 + cached / 2, inactive: app - app / 2 + cached - cached / 2,
            speculative: 0, throttled: 0, wired: wired, purgeable: 0,
            fileBacked: cached, anonymous: app,
            compressorOccupied: compressed, compressorStored: compressed * 2
        )
    }

    static func counters(swapOutPages: UInt64 = 0, swapInPages: UInt64 = 0) -> VMCounters {
        var counters = realCounters
        counters.swapOuts += swapOutPages
        counters.swapIns += swapInPages
        return counters
    }

    static func snapshot(
        usedFraction: Double = 0.6,
        swapUsed: UInt64? = 0,
        swapTotal: UInt64 = 2 * gib,
        activity: MemoryActivity? = nil,
        timestamp: Date = reference
    ) -> MemorySnapshot {
        let statistics = statistics(timestamp: timestamp, pages: pages(usedFraction: usedFraction))
        return MemorySnapshot(
            statistics: statistics,
            breakdown: MemoryBreakdown(statistics: statistics),
            swap: swapUsed.map { SwapUsage(total: swapTotal, used: $0, available: swapTotal - min($0, swapTotal), isEncrypted: true) },
            kernelFreePercentage: 50,
            activity: activity
        )
    }

    static func activity(interval: TimeInterval = 1, swapOut: UInt64 = 0, swapIn: UInt64 = 0) -> MemoryActivity {
        MemoryActivity(interval: interval, swapInBytes: swapIn, swapOutBytes: swapOut, pageInBytes: 0, pageOutBytes: 0,
                       compressedPages: 0, decompressedPages: 0, faults: 0)
    }

    /// A raw history sample.
    static func point(
        at date: Date,
        used: Double = Double(8 * gib),
        compressed: Double = Double(gib),
        swapUsed: UInt64? = 0,
        swapTotal: UInt64? = 2 * gib,
        pressure: MemoryPressureLevel? = .normal,
        activity: MemoryActivity? = nil
    ) -> HistoryPoint {
        HistoryPoint(
            start: date, duration: 0, sampleCount: 1, total: physicalMemory,
            used: used, usedPeak: UInt64(used), app: used - compressed - Double(gib), wired: Double(gib), compressed: compressed,
            compressedOriginal: compressed * 2, cachedFiles: Double(2 * gib), free: Double(gib),
            swapUsed: swapUsed.map { Double($0) }, swapUsedPeak: swapUsed, swapTotal: swapTotal, swapSampleCount: swapUsed == nil ? 0 : 1,
            worstPressure: pressure, pressureSampleCount: pressure == nil ? 0 : 1,
            elevatedPressureSamples: (pressure?.isElevated ?? false) ? 1 : 0,
            criticalPressureSamples: pressure == .critical ? 1 : 0,
            activity: activity
        )
    }

    /// One sample per `interval` seconds over `duration`, ending at `end`.
    static func samples(
        ending end: Date,
        duration: TimeInterval,
        interval: TimeInterval = 5,
        make: (Date, Int) -> HistoryPoint
    ) -> [HistoryPoint] {
        let count = Int(duration / interval)
        return (0...count).map { index in
            let date = end.addingTimeInterval(-duration + Double(index) * interval)
            return make(date, index)
        }
    }

    static func process(
        pid: Int32,
        path: String?,
        footprint: UInt64?,
        userName: String? = "me"
    ) -> ProcessRecord {
        let bundle = path.flatMap(ProcessGrouper.outermostAppBundlePath(forExecutablePath:))
        return ProcessRecord(
            pid: pid,
            name: path.map { ($0 as NSString).lastPathComponent } ?? "Process \(pid)",
            executablePath: path,
            appBundlePath: bundle,
            role: ProcessGrouper.role(executablePath: path, bundlePath: bundle),
            userID: footprint == nil ? 0 : 501,
            userName: footprint == nil ? "root" : userName,
            parentPID: 1,
            footprint: footprint,
            peakFootprint: footprint,
            access: footprint == nil ? .restricted(errno: EPERM) : .accessible
        )
    }

    static let braveMain = "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
    static let braveRenderer = "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/154.1.96.60/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)"
    static let braveGPU = "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/154.1.96.60/Helpers/Brave Browser Helper (GPU).app/Contents/MacOS/Brave Browser Helper (GPU)"
    static let webContent = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"

    static func processSnapshot(
        timestamp: Date = reference,
        records: [ProcessRecord],
        bundleMetadata: [String: BundleMetadata] = ["/Applications/Brave Browser.app": BundleMetadata(displayName: "Brave Browser", bundleIdentifier: "com.brave.Browser")]
    ) -> ProcessSnapshot {
        let groups = ProcessGrouper.makeGroups(from: records, bundleMetadata: bundleMetadata)
        let accessible = records.count(where: \.isAccessible)
        return ProcessSnapshot(
            timestamp: timestamp, groups: groups, totalCount: records.count,
            accessibleCount: accessible, restrictedCount: records.count - accessible, scanDuration: 0.01
        )
    }

    /// Brave using ~4 GB across a main process and helpers, plus a restricted root process.
    static func braveSnapshot(timestamp: Date = reference) -> ProcessSnapshot {
        processSnapshot(timestamp: timestamp, records: [
            process(pid: 100, path: braveMain, footprint: 600 * mib),
            process(pid: 101, path: braveRenderer, footprint: 1_800 * mib),
            process(pid: 102, path: braveRenderer, footprint: 1_100 * mib),
            process(pid: 103, path: braveGPU, footprint: 500 * mib),
            process(pid: 200, path: "/usr/libexec/someDaemon", footprint: 40 * mib),
            process(pid: 1, path: "/sbin/launchd", footprint: nil),
        ])
    }
}

// MARK: - Fakes

/// A controllable clock shared by a test and the code under test.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Fixtures.reference) {
        current = start
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

/// Returns scripted statistics; uptime and timestamp follow the test clock.
final class FakeMemoryReader: MemoryStatisticsProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let clock: TestClock
    private let start: Date
    var pages: VMPageCounts = Fixtures.realPages
    var counters: VMCounters = Fixtures.realCounters
    var failure: MemoryReadError?

    init(clock: TestClock) {
        self.clock = clock
        start = clock.now
    }

    func readStatistics() throws(MemoryReadError) -> MemoryStatistics {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        let now = clock.now
        return Fixtures.statistics(timestamp: now, uptime: 1_000 + now.timeIntervalSince(start), pages: pages, counters: counters)
    }

    func update(_ change: (FakeMemoryReader) -> Void) {
        lock.lock()
        change(self)
        lock.unlock()
    }
}

final class FakeSwapReader: SwapUsageProviding, @unchecked Sendable {
    var usage: SwapUsage? = SwapUsage(total: 2 * Fixtures.gib, used: 300 * Fixtures.mib, available: 1_748 * Fixtures.mib, isEncrypted: true)
    func readSwapUsage() -> SwapUsage? { usage }
}

final class FakePressureReader: PressureLevelProviding, @unchecked Sendable {
    var level: MemoryPressureLevel? = .normal
    func readIndicators() -> KernelPressureIndicators {
        KernelPressureIndicators(level: level, freePercentage: 50)
    }
}

struct FakeProcessProvider: ProcessProviding {
    var snapshot: ProcessSnapshot

    func scanProcesses() async -> ProcessSnapshot {
        snapshot
    }
}
