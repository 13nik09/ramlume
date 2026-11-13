import Foundation

/// Swap usage reported by the `vm.swapusage` sysctl. All values are measured.
///
/// macOS creates swap files on demand, so `total` is the space currently allocated to swap
/// files, not a fixed partition size. Swap that was written during an earlier memory spike can
/// stay allocated long after pressure returns to normal; that by itself is not a problem.
struct SwapUsage: Sendable, Equatable, Codable {
    /// Space currently allocated to swap files.
    var total: UInt64
    var used: UInt64
    var available: UInt64
    var isEncrypted: Bool
}
