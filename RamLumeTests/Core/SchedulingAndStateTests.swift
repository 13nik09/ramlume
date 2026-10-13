import Foundation
import ServiceManagement
import Testing
@testable import RamLume

@Suite("Sampling scheduler")
struct SamplingSchedulerTests {
    @Test func balancedMatchesSuggestedIntervals() {
        var scheduler = SamplingScheduler(profile: .balanced)
        #expect(scheduler.cadence == SamplingCadence(memoryInterval: 5, processInterval: 60))
        scheduler.visibility = .dashboard
        #expect(scheduler.cadence == SamplingCadence(memoryInterval: 1, processInterval: 15))
        scheduler.visibility = .menuPanel
        #expect(scheduler.cadence.memoryInterval == 1)
    }

    @Test func screensAsleepSlowsBackgroundSampling() {
        var scheduler = SamplingScheduler(profile: .balanced)
        scheduler.screensAsleep = true
        #expect(scheduler.cadence.memoryInterval == 30)
        #expect(scheduler.cadence.processInterval == 300)
    }

    @Test func lowPowerModeUsesEnergySaverWhenAllowed() {
        var scheduler = SamplingScheduler(profile: .responsive, isLowPowerModeEnabled: true)
        #expect(scheduler.effectiveProfile == .energySaver)
        #expect(scheduler.cadence.memoryInterval == 15)
        scheduler.usesEnergySaverInLowPowerMode = false
        #expect(scheduler.effectiveProfile == .responsive)
        #expect(scheduler.cadence.memoryInterval == 2)
    }

    @Test(arguments: MonitoringProfile.allCases)
    func intervalsAreOrdered(profile: MonitoringProfile) {
        let table = SamplingScheduler.intervals(for: profile)
        #expect(table.visibleMemory <= table.backgroundMemory)
        #expect(table.backgroundMemory <= table.idleMemory)
        #expect(table.visibleProcesses <= table.backgroundProcesses)
        #expect(table.visibleMemory < table.visibleProcesses)
    }
}

@Suite("Monitoring state transitions")
struct MonitoringStateMachineTests {
    @Test func startsSampling() {
        var machine = MonitoringStateMachine()
        #expect(machine.status == .stopped)
        #expect(machine.handle(.start) == .startSampling)
        #expect(machine.status == .running)
        #expect(machine.handle(.start) == MonitoringStateMachine.Transition.none)
    }

    @Test func pauseAndResume() {
        var machine = MonitoringStateMachine()
        _ = machine.handle(.start)
        #expect(machine.handle(.pauseRequested) == .stopSampling(.monitoringPaused))
        #expect(machine.status == .pausedByUser)
        #expect(machine.handle(.pauseRequested) == MonitoringStateMachine.Transition.none)
        #expect(machine.handle(.resumeRequested) == .startSampling)
    }

    @Test func sleepAndWake() {
        var machine = MonitoringStateMachine()
        _ = machine.handle(.start)
        #expect(machine.handle(.systemWillSleep) == .stopSampling(.systemSleep))
        #expect(machine.status == .systemAsleep)
        #expect(machine.handle(.systemDidWake) == .startSampling)
    }

    @Test func wakingDoesNotOverrideUserPause() {
        var machine = MonitoringStateMachine()
        _ = machine.handle(.start)
        _ = machine.handle(.pauseRequested)
        #expect(machine.handle(.systemWillSleep) == MonitoringStateMachine.Transition.none)
        #expect(machine.handle(.systemDidWake) == MonitoringStateMachine.Transition.none)
        #expect(machine.status == .pausedByUser)
        #expect(machine.handle(.resumeRequested) == .startSampling)
    }

    @Test func resumeWhileAsleepWaitsForWake() {
        var machine = MonitoringStateMachine()
        _ = machine.handle(.start)
        _ = machine.handle(.pauseRequested)
        _ = machine.handle(.systemWillSleep)
        #expect(machine.handle(.resumeRequested) == MonitoringStateMachine.Transition.none)
        #expect(machine.handle(.systemDidWake) == .startSampling)
    }

    @Test func eventsBeforeStartDoNothing() {
        var machine = MonitoringStateMachine()
        #expect(machine.handle(.systemDidWake) == MonitoringStateMachine.Transition.none)
        #expect(machine.handle(.resumeRequested) == MonitoringStateMachine.Transition.none)
        #expect(!machine.isSampling)
    }
}

@Suite("Status item presentation")
struct StatusItemPresentationTests {
    let posix = Locale(identifier: "en_US_POSIX")

    @Test func titlesForEachStyle() {
        let snapshot = Fixtures.snapshot(usedFraction: 0.62)
        #expect(StatusItemPresentation.make(snapshot: snapshot, health: .healthy, pressure: .normal, status: .running, style: .iconOnly, tintsIcon: true, locale: posix).title == "")
        #expect(StatusItemPresentation.make(snapshot: snapshot, health: .healthy, pressure: .normal, status: .running, style: .percentage, tintsIcon: true, locale: posix).title == "62%")
        #expect(StatusItemPresentation.make(snapshot: snapshot, health: .healthy, pressure: .normal, status: .running, style: .usedOfTotal, tintsIcon: true, locale: posix).title == "9.9/16 GB")
    }

    @Test func highUsageAloneIsNotTinted() {
        let snapshot = Fixtures.snapshot(usedFraction: 0.95)
        let presentation = StatusItemPresentation.make(snapshot: snapshot, health: .healthy, pressure: .normal, status: .running, style: .percentage, tintsIcon: true, locale: posix)
        #expect(presentation.tint == nil)
    }

