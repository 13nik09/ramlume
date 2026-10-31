import Foundation
import Observation
import Testing
@testable import RamLume

/// Drives the coordinator with fake readers and a controlled clock.
@MainActor
@Suite("Monitoring coordinator")
struct MonitoringCoordinatorTests {
    let clock = TestClock()
    let memory: FakeMemoryReader
    let swap = FakeSwapReader()
    let pressure = FakePressureReader()
    let history = HistoryStore(retention: .oneDay, persistence: nil, now: Fixtures.reference)
    let coordinator: MonitoringCoordinator

    init() {
        memory = FakeMemoryReader(clock: clock)
        let clock = clock
        coordinator = MonitoringCoordinator(
            memoryReader: .success(memory),
            swapReader: swap,
            pressureReader: pressure,
            processReader: FakeProcessProvider(snapshot: Fixtures.braveSnapshot()),
            history: history,
            clock: { clock.now },
            schedulesSampling: false
        )
    }

    private func sample(after seconds: TimeInterval = 5) {
        clock.advance(by: seconds)
        coordinator.sampleNow()
    }

    @Test func samplesUpdateCurrentStateAndHistory() throws {
        coordinator.start()
        #expect(coordinator.status == .running)
        sample()
        sample()
        let snapshot = try #require(coordinator.current.snapshot)
        #expect(snapshot.breakdown.total == Fixtures.physicalMemory)
        #expect(snapshot.activity != nil)   // second sample has a baseline
        #expect(coordinator.current.pressure.level == .normal)
        #expect(history.history.points(in: .raw).count == 2)
        #expect(history.events.elements.contains { $0.kind == .monitoringStarted })
    }

    @Test func publishesToSwiftUIOnlyWhileVisible() {
        coordinator.start()
        sample()
        #expect(coordinator.current.snapshot != nil)
        #expect(coordinator.snapshot == nil)        // nothing on screen yet

        coordinator.setVisible(true, surface: .menuPanel)
        #expect(coordinator.snapshot == coordinator.current.snapshot)
        let revisionWhileVisible = history.revision
        sample()
        #expect(history.revision > revisionWhileVisible)

        coordinator.setVisible(false, surface: .menuPanel)
        let revisionWhenHidden = history.revision
        let publishedWhenHidden = coordinator.snapshot
        sample()
        #expect(coordinator.snapshot == publishedWhenHidden)
        #expect(history.revision == revisionWhenHidden)
    }

    @Test func visibilityChangesCadence() {
        coordinator.start()
        #expect(coordinator.scheduler.cadence.memoryInterval == 5)
        coordinator.setVisible(true, surface: .dashboard)
        #expect(coordinator.scheduler.cadence.memoryInterval == 1)
        coordinator.setVisible(true, surface: .menuPanel)
        coordinator.setVisible(false, surface: .dashboard)
        #expect(coordinator.scheduler.visibility == .menuPanel)
        coordinator.setVisible(false, surface: .menuPanel)
        #expect(coordinator.scheduler.visibility == .hidden)
    }

    @Test func readFailureClearsValuesAndRecovers() throws {
        coordinator.start()
        sample()
        memory.update { $0.failure = .hostStatisticsFailed(code: 5) }
        sample()
        #expect(coordinator.current.snapshot == nil)
        #expect(coordinator.current.readError == .hostStatisticsFailed(code: 5))
        #expect(coordinator.current.health.state == .insufficientData)
        #expect(history.history.openGap?.reason == .readFailure)

        memory.update { $0.failure = nil }
        sample()
        #expect(coordinator.current.snapshot != nil)
        #expect(coordinator.current.readError == nil)
        #expect(history.history.openGap == nil)
        #expect(history.events.elements.contains { $0.kind == .readRecovered })
    }

    @Test func pauseStopsSamplingAndRecordsAGap() {
        coordinator.start()
        sample()
        coordinator.setPaused(true)
        #expect(coordinator.status == .pausedByUser)
        let count = history.history.points(in: .raw).count
        sample()    // sampleNow is ignored while paused
        #expect(history.history.points(in: .raw).count == count)
        #expect(history.history.openGap?.reason == .monitoringPaused)

        clock.advance(by: 60)
        coordinator.setPaused(false)
        #expect(coordinator.status == .running)
        #expect(history.history.openGap == nil)
        #expect(history.history.gaps.elements.last?.reason == .monitoringPaused)
    }

