import Foundation
import Testing
@testable import RamLume

@Suite("Recommendations")
struct RecommendationEngineTests {
    let now = Scenario.now

    private func recommendations(
        snapshot: MemorySnapshot? = Fixtures.snapshot(),
        pressure: PressureState = Scenario.pressure(.normal),
        trends: MemoryTrends = Scenario.trends(),
        processes: ProcessSnapshot? = nil,
        growth: [ProcessGrowthFinding] = []
    ) -> [Recommendation] {
        let health = HealthRules.assess(snapshot: snapshot, readError: nil, pressure: pressure, trends: trends, now: now)
        return RecommendationEngine.recommendations(for: DiagnosticsInput(
            now: now, snapshot: snapshot, pressure: pressure, health: health,
            trends: trends, processes: processes, growthFindings: growth
        ))
    }

    private func allText(_ recommendations: [Recommendation]) -> [String] {
        recommendations.flatMap { [$0.title, $0.summary, $0.reason, $0.suggestion ?? ""] + $0.steps }
    }

    @Test func aHealthyMacGetsNoInventedProblems() throws {
        let result = recommendations(snapshot: Fixtures.snapshot(usedFraction: 0.88))
        let first = try #require(result.first)
        #expect(first.id == "healthy")
        #expect(first.summary.hasPrefix("No changes are necessary."))
        #expect(first.reason.contains("of RAM in use"))
        #expect(!result.contains { $0.priority.isActionable })
        #expect(!result.contains { $0.id == "background-apps" })
    }

    @Test func aLargeBrowserIsAnOptionalTipWhileMemoryIsFine() throws {
        let result = recommendations(processes: Fixtures.braveSnapshot())
        #expect(result.first?.id == "healthy")
        let browser = try #require(result.first { $0.id.hasPrefix("browser:") })
        #expect(browser.priority == .tip)
        #expect(browser.title.hasPrefix("Brave Browser is using "))
        #expect(browser.suggestion == "Turn on Memory Saver in Brave Browser.")
        // Brave's own setting: Settings › System › Performance › Memory Saver.
        #expect(browser.steps.contains { $0.contains("Choose System, then find Performance") })
        #expect(browser.steps.contains { $0.contains("Turn on Memory Saver") })
        #expect(browser.steps.contains("Close tabs you no longer need."))
        #expect(browser.reason.contains("RamLume can't see which tab uses what"))
    }

    @Test func sustainedPressureComesFirstAndNamesTheLargestApps() throws {
        let result = recommendations(
            pressure: Scenario.pressure(.warning, for: 600),
            trends: Scenario.trends(swapOut: 600 * Fixtures.mib, swapChange: Int64(Fixtures.gib)),
            processes: Fixtures.braveSnapshot()
        )
        let first = try #require(result.first)
        #expect(first.id == "sustained-pressure")
        #expect(first.priority == .important)
        #expect(first.summary.contains("can slow your Mac down"))
        #expect(first.reason.contains("Brave Browser"))
        #expect(first.actions.contains(.viewApplications))
        #expect(result.first { $0.id.hasPrefix("browser:") }?.priority == .suggested)
        #expect(result.contains { $0.id == "background-apps" && $0.actions == [.openLoginItemsSettings] })
        #expect(!result.contains { $0.id == "healthy" })
    }

    @Test func briefPressureIsOnlyASuggestion() {
        let result = recommendations(pressure: Scenario.pressure(.warning, for: 30))
        #expect(result.first?.id == "elevated-pressure")
        #expect(result.first?.priority == .suggested)
        #expect(!result.contains { $0.id == "sustained-pressure" })
    }

    @Test func criticalPressureIsUrgent() throws {
        let result = recommendations(pressure: Scenario.pressure(.critical, for: 60), processes: Fixtures.braveSnapshot())
        let first = try #require(result.first)
        #expect(first.id == "critical-pressure")
        #expect(first.priority == .urgent)
        #expect(first.actions == [.viewApplications, .openActivityMonitor])
    }

    @Test func quietSwapIsExplainedNotTreatedAsAProblem() throws {
        let result = recommendations(snapshot: Fixtures.snapshot(swapUsed: Fixtures.gib), trends: Scenario.trends(swapOut: 0, swapChange: 0))
        let swap = try #require(result.first { $0.id == "swap-at-rest" })
        #expect(swap.summary == "macOS can keep inactive data in swap even after RAM becomes available. This is usually normal.")
        #expect(swap.priority == .status)
        #expect(result.first?.id == "healthy")
    }

    @Test func memoryGrowthIsReportedWithoutDiagnosingALeak() throws {
        let finding = ProcessGrowthFinding(id: "app:/Applications/Mail.app", displayName: "Mail", startBytes: 400 * Fixtures.mib, endBytes: 1_600 * Fixtures.mib, duration: 3_600)
        let result = recommendations(growth: [finding])
        let growth = try #require(result.first { $0.id == "growth:app:/Applications/Mail.app" })
        #expect(growth.priority == .tip)
        #expect(growth.suggestion == "If Mail becomes slow, save your work, then quit and reopen it.")
        #expect(!allText([growth]).contains { $0.localizedCaseInsensitiveContains("leak") })
    }

    @Test func checkingWhileThereIsNoData() {
        let result = recommendations(snapshot: nil, pressure: .unknown)
        #expect(result.map(\.id) == ["checking"])
    }

    @Test func neverSuggestsRestartingOrCleaning() {
        let scenarios: [[Recommendation]] = [
            recommendations(processes: Fixtures.braveSnapshot()),
            recommendations(snapshot: Fixtures.snapshot(swapUsed: Fixtures.gib)),
            recommendations(pressure: Scenario.pressure(.warning, for: 600), trends: Scenario.trends(swapOut: 600 * Fixtures.mib, swapChange: Int64(Fixtures.gib)), processes: Fixtures.braveSnapshot()),
            recommendations(pressure: Scenario.pressure(.critical, for: 60), processes: Fixtures.braveSnapshot()),
        ]
        for text in scenarios.flatMap(allText) {
            #expect(!text.hasPrefix("Restart"))
            #expect(!text.localizedCaseInsensitiveContains("clean"))
            #expect(!text.localizedCaseInsensitiveContains("purge"))
        }
    }

    @Test func sameMeasurementsGiveTheSameRecommendations() {
        let make = {
            recommendations(pressure: Scenario.pressure(.warning, for: 600), trends: Scenario.trends(swapOut: 600 * Fixtures.mib), processes: Fixtures.braveSnapshot())
        }
        #expect(make() == make())
    }

    @Test func plainHealthWording() {
        #expect(HealthState.healthy.sentence == "Your Mac is running smoothly.")
        #expect(HealthState.underPressure.title == "High Pressure")
        #expect(HealthState.critical.title == "High Pressure")
        #expect(HealthState.insufficientData.title == "Checking")
        let healthy = HealthRules.assess(snapshot: Fixtures.snapshot(), readError: nil, pressure: Scenario.pressure(.normal), trends: Scenario.trends(), now: now)
        #expect(healthy.plainDetail == "Memory pressure is low. No action needed.")
    }
}
