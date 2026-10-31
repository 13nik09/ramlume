import Foundation
import Observation

/// Everything the coordinator knows, always up to date.
struct MonitoringState: Sendable, Equatable {
    var snapshot: MemorySnapshot?
    var readError: MemoryReadError?
    var pressure: PressureState = .unknown
    var health: HealthAssessment = .initial
    var insights: [Insight] = []
    var recommendations: [Recommendation] = []
    var trends: MemoryTrends = .empty
    var processes: ProcessSnapshot?
    var growthFindings: [ProcessGrowthFinding] = []
}

/// The single owner of monitoring state.
///
/// One loop drives all polling: memory statistics at the scheduler's cadence, and process
/// scans when their (longer) interval has elapsed. No UI component polls the system itself.
///
/// `current` is always up to date and drives the status item, diagnostics, and notifications.
/// SwiftUI reads the published copies below, which are refreshed only while a RamLume surface
/// is actually on screen — so a closed panel or a hidden dashboard causes no view updates.
@MainActor
@Observable
final class MonitoringCoordinator {
    enum VisibleSurface: Hashable, Sendable {
        case menuPanel
        case dashboard
    }

    /// Always-current state (not observed by SwiftUI).
    @ObservationIgnored private(set) var current = MonitoringState()

    // MARK: Published for SwiftUI (refreshed only while presenting)

    private(set) var snapshot: MemorySnapshot?
    private(set) var readError: MemoryReadError?
    private(set) var pressure: PressureState = .unknown
    private(set) var health: HealthAssessment = .initial
    private(set) var insights: [Insight] = []
    private(set) var recommendations: [Recommendation] = []
    private(set) var trends: MemoryTrends = .empty
    private(set) var processes: ProcessSnapshot?
    private(set) var growthFindings: [ProcessGrowthFinding] = []

    // MARK: Published directly (change rarely)

    private(set) var isScanningProcesses = false
    private(set) var status: MonitoringStateMachine.Status = .stopped
    /// Whether the person paused monitoring. A copy of the state machine's flag, which observation
    /// can't see: the pause controls read this, and nothing else changes while sampling is paused.
    private(set) var isPausedByUser = false
    private(set) var scheduler = SamplingScheduler()

    /// Whether a RamLume surface is on screen.
    var isPresenting: Bool { scheduler.visibility != .hidden }

    let history: HistoryStore

    // MARK: Callbacks

    /// Called after every state change that affects the status item.
    @ObservationIgnored var onUpdate: (() -> Void)?
    /// Called with notifications the policy decided to deliver.
    @ObservationIgnored var onAlerts: (([AlertCandidate]) -> Void)?
    /// Supplies the user's current notification preferences.
    @ObservationIgnored var notificationPreferences: () -> NotificationPreferences = { .disabled }

    // MARK: Dependencies and internal state

    @ObservationIgnored private let memoryReader: (any MemoryStatisticsProviding)?
    @ObservationIgnored private let readerInitializationError: MemoryReadError?
    @ObservationIgnored private let swapReader: any SwapUsageProviding
    @ObservationIgnored private let pressureReader: any PressureLevelProviding
    @ObservationIgnored private let processReader: any ProcessProviding
    @ObservationIgnored private let clock: @Sendable () -> Date
    /// `false` in unit tests, which drive sampling explicitly with `sampleNow()`.
    @ObservationIgnored private let schedulesSampling: Bool

    @ObservationIgnored private var stateMachine = MonitoringStateMachine()
    @ObservationIgnored private var activityTracker = ActivityTracker()
    @ObservationIgnored private var growthTracker = ProcessGrowthTracker()
    @ObservationIgnored private var notificationPolicy = NotificationPolicy()
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var processTask: Task<Void, Never>?
    @ObservationIgnored private var lastProcessScan: Date?
    @ObservationIgnored private var lastSampleDate: Date?
    @ObservationIgnored private var visibleSurfaces: Set<VisibleSurface> = []
    @ObservationIgnored private var lastSwapTotal: UInt64?
    /// The latest dispatch pressure event, kept even while paused or asleep. Without the kernel
    /// level it's the best knowledge of the current level, because events report every change.
    @ObservationIgnored private var lastEventReading: PressureEventReading?

    /// Minimum spacing between on-demand samples (pressure events, panel opening).
    private static let minimumOnDemandSpacing: TimeInterval = 0.5

    init(
        memoryReader: Result<any MemoryStatisticsProviding, MemoryReadError>,
        swapReader: any SwapUsageProviding,
        pressureReader: any PressureLevelProviding,
        processReader: any ProcessProviding,
        history: HistoryStore,
        clock: @escaping @Sendable () -> Date = { Date() },
        schedulesSampling: Bool = true
    ) {
        switch memoryReader {
        case .success(let reader):
            self.memoryReader = reader
            readerInitializationError = nil
        case .failure(let error):
            self.memoryReader = nil
            readerInitializationError = error
        }
        self.swapReader = swapReader
        self.pressureReader = pressureReader
        self.processReader = processReader
        self.history = history
        self.clock = clock
        self.schedulesSampling = schedulesSampling
    }