    // Scenario: sleep/wake gaps in history.
    @Test func sleepAndWakeAreRecordedAsAGap() {
        coordinator.start()
        sample()
        coordinator.systemWillSleep()
        #expect(coordinator.status == .systemAsleep)
        clock.advance(by: 1_800)
        coordinator.systemDidWake()
        sample()
        let gap = history.history.gaps.elements.last
        #expect(gap?.reason == .systemSleep)
        #expect((gap?.duration ?? 0) >= 1_800)
        // No rate is computed across the sleep: the first sample after waking has no baseline.
        let points = history.history.points(in: .raw)
        #expect(points.last?.activity == nil)
        let kinds = history.events.elements.map(\.kind)
        #expect(kinds.contains(.systemSleep) && kinds.contains(.systemWake))
    }

    @Test func pressureTransitionsAreLogged() {
        coordinator.start()
        sample()
        pressure.level = .warning
        sample()
        #expect(coordinator.current.health.state == .underPressure)
        coordinator.handlePressureEvent(.critical)
        #expect(coordinator.current.pressure.level == .critical || coordinator.current.pressure.level == .warning)
        let pressureEvents = history.events.elements.filter { $0.kind == .pressureChanged }
        #expect(pressureEvents.contains { $0.pressure == .warning })
    }

    @Test func pressureEventUpdatesHealthWithoutWaitingForTheNextSample() {
        coordinator.start()
        sample()
        let sampleCount = history.history.points(in: .raw).count
        pressure.level = .warning
        clock.advance(by: 0.2)
        coordinator.handlePressureEvent(.warning)
        #expect(coordinator.current.pressure.level == .warning)
        #expect(coordinator.current.health.state == .underPressure)
        // A sample was taken moments ago, so the event re-evaluates rather than sampling again.
        #expect(history.history.points(in: .raw).count == sampleCount)
    }

    @Test func pressureEventsAreConfirmedWithTheKernelLevel() {
        coordinator.start()
        sample()
        // Events can be coalesced, so the sysctl reading decides the current level.
        pressure.level = .critical
        coordinator.handlePressureEvent(.warning)
        #expect(coordinator.current.pressure.level == .critical)
        #expect(coordinator.current.pressure.source == .kernelLevel)
        #expect(coordinator.current.health.state == .critical)

        // When the sysctl can't be read, the event's own level is used.
        pressure.level = nil
        coordinator.handlePressureEvent(.normal)
        #expect(coordinator.current.pressure.level == .normal)
        #expect(coordinator.current.pressure.source == .systemEvent)
    }

    // Events-only fallback: what RamLume does if a future macOS removes the pressure sysctl.

    @Test func eventsOnlyStartsUnknownAndKeepsTheEventLevel() {
        pressure.level = nil
        coordinator.start()
        sample()
        #expect(coordinator.current.pressure == .unknown)
        #expect(coordinator.current.insights.contains { $0.id == "pressure-unavailable" })

        coordinator.handlePressureEvent(.warning)
        #expect(coordinator.current.pressure.level == .warning)
        #expect(coordinator.current.pressure.source == .systemEvent)
        sample()
        sample()
        // Samples without a kernel level don't erase what the event reported.
        #expect(coordinator.current.pressure.level == .warning)
        #expect(coordinator.current.health.state == .underPressure)
    }

    @Test func mergedEventsAreResolvedByTheKernelLevelOrLeftUnknown() {
        coordinator.start()
        sample()
        pressure.level = .critical
        coordinator.handlePressureEvent(PressureEventReading.ambiguous)
        #expect(coordinator.current.pressure.level == .critical)

        pressure.level = nil
        coordinator.handlePressureEvent(PressureEventReading.ambiguous)
        #expect(coordinator.current.pressure == .unknown)
        sample()
        #expect(coordinator.current.pressure == .unknown)   // nothing to restore from
    }

