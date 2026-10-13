import Darwin
import Foundation

/// Reads system-wide virtual-memory statistics.
protocol MemoryStatisticsProviding: Sendable {
    func readStatistics() throws(MemoryReadError) -> MemoryStatistics
}

enum MemoryReadError: Error, Sendable, Equatable, CustomStringConvertible {
    case pageSizeUnavailable
    case physicalMemoryUnavailable
    case hostStatisticsFailed(code: Int32)

    var description: String {
        switch self {
        case .pageSizeUnavailable:
            "The kernel page size could not be read."
        case .physicalMemoryUnavailable:
            "The amount of installed memory could not be read."
        case .hostStatisticsFailed(let code):
            "macOS didn't return memory statistics (Mach error \(code))."
        }
    }
}

/// Reads memory statistics with `host_statistics64(HOST_VM_INFO64)`, `host_page_size`, and the
/// `hw.memsize` / `hw.memsize_usable` sysctls. Requires no privileges or entitlements.
final class SystemMemoryReader: MemoryStatisticsProviding {
    /// The host port is obtained once: every `mach_host_self()` call adds a send-right reference.
    private let host: mach_port_t
    private let pageSize: UInt64
    private let physicalMemory: UInt64
    private let usableMemory: UInt64?

    init() throws(MemoryReadError) {
        host = mach_host_self()

        var kernelPageSize: vm_size_t = 0
        guard host_page_size(host, &kernelPageSize) == KERN_SUCCESS, kernelPageSize > 0 else {
            throw .pageSizeUnavailable
        }
        pageSize = UInt64(kernelPageSize)

        guard let memsize = SysctlReader.integer(named: "hw.memsize", as: UInt64.self), memsize > 0 else {
            throw .physicalMemoryUnavailable
        }
        physicalMemory = memsize

        // `hw.memsize_usable` excludes memory reserved by hardware and firmware. Not every
        // macOS version provides it; when absent, that memory shows up as "unaccounted".
        if let usable = SysctlReader.integer(named: "hw.memsize_usable", as: UInt64.self), usable > 0, usable <= memsize {
            usableMemory = usable
        } else {
            usableMemory = nil
        }
    }

    func readStatistics() throws(MemoryReadError) -> MemoryStatistics {
        var raw = vm_statistics64()
        // HOST_VM_INFO64_COUNT: the structure size in `integer_t` units (C `sizeof`, i.e. stride).
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &raw) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { integers in
                host_statistics64(host, HOST_VM_INFO64, integers, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw .hostStatisticsFailed(code: result)
        }

        return MemoryStatistics(
            timestamp: Date(),
            uptime: ProcessInfo.processInfo.systemUptime,
            pageSize: pageSize,
            physicalMemory: physicalMemory,
            usableMemory: usableMemory,
            pages: VMPageCounts(raw),
            counters: VMCounters(raw)
        )
    }
}

extension VMPageCounts {
    init(_ raw: vm_statistics64) {
        free = UInt64(raw.free_count)
        active = UInt64(raw.active_count)
        inactive = UInt64(raw.inactive_count)
        speculative = UInt64(raw.speculative_count)
        throttled = UInt64(raw.throttled_count)
        wired = UInt64(raw.wire_count)
        purgeable = UInt64(raw.purgeable_count)
        fileBacked = UInt64(raw.external_page_count)
        anonymous = UInt64(raw.internal_page_count)
        compressorOccupied = UInt64(raw.compressor_page_count)
        compressorStored = raw.total_uncompressed_pages_in_compressor
    }
}

extension VMCounters {
    init(_ raw: vm_statistics64) {
        pageIns = raw.pageins
        pageOuts = raw.pageouts
        swapIns = raw.swapins
        swapOuts = raw.swapouts
        compressions = raw.compressions
        decompressions = raw.decompressions
        faults = raw.faults
        copyOnWriteFaults = raw.cow_faults
        zeroFilled = raw.zero_fill_count
        reactivations = raw.reactivations
        purges = raw.purges
    }
}
