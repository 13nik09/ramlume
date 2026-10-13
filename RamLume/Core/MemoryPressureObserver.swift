import Dispatch
import Foundation

/// Kernel-reported pressure indicators read during each sample.
struct KernelPressureIndicators: Sendable, Equatable {
    /// `kern.memorystatus_vm_pressure_level`, or `nil` when unavailable.
    var level: MemoryPressureLevel?
    /// `kern.memorystatus_level` (0–100), or `nil` when unavailable.
    var freePercentage: Int?
}

protocol PressureLevelProviding: Sendable {
    func readIndicators() -> KernelPressureIndicators
}

/// Reads the kernel's current pressure level.
///
/// The documented API, `DispatchSource.makeMemoryPressureSource`, only reports *changes*, so on
/// its own it can't tell whether the system was already under pressure when RamLume launched or
/// resumed. The `kern.memorystatus_vm_pressure_level` sysctl (the value Apple's `memory_pressure`
/// tool reports) provides the current level. It isn't described in Apple's developer
/// documentation, so RamLume treats it as optional: values are size- and range-checked, and when
/// it's unavailable RamLume falls back to dispatch events alone (see `MonitoringCoordinator`).
struct KernelPressureReader: PressureLevelProviding {
    func readIndicators() -> KernelPressureIndicators {
        let level = SysctlReader.integer(named: "kern.memorystatus_vm_pressure_level", as: Int32.self)
            .flatMap(MemoryPressureLevel.init(kernelValue:))
        let freePercentage = SysctlReader.integer(named: "kern.memorystatus_level", as: Int32.self)
            .flatMap { (0...100).contains($0) ? Int($0) : nil }
        return KernelPressureIndicators(level: level, freePercentage: freePercentage)
    }
}

#if DEBUG
/// Simulates a macOS without the pressure sysctls (`--pressure-events-only`), to exercise the
/// events-only fallback in the running app.
struct EventsOnlyPressureReader: PressureLevelProviding {
    func readIndicators() -> KernelPressureIndicators {
        KernelPressureIndicators(level: nil, freePercentage: nil)
    }
}
#endif

/// What a dispatch memory-pressure event says about the current level.
enum PressureEventReading: Sendable, Equatable {
    case level(MemoryPressureLevel)
    /// Dispatch merged several transitions into one event (their flags are OR-ed), so the order
    /// — and therefore the current level — can't be known from the event alone.
    case ambiguous

    init?(event: DispatchSource.MemoryPressureEvent) {
        var levels: [MemoryPressureLevel] = []
        if event.contains(.normal) { levels.append(.normal) }
        if event.contains(.warning) { levels.append(.warning) }
        if event.contains(.critical) { levels.append(.critical) }
        switch levels.count {
        case 0: return nil
        case 1: self = .level(levels[0])
        default: self = .ambiguous
        }
    }
}

/// Delivers system memory-pressure transitions as they happen, via
/// `DispatchSource.makeMemoryPressureSource`. Event-driven: costs nothing between events.
@MainActor
final class MemoryPressureObserver {
    private var source: (any DispatchSourceMemoryPressure)?
    private let handler: @MainActor (PressureEventReading) -> Void

    init(handler: @escaping @MainActor (PressureEventReading) -> Void) {
        self.handler = handler
    }

    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            MainActor.assumeIsolated {
                guard let reading = PressureEventReading(event: event) else { return }
                self?.handler(reading)
            }
        }
        source.activate()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