    @Test func eventsOnlyLevelSurvivesAPause() {
        pressure.level = nil
        coordinator.start()
        sample()
        coordinator.handlePressureEvent(.warning)
        coordinator.setPaused(true)
        clock.advance(by: 600)
        coordinator.handlePressureEvent(.normal)    // arrives while paused: remembered, not applied
        #expect(coordinator.current.pressure.level == .warning)
        coordinator.setPaused(false)
        sample()
        let state = coordinator.current.pressure
        #expect(state.level == .normal)
        #expect(state.source == .systemEvent)
        #expect(state.observedSinceIsLowerBound)       // it may have started during the pause
    }

    @Test func pauseStartsANewPressureObservation() throws {
        coordinator.start()
        pressure.level = .warning
        sample()
        sample()
        let firstSeen = try #require(coordinator.current.pressure.elevatedSince)

        coordinator.setPaused(true)
        clock.advance(by: 3_600)
        coordinator.setPaused(false)
        #expect(coordinator.current.pressure == .unknown)   // nothing was observed while paused

        sample()
        let state = coordinator.current.pressure
        #expect(state.level == .warning)
        #expect(state.elevatedSince != firstSeen)
        #expect(state.elevatedSinceIsLowerBound)
        // The paused hour isn't counted as observed pressure.
        #expect((state.elevatedDuration(at: clock.now) ?? .infinity) < 60)
    }

    @Test func refreshDoesNothingWhilePaused() async {
        coordinator.start()
        sample()
        coordinator.setPaused(true)
        coordinator.refreshProcesses()
        #expect(coordinator.isScanningProcesses == false)
        #expect(coordinator.current.processes == nil)

        coordinator.setPaused(false)
        coordinator.refreshProcesses()
        #expect(coordinator.isScanningProcesses)
        await coordinator.scanProcessesNow()
        #expect(coordinator.current.processes != nil)
    }

    @Test func rapidPressureChangesStayBounded() {
        coordinator.start()
        coordinator.setVisible(true, surface: .dashboard)
        sample()
        var updates = 0
        coordinator.onUpdate = { updates += 1 }
        for index in 0..<1_000 {
            let level: MemoryPressureLevel = index.isMultiple(of: 2) ? .warning : .normal
            pressure.level = level
            coordinator.handlePressureEvent(level)
        }
        // One update per event, no more; history keeps a bounded timeline of the changes.
        #expect(updates == 1_000)
        #expect(coordinator.current.pressure.level == .normal)
        #expect(history.events.count <= HistoryStore.eventCapacity)
        #expect(coordinator.pressure.level == .normal)   // the published copy is current too
    }

    @Test func repeatedDashboardOpenCloseKeepsCadenceAndPublishingConsistent() {
        coordinator.start()
        for _ in 0..<500 {
            coordinator.setVisible(true, surface: .dashboard)
            #expect(coordinator.scheduler.cadence.memoryInterval == 1)
            coordinator.setVisible(false, surface: .dashboard)
        }
        #expect(coordinator.scheduler.visibility == .hidden)
        #expect(coordinator.scheduler.cadence.memoryInterval == 5)
        let revision = history.revision
        sample()
        #expect(history.revision == revision)   // nothing is published while nothing is visible
    }

    @Test func swapGrowthIsLogged() {
        coordinator.start()
        sample()
        swap.usage = SwapUsage(total: 3 * Fixtures.gib, used: 2 * Fixtures.gib, available: Fixtures.gib, isEncrypted: true)
        sample()
        #expect(history.events.elements.contains { $0.kind == .swapExpanded })
    }

    @Test func processScanFeedsDiagnostics() async {
        coordinator.start()
        sample()
        await coordinator.scanProcessesNow()
        #expect(coordinator.current.processes?.largestAccessibleGroup?.displayName == "Brave Browser")
        #expect(coordinator.current.insights.contains { $0.id.hasPrefix("largest-consumer") })
    }