    // MARK: - Lifecycle

    var isSampling: Bool { stateMachine.isSampling }

    func start() {
        let now = clock()
        if let readerInitializationError {
            current.readError = readerInitializationError
            current.health = HealthRules.assess(snapshot: nil, readError: readerInitializationError, pressure: current.pressure, trends: current.trends, now: now)
            publish()
        }
        history.record(MemoryEvent(date: now, kind: .monitoringStarted, title: "Monitoring started"))
        apply(stateMachine.handle(.start), at: now)
    }

    func setPaused(_ paused: Bool) {
        let now = clock()
        let transition = stateMachine.handle(paused ? .pauseRequested : .resumeRequested)
        guard transition != .none else {
            updateStatus()
            onUpdate?()
            return
        }
        history.record(MemoryEvent(
            date: now,
            kind: paused ? .monitoringPaused : .monitoringResumed,
            title: paused ? "Monitoring paused" : "Monitoring resumed"
        ))
        apply(transition, at: now)
    }

    func systemWillSleep() {
        let now = clock()
        history.record(MemoryEvent(date: now, kind: .systemSleep, title: "Mac went to sleep"))
        apply(stateMachine.handle(.systemWillSleep), at: now)
        history.save(now: now)
    }

    func systemDidWake() {
        let now = clock()
        history.record(MemoryEvent(date: now, kind: .systemWake, title: "Mac woke from sleep"))
        apply(stateMachine.handle(.systemDidWake), at: now)
    }

    /// Stops sampling and writes history synchronously. Called when the app quits.
    func prepareForTermination() {
        loopTask?.cancel()
        loopTask = nil
        processTask?.cancel()
        history.saveSynchronously(now: clock())
    }

    private func updateStatus() {
        status = stateMachine.status
        if isPausedByUser != stateMachine.isPausedByUser {
            isPausedByUser = stateMachine.isPausedByUser
        }
    }

    private func apply(_ transition: MonitoringStateMachine.Transition, at date: Date) {
        updateStatus()
        switch transition {
        case .startSampling:
            history.endGap(at: date)
            activityTracker.reset()
            // Nothing was observed during the gap: the next reading starts a new observation,
            // so durations never include time asleep or paused.
            current.pressure = .unknown
            restartLoop(sampleImmediately: true)
        case .stopSampling(let reason):
            loopTask?.cancel()
            loopTask = nil
            activityTracker.reset()
            history.beginGap(at: date, reason: reason)
        case .none:
            break
        }
        onUpdate?()
    }

    // MARK: - Scheduling inputs

    func setVisible(_ visible: Bool, surface: VisibleSurface) {
        if visible {
            visibleSurfaces.insert(surface)
        } else {
            visibleSurfaces.remove(surface)
        }
        let visibility: InterfaceVisibility = visibleSurfaces.contains(.dashboard)
            ? .dashboard
            : (visibleSurfaces.contains(.menuPanel) ? .menuPanel : .hidden)
        guard visibility != scheduler.visibility else { return }
        let becameVisible = scheduler.visibility == .hidden && visibility != .hidden
        scheduler.visibility = visibility
        if becameVisible {
            publish()
        }
        if stateMachine.isSampling {
            restartLoop(sampleImmediately: becameVisible && !sampledRecently())
        }
    }

    func setProfile(_ profile: MonitoringProfile) {
        updateScheduler { $0.profile = profile }
    }

    func setLowPowerMode(_ enabled: Bool) {
        updateScheduler { $0.isLowPowerModeEnabled = enabled }
    }

    func setUsesEnergySaverInLowPowerMode(_ enabled: Bool) {
        updateScheduler { $0.usesEnergySaverInLowPowerMode = enabled }
    }

    func setScreensAsleep(_ asleep: Bool) {
        updateScheduler { $0.screensAsleep = asleep }
    }

    private func updateScheduler(_ change: (inout SamplingScheduler) -> Void) {
        var updated = scheduler
        change(&updated)
        guard updated != scheduler else { return }
        let cadenceChanged = updated.cadence != scheduler.cadence
        scheduler = updated
        if cadenceChanged, stateMachine.isSampling {
            restartLoop(sampleImmediately: false)
        }
    }

    // MARK: - Sampling loop

