import Foundation

/// What the status item shows. A pure function of the current state, so it's unit tested.
///
/// Color is driven by RamLume's health assessment — never by the usage percentage — and only
/// appears when memory genuinely needs attention.
struct StatusItemPresentation: Equatable, Sendable {
    enum Tint: Equatable, Sendable {
        case serious
        case critical
    }

    var title: String
    var tint: Tint?
    var isDimmed: Bool
    var accessibilityLabel: String
    var toolTip: String

    static func make(
        snapshot: MemorySnapshot?,
        health: HealthState,
        pressure: MemoryPressureLevel?,
        status: MonitoringStateMachine.Status,
        style: MenuBarDisplayStyle,
        tintsIcon: Bool,
        locale: Locale = .current
    ) -> StatusItemPresentation {
        let paused = status == .pausedByUser

        var title = ""
        if style != .iconOnly {
            if let breakdown = snapshot?.breakdown {
                switch style {
                case .iconOnly:
                    break
                case .percentage:
                    title = MemoryFormatter.percent(breakdown.usedFraction, locale: locale)
                case .usedOfTotal:
                    title = MemoryFormatter.usedOfTotal(used: breakdown.used, total: breakdown.total, locale: locale)
                }
            } else {
                title = "—"
            }
        }

        var tint: Tint?
        if tintsIcon, !paused {
            switch health {
            case .critical: tint = .critical
            case .underPressure: tint = .serious
            default: tint = nil
            }
        }

        var spoken = ["RamLume"]
        var tip = ["RamLume"]
        if paused {
            spoken.append("Monitoring paused")
            tip.append("Monitoring paused")
        }
        if let breakdown = snapshot?.breakdown {
            let used = MemoryFormatter.string(fromBytes: breakdown.used, style: .compact, locale: locale)
            let total = MemoryFormatter.string(fromBytes: breakdown.total, style: .compact, locale: locale)
            let percent = MemoryFormatter.percent(breakdown.usedFraction, locale: locale)
            spoken.append("about \(percent) of memory in use, \(used) of \(total)")
            tip.append("≈ \(used) of \(total) in use (\(percent))")
        } else {
            spoken.append("memory statistics unavailable")
            tip.append("Memory statistics unavailable")
        }
        spoken.append("health \(health.title)")
        tip.append("Health: \(health.title)")
        if let pressure {
            spoken.append("macOS memory pressure \(pressure.displayName)")
            tip.append("macOS memory pressure: \(pressure.displayName)")
        }

        return StatusItemPresentation(
            title: title,
            tint: tint,
            isDimmed: paused,
            accessibilityLabel: spoken.joined(separator: ", "),
            toolTip: tip.joined(separator: "\n")
        )
    }
}
