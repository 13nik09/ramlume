import Foundation

/// A non-overlapping partition of installed physical memory, derived from one reading.
///
/// Every byte of installed memory lands in exactly one category:
///
/// | Category      | Formula                                         | Kind      |
/// |---------------|-------------------------------------------------|-----------|
/// | Reserved      | `hw.memsize − hw.memsize_usable`                | measured  |
/// | Wired         | `wire_count × page`                             | measured  |
/// | Compressed    | `compressor_page_count × page`                  | measured  |
/// | App memory    | `(internal_page_count − purgeable_count) × page`| derived   |
/// | Cached files  | `(external_page_count + purgeable_count) × page`| derived   |
/// | Free          | `(free_count − speculative_count) × page`       | derived   |
/// | Unaccounted   | whatever remains (normally zero)                | remainder |
///
/// `internal + external` equals `active + inactive + speculative`, and `free_count` already
/// includes speculative pages, which is why speculative pages are subtracted from `free`
/// rather than added anywhere. Compressed memory is counted once, as the physical pages the
/// compressor occupies; the larger uncompressed size it represents is reported separately and
/// is never added to the total.
///
/// "Used" is everything that isn't cached files or free memory:
/// `App + Wired + Compressed + Reserved (+ any unaccounted remainder)`, so
/// `Used + Cached files + Free = Installed`. Hardware-reserved memory counts as used because
/// apps can't use it. In testing this matched Activity Monitor's *Memory Used* within a few
/// hundredths of a gigabyte, but Activity Monitor's exact computation isn't public, so
/// RamLume presents the figure as an estimate.
struct MemoryBreakdown: Sendable, Equatable {
    /// Installed physical memory (`hw.memsize`).
    let total: UInt64
    /// Memory reserved by hardware and firmware, invisible to the VM system. `nil` if unknown.
    let reserved: UInt64?
    let wired: UInt64
    /// Physical memory occupied by the compressor.
    let compressed: UInt64
    /// The uncompressed size of the data held by the compressor (informational, not part of the partition).
    let compressedOriginal: UInt64
    let app: UInt64
    let cachedFiles: UInt64
    let free: UInt64
    /// `total` minus every other category, clamped at zero.
    let unaccounted: UInt64

    init(statistics: MemoryStatistics) {
        let pages = statistics.pages
        total = statistics.physicalMemory
        reserved = statistics.usableMemory.flatMap { usable in
            usable <= statistics.physicalMemory ? statistics.physicalMemory - usable : nil
        }
        wired = statistics.bytes(fromPages: pages.wired)
        compressed = statistics.bytes(fromPages: pages.compressorOccupied)
        compressedOriginal = statistics.bytes(fromPages: pages.compressorStored)

        // Purgeable pages are anonymous memory the system may discard, so they move from
        // "app" to "cached". Clamp in case the counters were read at slightly different moments.
        let purgeable = min(pages.purgeable, pages.anonymous)
        app = statistics.bytes(fromPages: pages.anonymous - purgeable)
        cachedFiles = statistics.bytes(fromPages: MemoryUnits.saturatingAdd(pages.fileBacked, purgeable))
        free = statistics.bytes(fromPages: pages.free > pages.speculative ? pages.free - pages.speculative : 0)

        let accounted = MemoryUnits.saturatingSum([reserved ?? 0, wired, compressed, app, cachedFiles, free])
        unaccounted = total > accounted ? total - accounted : 0
    }

    /// Estimated memory in use: everything except cached files and free memory.
    var used: UInt64 { MemoryUnits.saturatingSum([app, wired, compressed, systemReserved]) }

    /// Hardware/firmware-reserved memory plus any remainder the VM statistics don't report.
    var systemReserved: UInt64 { MemoryUnits.saturatingAdd(reserved ?? 0, unaccounted) }

    /// `used / total`, clamped to 0...1.
    var usedFraction: Double { MemoryUnits.clampedFraction(used, of: total) }

    /// Estimated memory that can be made available without swapping: `Cached files + Free`.
    /// Not every cached page is instantly reclaimable, so treat this as an upper bound.
    var availableEstimate: UInt64 { MemoryUnits.saturatingAdd(cachedFiles, free) }

    /// Sum of every category except `unaccounted`; equals `total` when the counters are consistent.
    var accounted: UInt64 {
        MemoryUnits.saturatingSum([reserved ?? 0, wired, compressed, app, cachedFiles, free])
    }

    /// How many times larger the stored data is than the memory the compressor occupies.
    var compressionRatio: Double? {
        guard compressed > 0, compressedOriginal > 0 else { return nil }
        return Double(compressedOriginal) / Double(compressed)
    }

    /// Memory saved by compression: original size minus occupied size.
    var compressionSavings: UInt64 {
        compressedOriginal > compressed ? compressedOriginal - compressed : 0
    }
}
