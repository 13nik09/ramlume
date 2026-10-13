import Foundation

/// The system-wide memory pressure level reported by macOS.
///
/// This is the kernel's own classification, read from the `kern.memorystatus_vm_pressure_level`
/// sysctl and from dispatch memory-pressure events. It is reported as-is; RamLume never
/// computes it. RamLume's separate health assessment (`HealthState`) is a heuristic.
enum MemoryPressureLevel: Int, Sendable, Codable, CaseIterable, Comparable {
    case normal = 1
    case warning = 2
    case critical = 4

    /// Interprets `kern.memorystatus_vm_pressure_level`. XNU reports dispatch-style values:
    /// 1 = normal, 2 = warning, 4 = critical. Anything else is rejected rather than guessed.
    init?(kernelValue: Int32) {
        switch kernelValue {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: return nil
        }
    }

    var severity: Int {
        switch self {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }

    static func < (lhs: MemoryPressureLevel, rhs: MemoryPressureLevel) -> Bool {
        lhs.severity < rhs.severity
    }

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    var isElevated: Bool { self != .normal }
}

/// Where the current pressure level came from.
enum PressureSource: String, Sendable, Codable {
    /// Read from the `kern.memorystatus_vm_pressure_level` sysctl during a sample.
    case kernelLevel
    /// Delivered by a `DispatchSource` memory-pressure event.
    case systemEvent
}

/// RamLume's knowledge of the current pressure level.
///
/// Durations only cover time RamLume actually observed: after a gap (launch, sleep, pause) the
/// state is reset, and the first reading afterwards starts a new observation that is marked as a
/// lower bound because the level may have begun earlier.
struct PressureState: Sendable, Equatable {
    var level: MemoryPressureLevel?
    var source: PressureSource?
    /// When RamLume first observed the current level.
    var observedSince: Date?
    /// `true` when the level was already active when observation began, so the real start is earlier.
    var observedSinceIsLowerBound: Bool
    /// When pressure last became warning-or-worse. Unlike `observedSince`, this survives changes
    /// between warning and critical, so "sustained" means "elevated", not "at one exact level".
    var elevatedSince: Date?
    var elevatedSinceIsLowerBound = false

    static let unknown = PressureState(level: nil, source: nil, observedSince: nil, observedSinceIsLowerBound: false)

    /// How long the current level has been observed, or `nil` if unknown.
    func duration(at now: Date) -> TimeInterval? {
        observedSince.map { max(now.timeIntervalSince($0), 0) }
    }

    /// How long pressure has been warning-or-worse without a break, or `nil` when it isn't elevated.
    func elevatedDuration(at now: Date) -> TimeInterval? {
        guard level?.isElevated == true else { return nil }
        return elevatedSince.map { max(now.timeIntervalSince($0), 0) }
    }

    /// Applies a new reading and reports whether the level changed.
    mutating func update(
        level newLevel: MemoryPressureLevel,
        source newSource: PressureSource,
        at date: Date
    ) -> (changed: Bool, previous: MemoryPressureLevel?) {
        let previous = level
        source = newSource
        guard newLevel != previous else { return (false, previous) }
        level = newLevel
        observedSince = date
        // The first reading after launch or a gap may describe a level that started earlier.
        observedSinceIsLowerBound = previous == nil
        if newLevel.isElevated {
            if previous?.isElevated != true {
                elevatedSince = date
                elevatedSinceIsLowerBound = previous == nil
            }
        } else {
            elevatedSince = nil
            elevatedSinceIsLowerBound = false
        }
        return (true, previous)
    }
}
