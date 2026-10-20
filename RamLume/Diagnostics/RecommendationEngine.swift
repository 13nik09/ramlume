import Foundation

/// Deterministic, offline tips for keeping memory pressure low. Every rule is a pure function of
/// the same input as the insights; the coordinator runs them once per sample, never per redraw.
///
/// Principles:
/// - When macOS reports normal pressure and the Mac isn't relying on swap, say so plainly and
///   suggest nothing: no invented problems. High RAM usage alone is never a reason to act.
/// - Only name apps RamLume can measure, and never claim which tab or document uses memory.
/// - Never suggest restarting to clear swap, "cleaning" RAM, or ending processes automatically.
///   Actions only open Apple's own tools or RamLume's own views.
enum RecommendationEngine {
    static func recommendations(for input: DiagnosticsInput, thresholds: HealthThresholds = .standard) -> [Recommendation] {
        guard input.snapshot != nil else { return [status(input, thresholds)] }
        var rules = [
            criticalPressure(input, thresholds),
            sustainedPressure(input, thresholds),
            elevatedPressure(input, thresholds),
            browser(input, thresholds),
            largeApp(input, thresholds),
        ].compactMap { $0 }
        rules += growth(input, thresholds)
        rules += [
            backgroundApps(input, thresholds),
            recentSwapping(input, thresholds),
            swapAtRest(input, thresholds),
        ].compactMap { $0 }
        // Most important first; rule order within a priority.
        var result = rules.enumerated()
            .sorted { $0.element.priority != $1.element.priority ? $0.element.priority > $1.element.priority : $0.offset < $1.offset }
            .map(\.element)
        if !result.contains(where: { $0.priority.isActionable }) {
            result.insert(status(input, thresholds), at: 0)
        }
        return result
    }

    // MARK: - Pressure

