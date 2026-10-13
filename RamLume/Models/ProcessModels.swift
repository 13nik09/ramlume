import Foundation

/// Memory information for one process, as far as macOS allows an unprivileged app to see it.
struct ProcessRecord: Sendable, Equatable, Identifiable {
    enum Access: Sendable, Equatable {
        /// `proc_pid_rusage` succeeded.
        case accessible
        /// The kernel refused access (typically processes owned by root or other users).
        case restricted(errno: Int32)
    }

    enum Role: Sendable, Equatable {
        /// The main executable of an application bundle.
        case application
        /// A helper, XPC service, or renderer inside an application bundle.
        case helper
        /// A process that doesn't live inside an application bundle.
        case standalone
    }

    let pid: Int32
    let name: String
    let executablePath: String?
    /// The outermost `.app` bundle containing the executable, if any.
    let appBundlePath: String?
    let role: Role
    let userID: UInt32?
    let userName: String?
    let parentPID: Int32?
    /// Physical footprint (`ri_phys_footprint`) — the same metric as Activity Monitor's Memory column.
    /// `nil` when access was restricted.
    let footprint: UInt64?
    /// Lifetime peak footprint (`ri_lifetime_max_phys_footprint`). `nil` when restricted.
    let peakFootprint: UInt64?
    let access: Access

    var id: Int32 { pid }
    var isAccessible: Bool { access == .accessible }
}

/// Processes that RamLume can trustworthily present together.
struct ProcessGroup: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable {
        /// Every member's executable lives inside the same `.app` bundle.
        case application(bundlePath: String)
        /// Several processes run the same executable outside any app bundle.
        case sharedExecutable(path: String)
        /// A single process.
        case single
    }

    let id: String
    let kind: Kind
    let displayName: String
    let bundleIdentifier: String?
    /// Members sorted by footprint, largest first.
    let processes: [ProcessRecord]
    /// Sum of accessible members' footprints. Shared memory may be counted in more than one
    /// process or in none, so treat the total as an approximation of the group's impact.
    let totalFootprint: UInt64
    let accessibleCount: Int

    init(id: String, kind: Kind, displayName: String, bundleIdentifier: String?, processes: [ProcessRecord]) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.processes = processes
        totalFootprint = MemoryUnits.saturatingSum(processes.compactMap(\.footprint))
        accessibleCount = processes.count(where: \.isAccessible)
    }

    var restrictedCount: Int { processes.count - accessibleCount }
    var isFullyRestricted: Bool { accessibleCount == 0 }

    var bundlePath: String? {
        if case .application(let path) = kind { return path }
        return nil
    }

    /// The executable path to use for an icon when the group isn't an app bundle.
    var representativePath: String? {
        bundlePath ?? processes.first?.executablePath
    }
}

/// The result of one process scan.
struct ProcessSnapshot: Sendable, Equatable {
    let timestamp: Date
    /// Sorted by total footprint, largest first; fully restricted groups last.
    let groups: [ProcessGroup]
    /// Groups with at least one measurable process, largest first.
    let accessibleGroups: [ProcessGroup]
    let totalCount: Int
    let accessibleCount: Int
    let restrictedCount: Int
    let scanDuration: TimeInterval
    let totalAccessibleFootprint: UInt64

    init(timestamp: Date, groups: [ProcessGroup], totalCount: Int, accessibleCount: Int, restrictedCount: Int, scanDuration: TimeInterval) {
        self.timestamp = timestamp
        self.groups = groups
        self.totalCount = totalCount
        self.accessibleCount = accessibleCount
        self.restrictedCount = restrictedCount
        self.scanDuration = scanDuration
        accessibleGroups = groups.filter { !$0.isFullyRestricted }
        totalAccessibleFootprint = MemoryUnits.saturatingSum(groups.map(\.totalFootprint))
    }

    var largestAccessibleGroup: ProcessGroup? { accessibleGroups.first }
}

/// A process group whose memory grew steadily for a sustained period.
struct ProcessGrowthFinding: Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let startBytes: UInt64
    let endBytes: UInt64
    let duration: TimeInterval

    var growth: UInt64 { endBytes > startBytes ? endBytes - startBytes : 0 }
}
