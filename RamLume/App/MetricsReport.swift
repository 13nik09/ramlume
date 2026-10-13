import Foundation

/// Plain-text report of one reading, printed by `RamLume --dump-metrics`.
///
/// It shows the raw kernel values next to every derived figure so the numbers can be checked
/// against `vm_stat`, `sysctl vm.swapusage`, and `memory_pressure`.
enum MetricsReport {
    static func printReport() {
        print(makeReport())
    }

    static func makeReport() -> String {
        var lines: [String] = []
        let reader: SystemMemoryReader
        do {
            reader = try SystemMemoryReader()
        } catch {
            return "RamLume could not initialize its memory reader: \(error.description)"
        }
        let statistics: MemoryStatistics
        do {
            statistics = try reader.readStatistics()
        } catch {
            return "RamLume could not read memory statistics: \(error.description)"
        }
        let breakdown = MemoryBreakdown(statistics: statistics)
        let swap = SystemSwapReader().readSwapUsage()
        let pressure = KernelPressureReader().readIndicators()
        let p = statistics.pages
        let c = statistics.counters

        func bytes(_ value: UInt64) -> String {
            "\(MemoryFormatter.string(fromBytes: value, locale: Locale(identifier: "en_US_POSIX"))) (\(value) bytes)"
        }

        lines.append("RamLume \(AppInfo.version) metrics report — \(ISO8601DateFormatter().string(from: statistics.timestamp))")
        lines.append("")
        lines.append("Measured (kernel)")
        lines.append("  hw.memsize                      \(bytes(statistics.physicalMemory))")
        lines.append("  hw.memsize_usable               \(statistics.usableMemory.map(bytes) ?? "unavailable")")
        lines.append("  page size (host_page_size)      \(statistics.pageSize)")
        lines.append("  free_count (incl. speculative)  \(p.free)")
        lines.append("  active_count                    \(p.active)")
        lines.append("  inactive_count                  \(p.inactive)")
        lines.append("  speculative_count               \(p.speculative)")
        lines.append("  throttled_count                 \(p.throttled)")
        lines.append("  wire_count                      \(p.wired)")
        lines.append("  purgeable_count                 \(p.purgeable)")
        lines.append("  external_page_count (file)      \(p.fileBacked)")
        lines.append("  internal_page_count (anonymous) \(p.anonymous)")
        lines.append("  compressor_page_count           \(p.compressorOccupied)")
        lines.append("  total_uncompressed_in_compressor \(p.compressorStored)")
        lines.append("  pageins / pageouts              \(c.pageIns) / \(c.pageOuts)")
        lines.append("  swapins / swapouts              \(c.swapIns) / \(c.swapOuts)")
        lines.append("  compressions / decompressions   \(c.compressions) / \(c.decompressions)")
        lines.append("  vm.swapusage                    " + (swap.map { "total \(bytes($0.total)), used \(bytes($0.used)), encrypted \($0.isEncrypted)" } ?? "unavailable"))
        lines.append("  kern.memorystatus_vm_pressure_level  \(pressure.level.map { "\($0.rawValue) (\($0.displayName))" } ?? "unavailable")")
        lines.append("  kern.memorystatus_level         \(pressure.freePercentage.map { "\($0)%" } ?? "unavailable")")
        lines.append("")
        lines.append("Derived partition (sums to hw.memsize)")
        lines.append("  Reserved   = memsize − memsize_usable              \(breakdown.reserved.map(bytes) ?? "unknown")")
        lines.append("  Wired      = wire_count × page                    \(bytes(breakdown.wired))")
        lines.append("  Compressed = compressor_page_count × page         \(bytes(breakdown.compressed))")
        lines.append("  App        = (internal − purgeable) × page        \(bytes(breakdown.app))")
        lines.append("  Cached     = (external + purgeable) × page        \(bytes(breakdown.cachedFiles))")
        lines.append("  Free       = (free_count − speculative) × page    \(bytes(breakdown.free))")
        lines.append("  Unaccounted (remainder)                           \(bytes(breakdown.unaccounted))")
        lines.append("  Sum of categories                                 \(bytes(breakdown.accounted)) of \(bytes(breakdown.total))")
        lines.append("")
        lines.append("Estimates")
        lines.append("  Used ≈ App + Wired + Compressed + Reserved       \(bytes(breakdown.used)) (\(MemoryFormatter.percent(breakdown.usedFraction, locale: Locale(identifier: "en_US_POSIX"))))")
        lines.append("  Available ≈ Cached + Free                         \(bytes(breakdown.availableEstimate))")
        if let ratio = breakdown.compressionRatio {
            lines.append("  Compression ratio (stored ÷ occupied)             \(String(format: "%.2f", ratio))×")
        }
        lines.append("")
        lines.append("Consistency check: internal + external = \(p.anonymous + p.fileBacked); active + inactive + speculative = \(p.active + p.inactive + p.speculative)")
        return lines.joined(separator: "\n")
    }
}
