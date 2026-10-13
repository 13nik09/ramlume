import Foundation

/// A period with no data, recorded explicitly so charts show an honest gap.
struct HistoryGap: Sendable, Equatable, Codable {
    enum Reason: String, Sendable, Codable {
        case systemSleep
        case monitoringPaused
        case appNotRunning
        case readFailure

        var displayName: String {
            switch self {
            case .systemSleep: "Mac was asleep"
            case .monitoringPaused: "Monitoring paused"
            case .appNotRunning: "RamLume wasn't running"
            case .readFailure: "Statistics unavailable"
            }
        }
    }

    var start: Date
    var end: Date
    var reason: Reason

    var duration: TimeInterval { end.timeIntervalSince(start) }

    func overlaps(_ lower: Date, _ upper: Date) -> Bool {
        start < upper && end > lower
    }
}

/// Something worth listing on the dashboard's event timeline.
struct MemoryEvent: Sendable, Equatable, Codable, Identifiable {
    enum Kind: String, Sendable, Codable {
        case pressureChanged
        case healthChanged
        case systemSleep
        case systemWake
        case monitoringStarted
        case monitoringPaused
        case monitoringResumed
        case swapExpanded
        case readFailure
        case readRecovered

        var symbolName: String {
            switch self {
            case .pressureChanged: "gauge.with.dots.needle.67percent"
            case .healthChanged: "heart.text.square"
            case .systemSleep: "moon.zzz"
            case .systemWake: "sun.max"
            case .monitoringStarted: "play.circle"
            case .monitoringPaused: "pause.circle"
            case .monitoringResumed: "play.circle"
            case .swapExpanded: "externaldrive.badge.plus"
            case .readFailure: "exclamationmark.triangle"
            case .readRecovered: "checkmark.circle"
            }
        }
    }

    var id: UUID
    var date: Date
    var kind: Kind
    var title: String
    var detail: String?
    /// The new pressure level, for `pressureChanged` events.
    var pressure: MemoryPressureLevel?
    /// The new health state, for `healthChanged` events.
    var health: HealthState?

    init(
        id: UUID = UUID(),
        date: Date,
        kind: Kind,
        title: String,
        detail: String? = nil,
        pressure: MemoryPressureLevel? = nil,
        health: HealthState? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.title = title
        self.detail = detail
        self.pressure = pressure
        self.health = health
    }
}
