import Foundation

/// Unit conversion helpers shared by the readers, diagnostics, and UI.
///
/// RamLume reports memory in binary units (1 GB = 1,073,741,824 bytes). This matches how
/// macOS describes installed memory ("16 GB") and how Activity Monitor formats memory sizes.
enum MemoryUnits {
    static let kibibyte: UInt64 = 1_024
    static let mebibyte: UInt64 = 1_048_576
    static let gibibyte: UInt64 = 1_073_741_824

    /// Converts a page count to bytes, saturating at `UInt64.max` instead of trapping on overflow.
    static func bytes(fromPages pages: UInt64, pageSize: UInt64) -> UInt64 {
        let (result, overflow) = pages.multipliedReportingOverflow(by: pageSize)
        return overflow ? .max : result
    }

    /// Adds two byte counts, saturating instead of trapping.
    static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }

    /// Sums byte counts with saturation.
    static func saturatingSum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0, saturatingAdd)
    }

    /// The difference between two readings of a cumulative kernel counter.
    ///
    /// Returns `nil` when the newer value is smaller than the older one. Kernel counters only
    /// grow while the system is running, so a decrease means the counter was reset or the
    /// readings are not comparable; callers must not invent a value in that case.
    static func counterDelta(from old: UInt64, to new: UInt64) -> UInt64? {
        new >= old ? new - old : nil
    }

    /// `part / whole`, or `nil` when `whole` is zero. The result is not clamped.
    static func fraction(_ part: UInt64, of whole: UInt64) -> Double? {
        guard whole > 0 else { return nil }
        return Double(part) / Double(whole)
    }

    /// `part / whole` clamped to `0...1` for display (bars and gauges cannot exceed 100%).
    static func clampedFraction(_ part: UInt64, of whole: UInt64) -> Double {
        guard let value = fraction(part, of: whole) else { return 0 }
        return min(max(value, 0), 1)
    }

    /// Signed difference `new - old` that cannot overflow `Int64`.
    static func signedDifference(_ new: UInt64, _ old: UInt64) -> Int64 {
        if new >= old {
            let delta = new - old
            return delta > UInt64(Int64.max) ? .max : Int64(delta)
        } else {
            let delta = old - new
            return delta > UInt64(Int64.max) ? .min : -Int64(delta)
        }
    }
}
