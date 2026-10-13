import Darwin

/// Minimal, type-checked access to `sysctlbyname`.
///
/// A value is returned only when the call succeeds *and* the kernel wrote exactly the expected
/// number of bytes, so a sysctl that changes size or disappears in a future macOS release is
/// reported as unavailable instead of being misread.
enum SysctlReader {
    static func integer<T: FixedWidthInteger & BitwiseCopyable>(named name: String, as type: T.Type = T.self) -> T? {
        value(named: name, initial: T.zero)
    }

    /// Reads a plain C value (an integer or a struct such as `xsw_usage`).
    static func value<T: BitwiseCopyable>(named name: String, initial: T) -> T? {
        var value = initial
        var size = MemoryLayout<T>.size
        let result = withUnsafeMutableBytes(of: &value) { buffer in
            sysctlbyname(name, buffer.baseAddress, &size, nil, 0)
        }
        guard result == 0, size == MemoryLayout<T>.size else { return nil }
        return value
    }
}
