import Foundation

/// Which notifications the user opted into. Everything is off until `isEnabled` is turned on.
struct NotificationPreferences: Sendable, Equatable {
    var isEnabled: Bool
    var criticalPressure: Bool
    var sustainedPressure: Bool
    var rapidSwapGrowth: Bool
    var appMemoryGrowth: Bool

    static let disabled = NotificationPreferences(isEnabled: false, criticalPressure: false, sustainedPressure: false, rapidSwapGrowth: false, appMemoryGrowth: false)
}

enum AlertKind: String, Sendable, CaseIterable {
    case criticalPressure
    case sustainedPressure
    case rapidSwapGrowth
    case appMemoryGrowth

    /// Minimum time between two alerts of the same kind (and subject).
    var cooldown: TimeInterval {
        switch self {
        case .criticalPressure: 15 * 60
        case .sustainedPressure: 60 * 60
        case .rapidSwapGrowth: 60 * 60
        case .appMemoryGrowth: 6 * 60 * 60
        }
    }
}

/// A notification RamLume wants to deliver.
struct AlertCandidate: Sendable, Equatable {
    var kind: AlertKind
    /// Identifies the episode, e.g. `appMemoryGrowth:app:/Applications/Foo.app`.
    var key: String
    var title: String
    var body: String
}

struct NotificationInput: Sendable {
    var now: Date
    var pressure: PressureState
    var trends: MemoryTrends
    var topConsumer: (name: String, bytes: UInt64)?
    var growthFindings: [ProcessGrowthFinding]
}

/// Decides when to notify. Deliberately conservative:
/// - nothing is delivered unless the user opted in;
/// - a fixed RAM percentage never triggers a notification;
/// - each condition alerts once per episode, and again only after its cooldown;
/// - non-critical alerts are spaced at least `minimumSpacing` apart.
struct NotificationPolicy: Sendable, Equatable {
    /// Pressure must stay at warning or worse this long to count as sustained.
    var sustainedPressureDuration: TimeInterval = 5 * 60
    /// Swap growth over the change window that counts as rapid.
    var rapidSwapGrowth: Int64 = 2 * Int64(MemoryUnits.gibibyte)
    /// Swap written in 5 minutes that, together with warning pressure, makes it "serious".
    var seriousSwapOut: UInt64 = 256 * MemoryUnits.mebibyte
    /// Minimum spacing between any two non-critical notifications.
    var minimumSpacing: TimeInterval = 10 * 60

    private(set) var lastDelivered: [String: Date] = [:]
    private(set) var lastAnyDelivery: Date?
    private(set) var activeEpisodes: Set<String> = []

    mutating func evaluate(_ input: NotificationInput, preferences: NotificationPreferences) -> [AlertCandidate] {
        guard preferences.isEnabled else {
            activeEpisodes = []
            return []
        }

        var conditions: [AlertCandidate] = []
        let level = input.pressure.level

        if preferences.criticalPressure, level == .critical {
            var body = "macOS reports critical memory pressure. Save your work and quit apps you don't need."
            if let top = input.topConsumer {
                body += " The largest is \(top.name) (\(MemoryFormatter.string(fromBytes: top.bytes, style: .compact)))."
            }
            conditions.append(AlertCandidate(kind: .criticalPressure, key: AlertKind.criticalPressure.rawValue,
                                             title: "Memory pressure is critical", body: body))
        }

        if preferences.sustainedPressure, let level, level >= .warning,
           let duration = input.pressure.elevatedDuration(at: input.now), duration >= sustainedPressureDuration,
           (input.trends.swapOutRecent ?? 0) >= seriousSwapOut || (input.trends.swapUsedChange ?? 0) >= rapidSwapGrowth / 4 {
            conditions.append(AlertCandidate(
                kind: .sustainedPressure,
                key: AlertKind.sustainedPressure.rawValue,
                title: "Sustained memory pressure",
                body: "Your Mac has been under memory pressure for \(MemoryFormatter.duration(duration)) and is swapping to disk. Closing apps you aren't using may improve performance."
            ))
        }

        if preferences.rapidSwapGrowth, let growth = input.trends.swapUsedChange, growth >= rapidSwapGrowth {
            conditions.append(AlertCandidate(
                kind: .rapidSwapGrowth,
                key: AlertKind.rapidSwapGrowth.rawValue,
                title: "Swap is growing quickly",
                body: "Swap use grew by \(MemoryFormatter.string(fromBytes: UInt64(growth), style: .compact)) in the last \(MemoryFormatter.duration(input.trends.changeSpan))."
            ))
        }

        if preferences.appMemoryGrowth {
            for finding in input.growthFindings {
                conditions.append(AlertCandidate(
                    kind: .appMemoryGrowth,
                    key: "\(AlertKind.appMemoryGrowth.rawValue):\(finding.id)",
                    title: "\(finding.displayName)'s memory keeps growing",
                    body: "It grew from \(MemoryFormatter.string(fromBytes: finding.startBytes, style: .compact)) to \(MemoryFormatter.string(fromBytes: finding.endBytes, style: .compact)) over \(MemoryFormatter.duration(finding.duration)). This can be normal for some workloads."
                ))
            }
        }

        // Episodes end when their condition clears; they can alert again after that.
        let currentKeys = Set(conditions.map(\.key))
        activeEpisodes.formIntersection(currentKeys)

        var delivered: [AlertCandidate] = []
        for candidate in conditions where !activeEpisodes.contains(candidate.key) {
            if let last = lastDelivered[candidate.key], input.now.timeIntervalSince(last) < candidate.kind.cooldown {
                // Still cooling down: treat as handled for this episode.
                activeEpisodes.insert(candidate.key)
                continue
            }
            if candidate.kind != .criticalPressure, let lastAny = lastAnyDelivery,
               input.now.timeIntervalSince(lastAny) < minimumSpacing {
                // Spacing not met yet; try again on a later evaluation without ending the episode.
                continue
            }
            delivered.append(candidate)
            activeEpisodes.insert(candidate.key)
            lastDelivered[candidate.key] = input.now
            lastAnyDelivery = input.now
        }
        return delivered
    }
}