    static func criticalPressure(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Recommendation? {
        guard input.pressure.level == .critical else { return nil }
        var summary = "Your Mac is critically short of memory. Apps may freeze, and macOS may close apps on its own."
        if swapIsGrowing(input, thresholds) {
            summary += " It's also moving data to storage, which slows things down."
        }
        return Recommendation(
            id: "critical-pressure",
            priority: .urgent,
            symbolName: "exclamationmark.octagon.fill",
            title: "Free up memory now",
            summary: summary,
            reason: sentences("macOS reports critical memory pressure.", topAppsSentence(input)),
            suggestion: "Save your work, then quit apps you don't need.",
            steps: [
                "Save any open documents.",
                "Quit apps you aren't using: click the app, then press ⌘Q.",
                "In your browser, close tabs you no longer need.",
            ],
            actions: [.viewApplications, .openActivityMonitor]
        )
    }

    static func sustainedPressure(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Recommendation? {
        guard input.pressure.level == .warning,
              let duration = input.pressure.elevatedDuration(at: input.now),
              duration >= thresholds.sustainedPressureDuration else { return nil }
        let lasted = "\(input.pressure.elevatedSinceIsLowerBound ? "at least " : "")\(MemoryFormatter.duration(duration))"
        var summary = "Your Mac has been short of memory for \(lasted). Quitting apps you don't need will make it faster."
        var reason = ["macOS has reported elevated memory pressure for \(lasted)."]
        if swapIsGrowing(input, thresholds) {
            summary += " macOS is also moving data to storage (swap), which can slow your Mac down."
            reason.append(swapActivitySentence(input))
        }
        reason.append(topAppsSentence(input))
        var steps = [
            "Open Applications to see which apps use the most memory.",
            "Quit the ones you aren't using (click the app, then press ⌘Q).",
            "Close browser tabs you no longer need.",
        ]
        if !input.growthFindings.isEmpty {
            steps.append("If an app's memory keeps growing, save your work, then quit and reopen it.")
        }
        return Recommendation(
            id: "sustained-pressure",
            priority: .important,
            symbolName: "exclamationmark.triangle.fill",
            title: "Reduce memory use",
            summary: summary,
            reason: sentences(reason),
            suggestion: "Quit memory-heavy apps you aren't using.",
            steps: steps,
            actions: [.viewApplications, .openActivityMonitor]
        )
    }

    /// Warning-level pressure that hasn't lasted long enough to call sustained.
    static func elevatedPressure(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Recommendation? {
        guard input.pressure.level == .warning, sustainedPressure(input, thresholds) == nil else { return nil }
        return Recommendation(
            id: "elevated-pressure",
            priority: .suggested,
            symbolName: "exclamationmark.circle.fill",
            title: "Memory is getting tight",
            summary: "macOS is working harder than usual to make room, for example by compressing memory. This is common for a moment when you open large apps or documents.",
            reason: sentences("macOS reports elevated memory pressure.", topAppsSentence(input)),
            suggestion: "If your Mac feels slow, quit apps you aren't using.",
            actions: [.viewApplications]
        )
    }

    // MARK: - Apps

    static func browser(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Recommendation? {
        guard let snapshot = input.snapshot, let processes = input.processes else { return nil }
        let total = snapshot.breakdown.total
        let minimum = max(MemoryUnits.gibibyte, UInt64(Double(total) * 0.08))
        guard let match = processes.accessibleGroups.prefix(3).enumerated().first(where: {
                  $0.element.totalFootprint >= minimum && KnownApplications.browser(forBundleIdentifier: $0.element.bundleIdentifier) != nil
              }),
              let kind = KnownApplications.browser(forBundleIdentifier: match.element.bundleIdentifier) else { return nil }
        let rank = match.offset
        let group = match.element

        let name = group.displayName
        let size = MemoryFormatter.string(fromBytes: group.totalFootprint, style: .compact)
        let tight = memoryIsTight(input)
        let saver = kind.memorySaverName.map { "turning on \($0) lets inactive tabs give their memory back" }
        let summary: String
        if tight {
            summary = "\(name) is one of the largest memory users while memory is tight. " + (saver.map { "Closing tabs you no longer need, or \($0), will help." } ?? "Closing tabs you no longer need will help.")
        } else {
            summary = "That's fine while your Mac has room to spare. If you'd like to free memory, " + (saver.map { "\($0)." } ?? "close tabs you no longer need.")
        }
        let processCount = group.accessibleCount == 1 ? "" : " across \(group.accessibleCount) processes"
        let share = MemoryUnits.fraction(group.totalFootprint, of: total).map { " (\(MemoryFormatter.percent($0)) of RAM)" } ?? ""
        let reason = sentences(
            "\(name) is \(rank == 0 ? "the largest memory user" : "one of the largest memory users") RamLume can measure: \(size)\(processCount)\(share).",
            "Its tabs, extensions, and helper processes all add up; RamLume can't see which tab uses what."
        )
        var steps = kind.memorySaverSteps ?? []
        steps += [
            "Close tabs you no longer need.",
            "Turn off extensions you don't use, in \(name)'s extensions settings.",
            "Quit \(name) when you aren't using it; that releases all of its memory.",
        ]
        return Recommendation(
            id: "browser:\(group.id)",
            priority: tight ? .suggested : .tip,
            symbolName: "globe",
            title: "\(name) is using \(size)",
            summary: summary,
            reason: reason,
            suggestion: kind.memorySaverName.map { "Turn on \($0) in \(name)." } ?? "Close tabs you no longer need.",
            steps: steps,
            actions: [.viewApplications],
            appIconPath: group.representativePath
        )
    }

    /// The largest app, when RamLume knows something useful about it (browsers have their own rule).
    static func largeApp(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Recommendation? {
        guard let snapshot = input.snapshot, let top = input.processes?.largestAccessibleGroup,
              KnownApplications.browser(forBundleIdentifier: top.bundleIdentifier) == nil else { return nil }
        let total = snapshot.breakdown.total
        guard top.totalFootprint >= max(UInt64(1.5 * Double(MemoryUnits.gibibyte)), total / 10) else { return nil }
        let executableName = top.processes.first.map { ($0.executablePath ?? $0.name) }.map { ($0 as NSString).lastPathComponent }
        guard let advice = KnownApplications.advice(forBundleIdentifier: top.bundleIdentifier, executableName: executableName),
              let suggestion = advice.suggestion else { return nil }
        let size = MemoryFormatter.string(fromBytes: top.totalFootprint, style: .compact)
        return Recommendation(
            id: "large-app:\(top.id)",
            priority: memoryIsTight(input) ? .suggested : .tip,
            symbolName: "macwindow",
            title: "\(top.displayName) is using \(size)",
            summary: advice.context,
            reason: "\(top.displayName) is the largest memory user RamLume can measure: \(size).",
            suggestion: suggestion,
            actions: [.viewApplications],
            appIconPath: top.representativePath
        )
    }

    static func growth(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> [Recommendation] {
        input.growthFindings.prefix(2).map { finding in
            let name = finding.displayName
            let from = MemoryFormatter.string(fromBytes: finding.startBytes, style: .compact)
            let to = MemoryFormatter.string(fromBytes: finding.endBytes, style: .compact)
            let period = MemoryFormatter.duration(finding.duration)
            return Recommendation(
                id: "growth:\(finding.id)",
                priority: memoryIsTight(input) ? .suggested : .tip,
                symbolName: "chart.line.uptrend.xyaxis",
                title: "\(name)'s memory keeps growing",
                summary: "\(name) grew from \(from) to \(to) over the last \(period). Some apps use more memory as you work, for example with large documents; steady growth can also mean an app isn't giving memory back.",
                reason: "RamLume measured steady growth in \(name) for \(period).",
                suggestion: "If \(name) becomes slow, save your work, then quit and reopen it.",
                steps: [
                    "Save your work in \(name).",
                    "Quit \(name) (press ⌘Q) and open it again.",
                    "If it grows quickly again, check whether an update is available for it.",
                ],
                actions: [.viewApplications]
            )
        }
    }

    static func backgroundApps(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Recommendation? {
        guard memoryIsTight(input) else { return nil }
        return Recommendation(
            id: "background-apps",
            priority: .tip,
            symbolName: "rectangle.stack",
            title: "Review apps that run in the background",
            summary: "Apps that open at login or stay running in the menu bar use memory even when you aren't using them.",
            reason: "Your Mac has needed more memory than usual recently, so apps you don't need running are worth a look.",
            suggestion: "Remove apps you don't need from Login Items.",
            steps: [
                "Open System Settings, then General › Login Items (called Login Items & Extensions on newer versions of macOS).",
                "Under Open at Login, select apps you don't need at startup and click the – button.",
                "Under Allow in the Background, only turn off items you recognize and don't need; some keep apps you use working.",
                "Quit menu bar apps you don't use from their menu bar icons.",
            ],
            actions: [.openLoginItemsSettings]
        )
    }

    // MARK: - Swap

    /// Swapping in bursts while pressure is normal.
    static func recentSwapping(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Recommendation? {
        guard input.pressure.level == .normal,
              input.trends.activityCoverage >= thresholds.minimumActivityCoverage,
              let swapOut = input.trends.swapOutRecent, swapOut >= thresholds.notableSwapOut else { return nil }
        let amount = MemoryFormatter.string(fromBytes: swapOut, style: .compact)
        return Recommendation(
            id: "recent-swapping",
            priority: .tip,
            symbolName: "internaldrive",
            title: "Your Mac used swap recently",
            summary: "Your Mac moved \(amount) of data to storage in the last 5 minutes, although memory pressure is normal now. Short bursts like this are normal.",
            reason: "Swap written in the last 5 minutes: \(amount). macOS reports normal memory pressure.",
            suggestion: "If your Mac feels slow, quit apps you aren't using.",
            actions: [.viewApplications]
        )
    }

    /// Swap that's allocated but quiet: normal, and no reason to restart.
    static func swapAtRest(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Recommendation? {
        guard let swap = input.snapshot?.swap,
              input.pressure.level == .normal,
              swap.used >= 256 * MemoryUnits.mebibyte,
              input.trends.activityCoverage >= thresholds.minimumActivityCoverage,
              (input.trends.swapOutRecent ?? .max) < thresholds.notableSwapOut / 4,
              (input.trends.swapUsedChange ?? 0) < thresholds.notableSwapGrowth / 4 else { return nil }
        let used = MemoryFormatter.string(fromBytes: swap.used, style: .compact)
        return Recommendation(
            id: "swap-at-rest",
            priority: .status,
            symbolName: "internaldrive",
            title: "Swap in use is normal here",
            summary: "macOS can keep inactive data in swap even after RAM becomes available. This is usually normal.",
            reason: "\(used) of swap is in use, but your Mac hasn't been writing to swap recently and memory pressure is low.",
            suggestion: "No action needed. You don't need to restart your Mac to clear swap.",
            actions: [.viewMemoryDetails]
        )
    }

    // MARK: - Status

    /// Shown first when nothing needs doing.
    static func status(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Recommendation {
        switch input.health.state {
        case .healthy:
            var reason = "macOS reports normal memory pressure, and your Mac hasn't needed to rely on swap recently."
            if let fraction = input.snapshot?.breakdown.usedFraction, fraction >= thresholds.highUtilizationFraction {
                reason += " That's true even with \(MemoryFormatter.percent(fraction)) of RAM in use."
            }
            return Recommendation(
                id: "healthy",
                priority: .status,
                symbolName: "checkmark.circle.fill",
                title: "Your Mac is managing memory normally",
                summary: "No changes are necessary. Using a lot of RAM isn't a problem by itself: macOS keeps memory busy with apps and recently used data so things open faster.",
                reason: reason,
                actions: [.viewMemoryDetails]
            )
        case .insufficientData:
            return Recommendation(
                id: "checking",
                priority: .status,
                symbolName: "hourglass",
                title: "Checking your Mac's memory",
                summary: "Recommendations appear once RamLume has a few minutes of measurements.",
                reason: input.health.explanation
            )
        case .elevated, .underPressure, .critical:
            return Recommendation(
                id: "coping",
                priority: .status,
                symbolName: "checkmark.circle",
                title: "Your Mac is coping",
                summary: "Your Mac needed more memory than usual recently, and macOS is handling it. No action is needed unless things feel slow.",
                reason: input.health.explanation,
                actions: [.viewApplications]
            )
        }
    }

    // MARK: - Helpers

    /// Pressure above normal, or swapping that made RamLume's assessment worse than healthy.
    static func memoryIsTight(_ input: DiagnosticsInput) -> Bool {
        (input.pressure.level?.isElevated ?? false) || input.health.state.severity >= HealthState.elevated.severity
    }

    static func swapIsGrowing(_ input: DiagnosticsInput, _ thresholds: HealthThresholds) -> Bool {
        if let growth = input.trends.swapUsedChange, growth >= thresholds.notableSwapGrowth { return true }
        guard input.trends.activityCoverage >= thresholds.minimumActivityCoverage else { return false }
        return (input.trends.swapOutRecent ?? 0) >= thresholds.notableSwapOut
    }

    static func swapActivitySentence(_ input: DiagnosticsInput) -> String {
        if let growth = input.trends.swapUsedChange, growth > 0 {
            return "Swap grew by \(MemoryFormatter.string(fromBytes: UInt64(growth), style: .compact)) over the last \(MemoryFormatter.duration(input.trends.changeSpan))."
        }
        let written = MemoryFormatter.string(fromBytes: input.trends.swapOutRecent ?? 0, style: .compact)
        return "Your Mac wrote \(written) to swap in the last 5 minutes."
    }

    /// "The apps using the most memory are A (3.2 GB), B (2.1 GB), and C (455 MB)."
    static func topAppsSentence(_ input: DiagnosticsInput) -> String {
        guard let groups = input.processes?.accessibleGroups.prefix(3), !groups.isEmpty else { return "" }
        let names = groups.map { "\($0.displayName) (\(MemoryFormatter.string(fromBytes: $0.totalFootprint, style: .compact)))" }
        let list = ListFormatter.localizedString(byJoining: names)
        return names.count == 1 ? "The app using the most memory is \(list)." : "The apps using the most memory are \(list)."
    }

    private static func sentences(_ parts: String...) -> String {
        sentences(parts)
    }

    private static func sentences(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
