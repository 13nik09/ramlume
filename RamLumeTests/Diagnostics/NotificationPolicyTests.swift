import Foundation
import Testing
@testable import RamLume

@Suite("Notification policy")
struct NotificationPolicyTests {
    let enabled = NotificationPreferences(isEnabled: true, criticalPressure: true, sustainedPressure: true, rapidSwapGrowth: true, appMemoryGrowth: true)
    let start = Scenario.now

    private func input(
        at offset: TimeInterval = 0,
        pressure: MemoryPressureLevel? = .normal,
        pressureFor duration: TimeInterval = 600,
        swapOut: UInt64 = 0,
        swapChange: Int64 = 0,
        growth: [ProcessGrowthFinding] = []
    ) -> NotificationInput {
        let now = start.addingTimeInterval(offset)
        let state = Scenario.pressure(pressure, for: duration, at: now)
        var trends = Scenario.trends(swapOut: swapOut, swapChange: swapChange)
        trends.changeSpan = 900
        return NotificationInput(now: now, pressure: state, trends: trends, topConsumer: ("Brave Browser", 4 * Fixtures.gib), growthFindings: growth)
    }

    @Test func nothingIsDeliveredUntilTheUserOptsIn() {
        var policy = NotificationPolicy()
        #expect(policy.evaluate(input(pressure: .critical), preferences: .disabled).isEmpty)
        var off = enabled
        off.isEnabled = false
        #expect(policy.evaluate(input(pressure: .critical), preferences: off).isEmpty)
    }

    @Test func highUsageAloneNeverNotifies() {
        var policy = NotificationPolicy()
        // Normal pressure, no swapping: no notification regardless of how full memory is.
        #expect(policy.evaluate(input(pressure: .normal), preferences: enabled).isEmpty)
    }

    @Test func criticalPressureAlertsOncePerEpisode() {
        var policy = NotificationPolicy()
        let first = policy.evaluate(input(pressure: .critical), preferences: enabled)
        #expect(first.map(\.kind) == [.criticalPressure])
        #expect(first.first?.body.contains("Brave Browser") == true)
        #expect(policy.evaluate(input(at: 60, pressure: .critical), preferences: enabled).isEmpty)
        #expect(policy.evaluate(input(at: 1_200, pressure: .critical), preferences: enabled).isEmpty)
    }

    @Test func cooldownAppliesAcrossEpisodes() {
        var policy = NotificationPolicy()
        _ = policy.evaluate(input(pressure: .critical), preferences: enabled)
        _ = policy.evaluate(input(at: 60, pressure: .normal), preferences: enabled)        // episode ends
        #expect(policy.evaluate(input(at: 120, pressure: .critical), preferences: enabled).isEmpty)  // still cooling down
        _ = policy.evaluate(input(at: 180, pressure: .normal), preferences: enabled)
        let later = policy.evaluate(input(at: 20 * 60, pressure: .critical), preferences: enabled)
        #expect(later.map(\.kind) == [.criticalPressure])
    }

    @Test func sustainedPressureNeedsDurationAndSwapping() {
        var policy = NotificationPolicy()
        #expect(policy.evaluate(input(pressure: .warning, pressureFor: 120, swapOut: Fixtures.gib), preferences: enabled).isEmpty)
        #expect(policy.evaluate(input(pressure: .warning, pressureFor: 900, swapOut: 0), preferences: enabled).isEmpty)
        let alert = policy.evaluate(input(pressure: .warning, pressureFor: 900, swapOut: Fixtures.gib), preferences: enabled)
        #expect(alert.map(\.kind) == [.sustainedPressure])
    }

    @Test func sustainedPressureCountsWarningAndCriticalTogether() {
        var policy = NotificationPolicy()
        var preferences = enabled
        preferences.criticalPressure = false
        // Warning for one minute after a stretch at critical: elevated for 15 minutes in total.
        var alternating = input(pressure: .warning, pressureFor: 60, swapOut: Fixtures.gib)
        alternating.pressure.elevatedSince = alternating.now.addingTimeInterval(-900)
        let alert = policy.evaluate(alternating, preferences: preferences)
        #expect(alert.map(\.kind) == [.sustainedPressure])
        #expect(alert.first?.body.contains("for 15 min") == true)
    }

    @Test func nonCriticalAlertsAreSpacedOut() {
        var policy = NotificationPolicy()
        let swap = policy.evaluate(input(swapChange: Int64(3 * Fixtures.gib)), preferences: enabled)
        #expect(swap.map(\.kind) == [.rapidSwapGrowth])
        let finding = ProcessGrowthFinding(id: "app:/Applications/Foo.app", displayName: "Foo", startBytes: Fixtures.gib, endBytes: 3 * Fixtures.gib, duration: 2_400)
        // Within the spacing window: held back, not dropped.
        #expect(policy.evaluate(input(at: 60, growth: [finding]), preferences: enabled).isEmpty)
        let later = policy.evaluate(input(at: 15 * 60, growth: [finding]), preferences: enabled)
        #expect(later.map(\.kind) == [.appMemoryGrowth])
    }

    @Test func criticalBypassesSpacing() {
        var policy = NotificationPolicy()
        _ = policy.evaluate(input(swapChange: Int64(3 * Fixtures.gib)), preferences: enabled)
        let critical = policy.evaluate(input(at: 30, pressure: .critical, swapChange: Int64(3 * Fixtures.gib)), preferences: enabled)
        #expect(critical.map(\.kind) == [.criticalPressure])
    }

    /// A cooldown measured against a clock that was set back would otherwise last until the
    /// clock caught up again.
    @Test func aClockSetBackDoesNotSilenceAlerts() {
        var policy = NotificationPolicy()
        #expect(policy.evaluate(input(pressure: .critical), preferences: enabled).map(\.kind) == [.criticalPressure])
        _ = policy.evaluate(input(at: 60, pressure: .normal), preferences: enabled)        // episode ends
        // The clock now reads a day earlier.
        let earlier = policy.evaluate(input(at: -86_400, pressure: .critical), preferences: enabled)
        #expect(earlier.map(\.kind) == [.criticalPressure])

        var spaced = NotificationPolicy()
        _ = spaced.evaluate(input(swapChange: Int64(3 * Fixtures.gib)), preferences: enabled)
        let finding = ProcessGrowthFinding(id: "app:/Applications/Foo.app", displayName: "Foo", startBytes: Fixtures.gib, endBytes: 3 * Fixtures.gib, duration: 2_400)
        let afterStep = spaced.evaluate(input(at: -86_400, growth: [finding]), preferences: enabled)
        #expect(afterStep.map(\.kind) == [.appMemoryGrowth])
    }

    @Test func respectsIndividualToggles() {
        var policy = NotificationPolicy()
        var preferences = enabled
        preferences.criticalPressure = false
        #expect(policy.evaluate(input(pressure: .critical), preferences: preferences).isEmpty)
    }
}
