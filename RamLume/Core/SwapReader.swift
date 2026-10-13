import Darwin

/// Reads current swap usage.
protocol SwapUsageProviding: Sendable {
    /// Returns `nil` when swap usage can't be read; callers show "Unavailable" rather than zero.
    func readSwapUsage() -> SwapUsage?
}

/// Reads the `vm.swapusage` sysctl (`struct xsw_usage`).
struct SystemSwapReader: SwapUsageProviding {
    func readSwapUsage() -> SwapUsage? {
        guard let usage = SysctlReader.value(named: "vm.swapusage", initial: xsw_usage()) else {
            return nil
        }
        return SwapUsage(
            total: usage.xsu_total,
            used: usage.xsu_used,
            available: usage.xsu_avail,
            isEncrypted: usage.xsu_encrypted != 0
        )
    }
}