    private func restartLoop(sampleImmediately: Bool) {
        loopTask?.cancel()
        guard stateMachine.isSampling, schedulesSampling else {
            loopTask = nil
            return
        }
        loopTask = Task { [weak self] in
            var sampleNow = sampleImmediately
            while !Task.isCancelled {
                if !sampleNow {
                    guard let interval = self?.scheduler.cadence.memoryInterval else { return }
                    do {
                        // A 10% tolerance lets macOS coalesce RamLume's wake-ups with other timers.
                        try await Task.sleep(for: .seconds(interval), tolerance: .seconds(interval * 0.1))
                    } catch {
                        return
                    }
                }
                sampleNow = false
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let now = clock()
        sampleMemory()
        if shouldScanProcesses(at: now) {
            scanProcesses()
        }
        history.saveIfDue(now: now)
    }

    private func sampledRecently() -> Bool {
        guard let lastSampleDate else { return false }
        let elapsed = clock().timeIntervalSince(lastSampleDate)
        // A negative value means the clock was set back; don't treat that as "recent".
        return elapsed >= 0 && elapsed < Self.minimumOnDemandSpacing
    }

    /// Takes a sample immediately (e.g. when a pressure event arrives), if monitoring is running.
    func sampleNow() {
        guard stateMachine.isSampling, !sampledRecently() else { return }
        sampleMemory()
    }

    private func sampleMemory() {
        guard let memoryReader else { return }
        let statistics: MemoryStatistics
        do {
            statistics = try memoryReader.readStatistics()
        } catch {
            handleReadFailure(error)
            return
        }
        let now = statistics.timestamp
        if current.readError != nil {
            current.readError = nil
            history.endGap(at: now)
            history.record(MemoryEvent(date: now, kind: .readRecovered, title: "Memory statistics available again"))
        }

        let indicators = pressureReader.readIndicators()
        if let level = indicators.level {
            applyPressure(level, source: .kernelLevel, at: now)
        } else if current.pressure.level == nil, case .level(let level)? = lastEventReading {
            // Events-only fallback after launch, sleep, or a pause: the latest event still
            // describes the current level. It's recorded as a new (lower-bound) observation.
            applyPressure(level, source: .systemEvent, at: now)
        }
        let swap = swapReader.readSwapUsage()
        let activity = activityTracker.record(statistics)
        let snapshot = MemorySnapshot(
            statistics: statistics,
            breakdown: MemoryBreakdown(statistics: statistics),
            swap: swap,
            kernelFreePercentage: indicators.freePercentage,
            activity: activity
        )
        current.snapshot = snapshot
        lastSampleDate = clock()
        noteSwapAllocation(swap, at: now)
        history.append(HistoryPoint(snapshot: snapshot, pressure: current.pressure.level))
        evaluate(at: now)
        onUpdate?()
    }

    private func handleReadFailure(_ error: MemoryReadError) {
        let now = clock()
        if current.readError == nil {
            history.record(MemoryEvent(date: now, kind: .readFailure, title: "Memory statistics unavailable", detail: error.description))
            history.beginGap(at: now, reason: .readFailure)
        }
        current.readError = error
        // Don't keep showing numbers that are no longer being refreshed.
        current.snapshot = nil
        activityTracker.reset()
        evaluate(at: now)
        onUpdate?()
    }

    private func noteSwapAllocation(_ swap: SwapUsage?, at date: Date) {
        guard let swap else { return }
        defer { lastSwapTotal = swap.total }
        guard let previous = lastSwapTotal, swap.total > previous else { return }
        history.record(MemoryEvent(
            date: date,
            kind: .swapExpanded,
            title: "Swap space grew to \(MemoryFormatter.string(fromBytes: swap.total, style: .compact))",
            detail: "macOS allocated more swap file space (\(MemoryFormatter.signedChange(bytes: MemoryUnits.signedDifference(swap.total, previous))))."
        ))
    }

    // MARK: - Pressure

    /// Handles a dispatch memory-pressure event.
    ///
    /// Dispatch merges events that arrive before the handler runs (for example warning followed
    /// by normal), so the event only prompts an immediate check: the kernel's current level wins
    /// whenever it's readable.
    func handlePressureEvent(_ eventLevel: MemoryPressureLevel) {
        handlePressureEvent(.level(eventLevel))
    }

    func handlePressureEvent(_ reading: PressureEventReading) {
        lastEventReading = reading
        guard stateMachine.isSampling else { return }
        let now = clock()
        if let kernelLevel = pressureReader.readIndicators().level {
            applyPressure(kernelLevel, source: .kernelLevel, at: now)
        } else {
            switch reading {
            case .level(let level):
                applyPressure(level, source: .systemEvent, at: now)
            case .ambiguous:
                // Without the kernel level there's no telling which merged transition came last.
                current.pressure = .unknown
            }
        }
        if sampledRecently() {
            // A fresh sample exists; re-run the diagnostics so health and alerts reflect the new level now.
            evaluate(at: now)
        } else {
            sampleMemory()
        }
        onUpdate?()
    }

    private func applyPressure(_ level: MemoryPressureLevel, source: PressureSource, at date: Date) {
        let result = current.pressure.update(level: level, source: source, at: date)
        guard result.changed else { return }
        if let previous = result.previous {
            history.record(MemoryEvent(
                date: date,
                kind: .pressureChanged,
                title: "Memory pressure: \(level.displayName)",
                detail: "Changed from \(previous.displayName), as reported by macOS.",
                pressure: level
            ))
        } else if level.isElevated {
            history.record(MemoryEvent(
                date: date,
                kind: .pressureChanged,
                title: "Memory pressure: \(level.displayName)",
                detail: "Already elevated when RamLume began observing.",
                pressure: level
            ))
        }
    }

    // MARK: - Processes

    private func shouldScanProcesses(at date: Date) -> Bool {
        guard processTask == nil else { return false }
        guard let lastProcessScan else { return true }
        return lastProcessScan.hasElapsed(scheduler.cadence.processInterval, by: date)
    }

    /// Starts a process scan now unless one is already running. Does nothing while paused:
    /// a paused RamLume doesn't sample anything.
    func refreshProcesses() {
        guard processTask == nil, stateMachine.isSampling else { return }
        scanProcesses()
    }

    /// Scans processes and waits for the result.
    func scanProcessesNow() async {
        if processTask == nil {
            scanProcesses()
        }
        await processTask?.value
    }

    private func scanProcesses() {
        lastProcessScan = clock()
        isScanningProcesses = true
        let reader = processReader
        processTask = Task { [weak self] in
            let result = await reader.scanProcesses()
            guard let self else { return }
            self.processTask = nil
            self.isScanningProcesses = false
            self.current.processes = result
            self.growthTracker.record(result)
            self.current.growthFindings = self.growthTracker.findings(now: result.timestamp)
            // A scan that finishes after a pause began is kept, but diagnostics wait for sampling.
            if self.stateMachine.isSampling {
                self.evaluate(at: self.clock())
            } else {
                self.publish()
            }
            self.onUpdate?()
        }
    }

    // MARK: - Diagnostics

    private func evaluate(at now: Date) {
        let windowStart = now.addingTimeInterval(-MemoryTrendAnalyzer.changeWindow)
        let samples = history.history.rawPoints(since: windowStart)
        let gaps = history.history.gaps(between: windowStart, and: now, now: now)
        let trends = MemoryTrendAnalyzer.analyze(samples: samples, gaps: gaps, now: now)
        current.trends = trends

        let previousHealth = current.health
        let health = HealthRules.assess(snapshot: current.snapshot, readError: current.readError, pressure: current.pressure, trends: trends, now: now)
        if health.state != previousHealth.state, previousHealth.state != .insufficientData || health.state.severity > 0 {
            history.record(MemoryEvent(
                date: now,
                kind: .healthChanged,
                title: "Health: \(health.state.title)",
                detail: health.headline,
                health: health.state
            ))
        }
        current.health = health

        let input = DiagnosticsInput(
            now: now,
            snapshot: current.snapshot,
            pressure: current.pressure,
            health: health,
            trends: trends,
            processes: current.processes,
            growthFindings: current.growthFindings
        )
        current.insights = DiagnosticsEngine.insights(for: input)
        current.recommendations = RecommendationEngine.recommendations(for: input)

        let top = current.processes?.largestAccessibleGroup.map { (name: $0.displayName, bytes: $0.totalFootprint) }
        let alerts = notificationPolicy.evaluate(
            NotificationInput(now: now, pressure: current.pressure, trends: trends, topConsumer: top, growthFindings: current.growthFindings),
            preferences: notificationPreferences()
        )
        if !alerts.isEmpty {
            onAlerts?(alerts)
        }
        publish()
    }

    /// Copies `current` into the observed properties while a surface is on screen. Each property
    /// is assigned only when it changed, so SwiftUI invalidates only the views that depend on it.
    private func publish() {
        guard isPresenting else { return }
        if snapshot != current.snapshot { snapshot = current.snapshot }
        if readError != current.readError { readError = current.readError }
        if pressure != current.pressure { pressure = current.pressure }
        if health != current.health { health = current.health }
        if insights != current.insights { insights = current.insights }
        if recommendations != current.recommendations { recommendations = current.recommendations }
        if trends != current.trends { trends = current.trends }
        // Process snapshots are immutable per scan; comparing timestamps avoids a deep comparison.
        if processes?.timestamp != current.processes?.timestamp { processes = current.processes }
        if growthFindings != current.growthFindings { growthFindings = current.growthFindings }
        history.publishChanges()
    }

    // MARK: - History maintenance

    func setRetention(_ retention: HistoryRetention) {
        history.setRetention(retention, now: clock())
    }

    func clearHistory() {
        history.clearAll()
        growthTracker.reset()
        current.growthFindings = []
        evaluate(at: clock())
    }
}