    /// The pause controls (panel menu and note, dashboard toolbar, Settings) read `isPausedByUser`.
    /// Sampling stops while paused, so nothing else would make them update.
    @Test func pausingNotifiesViewsThatShowThePauseState() {
        final class Changes: @unchecked Sendable { var count = 0 }
        let changes = Changes()
        coordinator.start()
        withObservationTracking { _ = coordinator.isPausedByUser } onChange: { changes.count += 1 }
        coordinator.setPaused(true)
        #expect(changes.count == 1)
        #expect(coordinator.isPausedByUser)
        withObservationTracking { _ = coordinator.isPausedByUser } onChange: { changes.count += 1 }
        coordinator.setPaused(false)
        #expect(changes.count == 2)
        #expect(!coordinator.isPausedByUser)
    }

    @Test func clearHistoryEmptiesStore() {
        coordinator.start()
        sample()
        sample()
        coordinator.clearHistory()
        #expect(history.history.points(in: .raw).isEmpty)
        #expect(history.events.isEmpty)
    }

    @Test func readerInitializationFailureIsReported() {
        let failing = MonitoringCoordinator(
            memoryReader: .failure(.physicalMemoryUnavailable),
            swapReader: swap,
            pressureReader: pressure,
            processReader: FakeProcessProvider(snapshot: Fixtures.braveSnapshot()),
            history: HistoryStore(retention: .oneHour, persistence: nil),
            clock: { Fixtures.reference },
            schedulesSampling: false
        )
        failing.start()
        failing.sampleNow()
        #expect(failing.current.snapshot == nil)
        #expect(failing.current.health.state == .insufficientData)
        #expect(failing.current.readError == .physicalMemoryUnavailable)
    }

    @Test func notificationsRespectPreferences() {
        var delivered: [AlertCandidate] = []
        coordinator.onAlerts = { delivered += $0 }
        coordinator.start()
        pressure.level = .critical
        sample()
        #expect(delivered.isEmpty)   // notifications are off by default

        coordinator.notificationPreferences = {
            NotificationPreferences(isEnabled: true, criticalPressure: true, sustainedPressure: true, rapidSwapGrowth: true, appMemoryGrowth: false)
        }
        sample()
        #expect(delivered.map(\.kind) == [.criticalPressure])
    }
}

/// Reads the real system once. These checks validate the production readers against invariants
/// that must hold on any Mac; they don't depend on specific values.
@Suite("Live system readers")
struct LiveSystemReaderTests {
    @Test func memoryReaderMatchesProcessInfo() throws {
        let reader = try SystemMemoryReader()
        let statistics = try reader.readStatistics()
        #expect(statistics.physicalMemory == ProcessInfo.processInfo.physicalMemory)
        #expect([4_096, 16_384].contains(statistics.pageSize))
        let breakdown = MemoryBreakdown(statistics: statistics)
        // Counters are read without a global lock, so allow a tiny inconsistency (0.5%).
        let tolerance = breakdown.total / 200
        #expect(breakdown.accounted <= breakdown.total + tolerance)
        #expect(breakdown.used > 0 && breakdown.used < breakdown.total)
        #expect(statistics.pages.free >= statistics.pages.speculative || statistics.pages.speculative < 1_000)
    }

    @Test func pageQueuesAreConsistent() throws {
        let statistics = try SystemMemoryReader().readStatistics()
        let p = statistics.pages
        let pageable = p.anonymous + p.fileBacked
        let queues = p.active + p.inactive + p.speculative
        // internal + external pages should match the pageable queues (within concurrent-read slack).
        let slack = max(queues / 100, 2_000)
        #expect(pageable + slack >= queues && queues + slack >= pageable)
    }

    @Test func swapAndPressureReadersDontFabricate() {
        if let swap = SystemSwapReader().readSwapUsage() {
            #expect(swap.used <= swap.total || swap.total == 0)
        }
        let indicators = KernelPressureReader().readIndicators()
        if let freePercentage = indicators.freePercentage {
            #expect((0...100).contains(freePercentage))
        }
    }

    @Test func processReaderMeasuresThisProcess() async throws {
        let snapshot = await ProcessReader().scanProcesses()
        #expect(snapshot.totalCount > 10)
        #expect(snapshot.accessibleCount + snapshot.restrictedCount == snapshot.totalCount)
        let me = getpid()
        let record = try #require(snapshot.groups.flatMap(\.processes).first { $0.pid == me })
        #expect(record.isAccessible)
        #expect((record.footprint ?? 0) > 0)
    }
}
