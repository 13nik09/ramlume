import Foundation

/// Which RamLume surfaces are currently on screen.
enum InterfaceVisibility: Int, Sendable, Comparable {
    case hidden = 0
    case menuPanel = 1
    case dashboard = 2

    static func < (lhs: InterfaceVisibility, rhs: InterfaceVisibility) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Sampling intervals in seconds.
struct SamplingCadence: Sendable, Equatable {
    /// How often system memory statistics are read.
    var memoryInterval: TimeInterval
    /// How often processes are enumerated.
    var processInterval: TimeInterval
}

/// Decides how often to sample, so a single loop in `MonitoringCoordinator` drives all polling.
///
/// Memory statistics are cheap to read (a few microseconds), so they're sampled frequently only
/// while a RamLume window is visible. Process scans touch every process and run less often.
struct SamplingScheduler: Sendable, Equatable {
    var profile: MonitoringProfile = .balanced
    var visibility: InterfaceVisibility = .hidden
    var screensAsleep = false
    var isLowPowerModeEnabled = false
    var usesEnergySaverInLowPowerMode = true

    /// The profile actually in effect (Energy Saver while Low Power Mode is on, if enabled).
    var effectiveProfile: MonitoringProfile {
        isLowPowerModeEnabled && usesEnergySaverInLowPowerMode ? .energySaver : profile
    }

    var cadence: SamplingCadence {
        Self.makeCadence(for: effectiveProfile, visibility: visibility, screensAsleep: screensAsleep)
    }

    static func makeCadence(
        for profile: MonitoringProfile,
        visibility: InterfaceVisibility,
        screensAsleep: Bool
    ) -> SamplingCadence {
        let table = intervals(for: profile)
        // First: a panel or dashboard left open doesn't count while nobody can see the displays.
        if screensAsleep {
            return SamplingCadence(memoryInterval: table.idleMemory, processInterval: table.idleProcesses)
        }
        if visibility > .hidden {
            return SamplingCadence(memoryInterval: table.visibleMemory, processInterval: table.visibleProcesses)
        }
        return SamplingCadence(memoryInterval: table.backgroundMemory, processInterval: table.backgroundProcesses)
    }

    struct IntervalTable: Sendable, Equatable {
        var visibleMemory: TimeInterval
        var backgroundMemory: TimeInterval
        /// Used while the displays are asleep and nobody can see the menu bar.
        var idleMemory: TimeInterval
        var visibleProcesses: TimeInterval
        var backgroundProcesses: TimeInterval
        var idleProcesses: TimeInterval
    }

    static func intervals(for profile: MonitoringProfile) -> IntervalTable {
        switch profile {
        case .responsive:
            IntervalTable(visibleMemory: 1, backgroundMemory: 2, idleMemory: 30,
                          visibleProcesses: 10, backgroundProcesses: 30, idleProcesses: 120)
        case .balanced:
            IntervalTable(visibleMemory: 1, backgroundMemory: 5, idleMemory: 30,
                          visibleProcesses: 15, backgroundProcesses: 60, idleProcesses: 300)
        case .energySaver:
            IntervalTable(visibleMemory: 2, backgroundMemory: 15, idleMemory: 60,
                          visibleProcesses: 30, backgroundProcesses: 300, idleProcesses: 600)
        }
    }
}

/// Whether sampling should run, given user and system events.
///
/// Kept separate from the coordinator so the transitions can be unit tested.
struct MonitoringStateMachine: Sendable, Equatable {
    enum Event: Sendable {
        case start
        case pauseRequested
        case resumeRequested
        case systemWillSleep
        case systemDidWake
    }

    enum Status: Sendable, Equatable {
        case stopped
        case running
        case pausedByUser
        case systemAsleep
    }

    enum Transition: Sendable, Equatable {
        case none
        case startSampling
        case stopSampling(HistoryGap.Reason)
    }

    private(set) var isStarted = false
    private(set) var isPausedByUser = false
    private(set) var isSystemAsleep = false

    var isSampling: Bool { isStarted && !isPausedByUser && !isSystemAsleep }

    var status: Status {
        if !isStarted { return .stopped }
        if isSystemAsleep { return .systemAsleep }
        if isPausedByUser { return .pausedByUser }
        return .running
    }

    /// Applies an event and reports whether sampling must start or stop as a result.
    mutating func handle(_ event: Event) -> Transition {
        let wasSampling = isSampling
        switch event {
        case .start: isStarted = true
        case .pauseRequested: isPausedByUser = true
        case .resumeRequested: isPausedByUser = false
        case .systemWillSleep: isSystemAsleep = true
        case .systemDidWake: isSystemAsleep = false
        }
        switch (wasSampling, isSampling) {
        case (false, true):
            return .startSampling
        case (true, false):
            return .stopSampling(isSystemAsleep ? .systemSleep : .monitoringPaused)
        default:
            return .none
        }
    }
}