    @Test func tintFollowsHealth() {
        let snapshot = Fixtures.snapshot(usedFraction: 0.5)
        func tint(_ health: HealthState, enabled: Bool = true, status: MonitoringStateMachine.Status = .running) -> StatusItemPresentation.Tint? {
            StatusItemPresentation.make(snapshot: snapshot, health: health, pressure: .warning, status: status, style: .iconOnly, tintsIcon: enabled, locale: posix).tint
        }
        #expect(tint(.elevated) == nil)
        #expect(tint(.underPressure) == .serious)
        #expect(tint(.critical) == .critical)
        #expect(tint(.critical, enabled: false) == nil)
        #expect(tint(.critical, status: .pausedByUser) == nil)
    }

    @Test func missingDataAndPauseAreExplicit() {
        let unavailable = StatusItemPresentation.make(snapshot: nil, health: .insufficientData, pressure: nil, status: .running, style: .percentage, tintsIcon: true, locale: posix)
        #expect(unavailable.title == "—")
        #expect(unavailable.accessibilityLabel.contains("unavailable"))

        let paused = StatusItemPresentation.make(snapshot: Fixtures.snapshot(), health: .healthy, pressure: .normal, status: .pausedByUser, style: .percentage, tintsIcon: true, locale: posix)
        #expect(paused.isDimmed)
        #expect(paused.accessibilityLabel.contains("paused"))
    }
}

@Suite("Pressure state")
struct PressureStateTests {
    let start = Fixtures.reference

    @Test func elevatedDurationSurvivesChangesBetweenWarningAndCritical() {
        var state = PressureState.unknown
        _ = state.update(level: .normal, source: .kernelLevel, at: start)
        _ = state.update(level: .warning, source: .kernelLevel, at: start.addingTimeInterval(60))
        _ = state.update(level: .critical, source: .systemEvent, at: start.addingTimeInterval(120))
        _ = state.update(level: .warning, source: .kernelLevel, at: start.addingTimeInterval(180))
        let now = start.addingTimeInterval(360)
        #expect(state.duration(at: now) == 180)            // at warning since the last change
        #expect(state.elevatedDuration(at: now) == 300)    // elevated since the first warning
        #expect(state.elevatedSinceIsLowerBound == false)

        _ = state.update(level: .normal, source: .kernelLevel, at: now)
        #expect(state.elevatedSince == nil)
        #expect(state.elevatedDuration(at: now.addingTimeInterval(10)) == nil)
    }

    @Test func firstReadingAfterAGapIsALowerBound() {
        var state = PressureState.unknown
        let first = state.update(level: .warning, source: .kernelLevel, at: start)
        #expect(first.changed && first.previous == nil)
        #expect(state.observedSinceIsLowerBound)
        #expect(state.elevatedSinceIsLowerBound)

        // Moving to critical is a new level but the same elevated episode.
        _ = state.update(level: .critical, source: .kernelLevel, at: start.addingTimeInterval(30))
        #expect(state.observedSinceIsLowerBound == false)
        #expect(state.elevatedSince == start)
        #expect(state.elevatedSinceIsLowerBound)
    }

    @Test func repeatedReadingsDontRestartTheClock() {
        var state = PressureState.unknown
        _ = state.update(level: .warning, source: .kernelLevel, at: start)
        let repeated = state.update(level: .warning, source: .systemEvent, at: start.addingTimeInterval(100))
        #expect(repeated.changed == false)
        #expect(state.observedSince == start)
        #expect(state.elevatedSince == start)
        #expect(state.source == .systemEvent)
    }
}

@Suite("Chart ranges")
struct ChartRangeTests {
    @Test func rangesFollowRetention() {
        #expect(ChartRange.available(for: .oneHour) == [.fiveMinutes, .fifteenMinutes, .oneHour])
        #expect(ChartRange.available(for: .oneDay) == [.fiveMinutes, .fifteenMinutes, .oneHour, .oneDay])
        #expect(ChartRange.available(for: .sevenDays) == ChartRange.allCases)
    }

    @Test func clampingFallsBackToTheLongestAvailableRange() {
        #expect(ChartRange.clamped(.sevenDays, to: .oneHour) == .oneHour)
        #expect(ChartRange.clamped(.sevenDays, to: .oneDay) == .oneDay)
        #expect(ChartRange.clamped(.oneDay, to: .oneDay) == .oneDay)
        #expect(ChartRange.clamped(.fiveMinutes, to: .oneHour) == .fiveMinutes)
    }
}

@MainActor
@Suite("Launch at login")
struct LaunchAtLoginTests {
    @Test func neverRegisteredIsOffNotUnavailable() {
        // macOS reports `.notFound` for an app that was never registered.
        #expect(LaunchAtLoginService.map(.notFound) == .disabled)
        #expect(LaunchAtLoginService.map(.notRegistered) == .disabled)
        #expect(LaunchAtLoginService.map(.enabled) == .enabled)
        #expect(LaunchAtLoginService.map(.requiresApproval) == .requiresApproval)
    }

    @Test func recognizesApplicationsFolders() {
        #expect(LaunchAtLoginService.isInApplicationsFolder(URL(fileURLWithPath: "/Applications/RamLume.app")))
        #expect(LaunchAtLoginService.isInApplicationsFolder(URL(fileURLWithPath: NSHomeDirectory() + "/Applications/RamLume.app")))
        #expect(!LaunchAtLoginService.isInApplicationsFolder(URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/RamLume.app")))
        #expect(!LaunchAtLoginService.isInApplicationsFolder(URL(fileURLWithPath: "/Volumes/RamLume/RamLume.app")))
        #expect(!LaunchAtLoginService.isInApplicationsFolder(URL(fileURLWithPath: "/Applications-old/RamLume.app")))
    }
}
