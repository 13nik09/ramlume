import Foundation

/// Page counts reported by `host_statistics64(HOST_VM_INFO64)` at one instant.
///
/// Every field is a value measured by the kernel. Counts are in kernel pages; multiply by
/// `MemoryStatistics.pageSize` for bytes.
struct VMPageCounts: Sendable, Equatable, Codable {
    /// `free_count`. Per `mach/vm_statistics.h` this *includes* speculative pages.
    var free: UInt64
    /// `active_count`.
    var active: UInt64
    /// `inactive_count`.
    var inactive: UInt64
    /// `speculative_count`: read-ahead file pages that are already counted in `free`.
    var speculative: UInt64
    /// `throttled_count`.
    var throttled: UInt64
    /// `wire_count`: pages that cannot be paged out or compressed.
    var wired: UInt64
    /// `purgeable_count`: anonymous pages that apps marked as discardable.
    var purgeable: UInt64
    /// `external_page_count`: file-backed pages (the file cache).
    var fileBacked: UInt64
    /// `internal_page_count`: anonymous (app) pages.
    var anonymous: UInt64
    /// `compressor_page_count`: physical pages occupied by compressed data.
    var compressorOccupied: UInt64
    /// `total_uncompressed_pages_in_compressor`: how many pages the compressed data represents.
    var compressorStored: UInt64
}

/// Cumulative event counters since boot, as reported by `host_statistics64`. Units: pages.
struct VMCounters: Sendable, Equatable, Codable {
    var pageIns: UInt64
    var pageOuts: UInt64
    var swapIns: UInt64
    var swapOuts: UInt64
    var compressions: UInt64
    var decompressions: UInt64
    var faults: UInt64
    var copyOnWriteFaults: UInt64
    var zeroFilled: UInt64
    var reactivations: UInt64
    var purges: UInt64
}

/// One complete reading of the kernel's virtual-memory statistics.
struct MemoryStatistics: Sendable, Equatable {
    /// Wall-clock time of the reading (used for display and history).
    var timestamp: Date
    /// System uptime excluding sleep, in seconds. Used to compute rates between readings.
    var uptime: TimeInterval
    /// Kernel page size in bytes (`host_page_size`): 16 KB on Apple silicon, 4 KB on Intel.
    var pageSize: UInt64
    /// Installed physical memory (`hw.memsize`).
    var physicalMemory: UInt64
    /// Physical memory managed by the operating system (`hw.memsize_usable`), when the sysctl exists.
    var usableMemory: UInt64?
    var pages: VMPageCounts
    var counters: VMCounters

    func bytes(fromPages pages: UInt64) -> UInt64 {
        MemoryUnits.bytes(fromPages: pages, pageSize: pageSize)
    }
}

/// The latest complete view of system memory used by the UI and the diagnostics engine.
struct MemorySnapshot: Sendable, Equatable {
    var statistics: MemoryStatistics
    var breakdown: MemoryBreakdown
    /// `nil` when `vm.swapusage` could not be read.
    var swap: SwapUsage?
    /// `kern.memorystatus_level`: the kernel's "memory free percentage" (0–100), also printed
    /// by the `memory_pressure` command. `nil` when unavailable.
    var kernelFreePercentage: Int?
    /// Counter changes since the previous sample, or `nil` after a gap (launch, sleep, pause).
    var activity: MemoryActivity?

    var timestamp: Date { statistics.timestamp }
}
