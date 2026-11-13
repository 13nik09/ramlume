import Darwin
import Foundation

/// Enumerates processes and their memory footprints.
protocol ProcessProviding: Sendable {
    func scanProcesses() async -> ProcessSnapshot
}

/// Reads per-process memory with `libproc`, without elevated privileges.
///
/// - `proc_listallpids` enumerates processes.
/// - `proc_pid_rusage(RUSAGE_INFO_V4)` provides `ri_phys_footprint`, the same "physical
///   footprint" Activity Monitor shows in its Memory column. macOS only allows this for the
///   current user's processes; for others it fails with `EPERM` and RamLume shows the process
///   as restricted instead of substituting another number.
/// - `proc_pidpath` and `proc_pidinfo(PROC_PIDT_SHORTBSDINFO)` provide the executable path,
///   owner, and parent; both work for all processes.
///
/// Runs on its own actor, off the main thread.
actor ProcessReader: ProcessProviding {
    private var bundleMetadataCache: [String: BundleMetadata] = [:]
    private var userNameCache: [UInt32: String] = [:]
    /// Display names of XPC service bundles; an empty string records "none declared".
    private var serviceNameCache: [String: String] = [:]

    func scanProcesses() async -> ProcessSnapshot {
        let clock = ContinuousClock()
        let started = clock.now

        let pids = Self.listAllPIDs()
        var records: [ProcessRecord] = []
        records.reserveCapacity(pids.count)
        for pid in pids {
            if let record = record(forPID: pid) { records.append(record) }
        }

        let bundlePaths = Set(records.compactMap(\.appBundlePath))
        var metadata: [String: BundleMetadata] = [:]
        for path in bundlePaths {
            metadata[path] = bundleMetadata(forBundlePath: path)
        }
        // Keep the cache bounded to bundles that are currently running.
        bundleMetadataCache = bundleMetadataCache.filter { bundlePaths.contains($0.key) }

        let groups = ProcessGrouper.makeGroups(from: records, bundleMetadata: metadata)
        let accessible = records.count(where: \.isAccessible)
        return ProcessSnapshot(
            timestamp: Date(),
            groups: groups,
            totalCount: records.count,
            accessibleCount: accessible,
            restrictedCount: records.count - accessible,
            scanDuration: started.duration(to: clock.now).timeInterval
        )
    }

    // MARK: - Per-process reads

    /// One process, or `nil` if it has exited since it was listed: `ESRCH` means there's nothing
    /// left to measure, which isn't the same as not being allowed to (`EPERM`).
    func record(forPID pid: pid_t) -> ProcessRecord? {
        let usage = Self.resourceUsage(pid: pid)
        if usage.info == nil, usage.errorNumber == ESRCH { return nil }
        let path = Self.executablePath(pid: pid)
        let bundlePath = path.flatMap(ProcessGrouper.outermostAppBundlePath(forExecutablePath:))
        let pathName = path.map { ($0 as NSString).lastPathComponent }
        // A service outside any app (e.g. "com.apple.Virtualization.VirtualMachine.xpc") uses its
        // own bundle's display name ("Virtual Machine Service") when it declares one.
        let serviceName = bundlePath == nil
            ? path.flatMap(ProcessGrouper.serviceBundlePath(forExecutablePath:)).flatMap(serviceDisplayName(forBundlePath:))
            : nil
        let name = serviceName
            ?? (pathName?.isEmpty == false ? pathName : nil)
            ?? Self.processName(pid: pid)
            ?? "Process \(pid)"
        let shortInfo = Self.shortBSDInfo(pid: pid)
        let userID = shortInfo.map { UInt32($0.pbsi_uid) }
        let access: ProcessRecord.Access = usage.info != nil ? .accessible : .restricted(errno: usage.errorNumber)

        return ProcessRecord(
            pid: pid,
            name: name,
            executablePath: path,
            appBundlePath: bundlePath,
            role: ProcessGrouper.role(executablePath: path, bundlePath: bundlePath),
            userID: userID,
            userName: userID.flatMap(userName(for:)),
            parentPID: shortInfo.map { Int32($0.pbsi_ppid) },
            footprint: usage.info?.ri_phys_footprint,
            peakFootprint: usage.info?.ri_lifetime_max_phys_footprint,
            access: access
        )
    }

    static func listAllPIDs() -> [pid_t] {
        var capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return [] }
        // Leave headroom for processes launched between the two calls; retry once if full.
        for _ in 0..<2 {
            capacity += 64
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBufferPointer { buffer in
                Int(proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size)))
            }
            guard count > 0 else { return [] }
            if count < capacity {
                return Array(pids.prefix(count))
            }
            capacity = count * 2
        }
        return []
    }

    static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func processName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_name(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func shortBSDInfo(pid: pid_t) -> proc_bsdshortinfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        let written = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size)
        return written == size ? info : nil
    }

    static func resourceUsage(pid: pid_t) -> (info: rusage_info_v4?, errorNumber: Int32) {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        return result == 0 ? (info, 0) : (nil, errno)
    }

    // MARK: - Cached metadata

    private func bundleMetadata(forBundlePath path: String) -> BundleMetadata {
        if let cached = bundleMetadataCache[path] { return cached }
        let url = URL(fileURLWithPath: path)
        let bundle = Bundle(url: url)
        let localized = bundle?.localizedInfoDictionary
        let info = bundle?.infoDictionary
        let candidates: [Any?] = [
            localized?["CFBundleDisplayName"], info?["CFBundleDisplayName"],
            localized?["CFBundleName"], info?["CFBundleName"],
        ]
        let name = candidates.lazy.compactMap { $0 as? String }.first { !$0.isEmpty }
            ?? ProcessGrouper.fallbackDisplayName(forBundlePath: path)
        let metadata = BundleMetadata(displayName: name, bundleIdentifier: bundle?.bundleIdentifier)
        bundleMetadataCache[path] = metadata
        return metadata
    }

    /// The display name an XPC service declares, or `nil` if it only has an identifier-style name.
    private func serviceDisplayName(forBundlePath path: String) -> String? {
        if let cached = serviceNameCache[path] { return cached.isEmpty ? nil : cached }
        let bundle = Bundle(url: URL(fileURLWithPath: path))
        let localized = bundle?.localizedInfoDictionary
        let info = bundle?.infoDictionary
        let name = [localized?["CFBundleDisplayName"], info?["CFBundleDisplayName"]]
            .lazy.compactMap { $0 as? String }.first { !$0.isEmpty }
        serviceNameCache[path] = name ?? ""
        return name
    }

    private func userName(for userID: UInt32) -> String? {
        if let cached = userNameCache[userID] { return cached }
        var buffer = [CChar](repeating: 0, count: 1_024)
        let name: String? = buffer.withUnsafeMutableBufferPointer { pointer in
            var entry = passwd()
            var result: UnsafeMutablePointer<passwd>?
            guard getpwuid_r(userID, &entry, pointer.baseAddress, pointer.count, &result) == 0,
                  result != nil, let rawName = entry.pw_name else { return nil }
            return String(cString: rawName)
        }
        if let name { userNameCache[userID] = name }
        return name
    }
}

extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
