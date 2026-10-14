#if DEBUG
import AppKit
import os
import SwiftUI

/// Counters for diagnosing hover feedback loops (Debug builds only).
enum HoverDiagnostics {
    struct Counts: Sendable, Equatable {
        var handlerCalls = 0
        var stateWrites = 0
        var crosshairBodies = 0
        var lastTarget = "none"
        /// The most recent hover events and state writes, oldest first.
        var trail: [String] = []

        mutating func note(_ entry: String) {
            trail.append(entry)
            if trail.count > 12 { trail.removeFirst(trail.count - 12) }
        }
    }

    private static let lock = OSAllocatedUnfairLock(initialState: Counts())

    static func record(_ change: @Sendable (inout Counts) -> Void) {
        lock.withLock { change(&$0) }
    }

    static var counts: Counts { lock.withLock { $0 } }
    static func reset() { lock.withLock { $0 = Counts() } }
}

/// Exercises the history charts' hover handling in an off-screen window with synthetic,
/// in-process mouse events, and reports handler calls, state writes, overlay body evaluations,
/// CPU time, and main-thread stalls per scenario. Launch with `--hover-lab [scenario prefix]`.
/// It never moves the real pointer.
///
/// SwiftUI accepts synthetic hover only on this path: a `mouseEntered` event tagged with the
/// hosting view's own tracking area, then `mouseMoved` sent to the hosting view. Events sent
/// through the window or the application, or untagged, are ignored.
@MainActor
final class HoverLab {
    enum ChartKind: String, CaseIterable {
        case usage, compactUsage, compression, swap, swapActivity, pressure
    }

    @Observable
    @MainActor
    final class Model {
        var series: HistorySeries
        var chart: ChartKind = .usage
        init(series: HistorySeries) { self.series = series }
    }

    private struct Root: View {
        var model: Model
        var body: some View {
            Group {
                switch model.chart {
                case .usage: MemoryUsageChart(series: model.series, style: .full)
                case .compactUsage: MemoryUsageChart(series: model.series, style: .compact)
                case .compression: CompressionChart(series: model.series)
                case .swap: SwapChart(series: model.series)
                case .swapActivity: SwapActivityChart(series: model.series)
                case .pressure: PressureTimeline(series: model.series)
                }
            }
            .frame(width: HoverLab.chartSize.width, height: HoverLab.chartSize.height)
            .padding(HoverLab.padding)
        }
    }

    /// Reports a simulated pointer position to anything that asks the window where the mouse is.
    final class LabWindow: NSWindow {
        var simulatedMouse: NSPoint?
        override var mouseLocationOutsideOfEventStream: NSPoint {
            simulatedMouse ?? super.mouseLocationOutsideOfEventStream
        }
    }

    static let chartSize = CGSize(width: 860, height: 320)
    static let padding: CGFloat = 20

    private let window: LabWindow
    private let host: NSHostingView<Root>
    private let model: Model
    private let watchdog = Watchdog()
    private let filter: String?
    private var results: [String] = []

    init(filter: String?) {
        setvbuf(stdout, nil, _IONBF, 0)
        self.filter = filter
        model = Model(series: Self.restartGapsSeries())
        host = NSHostingView(rootView: Root(model: model))
        let size = CGSize(width: Self.chartSize.width + 2 * Self.padding, height: Self.chartSize.height + 2 * Self.padding)
        // On screen so AppKit renders it, but fully transparent and transparent to the real mouse:
        // the person at the Mac sees nothing, can't click it, and nothing is activated. Events
        // reach the hosting view only through the synthetic calls below.
        window = LabWindow(contentRect: NSRect(origin: CGPoint(x: 40, y: 40), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        // RAMLUME_LAB_ACCEPTS_MOUSE=1 tests whether ignoring mouse events blocks SwiftUI hover.
        window.ignoresMouseEvents = ProcessInfo.processInfo.environment["RAMLUME_LAB_ACCEPTS_MOUSE"] != "1"
        window.acceptsMouseMovedEvents = true
        window.contentView = host
        window.orderFrontRegardless()
        print("HOVERLAB filter=\(filter ?? "all")")
    }

    // MARK: Series

    /// The last 15 minutes with a few short gaps, like the history after several restarts.
    static func restartGapsSeries(now: Date = Date()) -> HistorySeries {
        var history = MemoryHistory(retention: .oneDay)
        let gaps: [ClosedRange<TimeInterval>] = [-700 ... -640, -420 ... -400, -260 ... -200, -90 ... -80]
        var t: TimeInterval = -900
        while t < 0 {
            if let gap = gaps.first(where: { $0.contains(t) }) {
                history.beginGap(at: now.addingTimeInterval(gap.lowerBound), reason: .appNotRunning)
                history.endGap(at: now.addingTimeInterval(gap.upperBound))
                t = gap.upperBound + 1
                continue
            }
            history.append(point(at: now.addingTimeInterval(t), seed: t))
            t += 1
        }
        return history.series(for: .fifteenMinutes, now: now, maxPoints: 120)
    }

    private static var cachedSleepGapSeries: HistorySeries?

    /// A day of history with a long sleep gap (the demo data).
    static func sleepGapSeries() -> HistorySeries {
        if let cachedSleepGapSeries { return cachedSleepGapSeries }
        let now = Date()
        let series = DemoData.makeHistory(anchor: now, retention: .oneDay).history.series(for: .oneDay, now: now, maxPoints: 120)
        cachedSleepGapSeries = series
        return series
    }

    /// 15 minutes of samples every second, with no gaps.
    static func denseSeries(now: Date = Date()) -> HistorySeries {
        var history = MemoryHistory(retention: .oneDay)
        for t in stride(from: -899.0, through: 0, by: 1) { history.append(point(at: now.addingTimeInterval(t), seed: t)) }
        return history.series(for: .fifteenMinutes, now: now, maxPoints: 120)
    }

    static func singlePointSeries(now: Date = Date()) -> HistorySeries {
        var history = MemoryHistory(retention: .oneDay)
        history.append(point(at: now.addingTimeInterval(-30), seed: 0))
        return history.series(for: .fifteenMinutes, now: now, maxPoints: 120)
    }

    static func emptySeries(now: Date = Date()) -> HistorySeries {
        MemoryHistory(retention: .oneDay).series(for: .fifteenMinutes, now: now, maxPoints: 120)
    }

    private static func point(at date: Date, seed: TimeInterval) -> HistoryPoint {
        let statistics = DemoData.statistics(at: seed, timestamp: date, uptime: 10_000 + seed)
        let snapshot = MemorySnapshot(
            statistics: statistics,
            breakdown: MemoryBreakdown(statistics: statistics),
            swap: DemoData.swap(at: seed),
            kernelFreePercentage: 50,
            activity: MemoryActivity(interval: 1, swapInBytes: 0, swapOutBytes: UInt64(4_096 * (abs(Int(seed)) % 7 + 1)),
                                     pageInBytes: 0, pageOutBytes: 0, compressedPages: 10, decompressedPages: 9, faults: 100)
        )
        return HistoryPoint(snapshot: snapshot, pressure: abs(Int(seed)) % 97 == 0 ? .warning : .normal)
    }

    // MARK: Events

    /// A point in the chart's coordinate space (top-left origin), as a fraction of its size.
    private func location(x: CGFloat, y: CGFloat) -> NSPoint {
        let px = Self.padding + x * Self.chartSize.width
        let py = Self.padding + y * Self.chartSize.height
        return NSPoint(x: px, y: host.bounds.height - py)
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
        switch type {
        case .mouseEntered, .mouseExited:
            // Tag the event with the hosting view's own tracking area, as AppKit does.
            NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                   trackingNumber: host.trackingAreas.first.map { Int(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0,
                                   userData: nil)
        default:
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)
        }
    }

    /// How synthetic events are delivered (`RAMLUME_LAB_ROUTE`: view, window, or app). Only
    /// "view" reaches SwiftUI's hover handling in-process; the others are kept for comparison.
    private let route = ProcessInfo.processInfo.environment["RAMLUME_LAB_ROUTE"] ?? "view"
    private var eventsDelivered = 0

    private func deliver(_ event: NSEvent) {
        eventsDelivered += 1
        switch route {
        case "view":
            switch event.type {
            case .mouseEntered: host.mouseEntered(with: event)
            case .mouseExited: host.mouseExited(with: event)
            default: host.mouseMoved(with: event)
            }
        case "app": NSApp.sendEvent(event)
        default: window.sendEvent(event)
        }
    }

    private func move(x: CGFloat, y: CGFloat = 0.45) {
        let point = location(x: x, y: y)
        window.simulatedMouse = point
        guard let event = event(.mouseMoved, at: point) else { return }
        deliver(event)
    }

    private func enter(x: CGFloat, y: CGFloat = 0.45) {
        let point = location(x: x, y: y)
        window.simulatedMouse = point
        guard let event = event(.mouseEntered, at: point) else { return }
        deliver(event)
    }

    private func exit(x: CGFloat, y: CGFloat = 0.45) {
        let point = location(x: x, y: y)
        window.simulatedMouse = point
        guard let event = event(.mouseExited, at: point) else { return }
        deliver(event)
    }

    /// Lets the run loop process updates (and any loop to show itself).
    private func settle(_ seconds: Double = 0.4) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// Finds an x position whose hover target is a gap, if the chart shows one.
    private func findGap() async -> CGFloat? {
        enter(x: 0.06)
        var x: CGFloat = 0.06
        while x < 0.99 {
            move(x: x)
            await settle(0.03)
            if HoverDiagnostics.counts.lastTarget == "gap" { return x }
            x += 0.01
        }
        return nil
    }

    /// Draws the chart into a PNG (the window is transparent on screen, so a screenshot wouldn't
    /// show it) and returns a note for the results.
    private func saveSnapshot(named name: String, in directory: String) -> String {
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return "no bitmap" }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let url = URL(fileURLWithPath: directory).appending(path: "\(name).png")
        guard let data = bitmap.representation(using: .png, properties: [:]), (try? data.write(to: url)) != nil else {
            return "couldn't write \(url.path)"
        }
        return "snapshot \(url.lastPathComponent), target \(HoverDiagnostics.counts.lastTarget)"
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + allSubviews(of: $0) }
    }

    // MARK: Scenarios

    func run() async {
        watchdog.start()
        await settle(0.5)
        let initial = HoverDiagnostics.counts
        print("HOVERLAB initial render: overlay bodies \(initial.crosshairBodies), handler \(initial.handlerCalls); window visible \(window.isVisible), occlusion visible \(window.occlusionState.contains(.visible)), ignores mouse \(window.ignoresMouseEvents)")
        for area in host.trackingAreas {
            print("HOVERLAB tracking area owner=\(area.owner.map { String(describing: type(of: $0)) } ?? "nil") options=\(area.options.rawValue) rect=\(area.rect)")
        }
        for view in allSubviews(of: host) where !view.trackingAreas.isEmpty {
            for area in view.trackingAreas {
                print("HOVERLAB subview \(type(of: view)) tracking owner=\(area.owner.map { String(describing: type(of: $0)) } ?? "nil") options=\(area.options.rawValue)")
            }
        }
        // `regression`: a short set covering every chart, used by HoverLoopRegressionTests.
        for chart in ChartKind.allCases {
            await scenario("regression.\(chart.rawValue).resting", chart: chart, series: Self.denseSeries()) {
                for x in stride(from: 0.30, through: 0.80, by: 0.05) {
                    self.enter(x: x)
                    await self.settle(0.08)
                }
                return nil
            }
            await scenario("regression.\(chart.rawValue).gap", chart: chart, series: Self.sleepGapSeries()) {
                for x in stride(from: 0.50, through: 0.85, by: 0.05) {
                    self.enter(x: x)
                    await self.settle(0.08)
                }
                return nil
            }
            await scenario("regression.\(chart.rawValue).sweep-and-leave", chart: chart, series: Self.restartGapsSeries()) {
                self.enter(x: 0)
                for step in 0...200 { self.move(x: CGFloat(step) / 200) }
                await self.settle(0.2)
                self.exit(x: 1.2, y: 1.2)
                await self.settle(0.2)
                return nil
            }
            await scenario("regression.\(chart.rawValue).data-arriving", chart: chart, series: Self.denseSeries()) {
                self.enter(x: 0.58)
                for _ in 0..<20 {
                    self.model.series = Self.denseSeries()
                    await self.settle(0.03)
                }
                await self.settle(0.2)
                return nil
            }
        }
        // No gaps involved: the pointer rests just right of the plot's middle.
        for chart in [ChartKind.usage, .pressure, .swapActivity] {
            await scenario("midright.\(chart.rawValue)", chart: chart, series: Self.denseSeries()) {
                self.enter(x: 0.56)
                await self.settle(0.5)
                return "trail: \(HoverDiagnostics.counts.trail.suffix(4).joined(separator: " | "))"
            }
        }
        // `RAMLUME_LAB_SNAPSHOTS=<directory>`: PNGs of every chart with the pointer resting on the
        // left half, the right half (tooltip left of the crosshair), and a gap, in both appearances,
        // to check the crosshair and tooltips by eye; the lab window itself is invisible.
        if let directory = ProcessInfo.processInfo.environment["RAMLUME_LAB_SNAPSHOTS"] {
            for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (NSAppearance.Name.darkAqua, "dark")] {
                window.appearance = NSAppearance(named: appearance)
                for chart in ChartKind.allCases {
                    for (place, x) in [("left", 0.3), ("right", 0.7)] as [(String, CGFloat)] {
                        await scenario("snapshot.\(name).\(chart.rawValue).\(place)", chart: chart, series: Self.denseSeries()) {
                            self.enter(x: x)
                            await self.settle(0.5)
                            return self.saveSnapshot(named: "\(chart.rawValue)-\(place)-\(name)", in: directory)
                        }
                    }
                    await scenario("snapshot.\(name).\(chart.rawValue).gap", chart: chart, series: Self.sleepGapSeries()) {
                        guard await self.findGap() != nil else { return "no gap target on this chart" }
                        await self.settle(0.5)
                        return self.saveSnapshot(named: "\(chart.rawValue)-gap-\(name)", in: directory)
                    }
                }
            }
            window.appearance = nil
        }
        for chart in ChartKind.allCases {
            await scenario("\(chart.rawValue).stationary-data", chart: chart, series: Self.restartGapsSeries()) {
                self.enter(x: 0.97)
                for _ in 0..<200 { self.move(x: 0.97) }
                await self.settle(1)
                return nil
            }
            await scenario("\(chart.rawValue).stationary-gap", chart: chart, series: Self.sleepGapSeries()) {
                guard let x = await self.findGap() else { return "no gap target on this chart" }
                for _ in 0..<200 { self.move(x: x) }
                await self.settle(1)
                return nil
            }
            await scenario("\(chart.rawValue).restart-gaps-sweep", chart: chart, series: Self.restartGapsSeries()) {
                self.enter(x: 0)
                for step in 0...300 { self.move(x: CGFloat(step) / 300) }
                await self.settle(1)
                return nil
            }
            await scenario("\(chart.rawValue).enter-leave", chart: chart, series: Self.restartGapsSeries()) {
                for index in 0..<100 {
                    if index.isMultiple(of: 2) { self.enter(x: 0.5); self.move(x: 0.5) } else { self.exit(x: 1.2, y: 1.2) }
                }
                await self.settle(1)
                return nil
            }
            await scenario("\(chart.rawValue).data-arriving", chart: chart, series: Self.restartGapsSeries()) {
                self.enter(x: 0.95)
                self.move(x: 0.95)
                for _ in 0..<60 {
                    self.model.series = Self.restartGapsSeries()
                    self.move(x: 0.95)
                    await self.settle(0.03)
                }
                await self.settle(1)
                return nil
            }
            await scenario("\(chart.rawValue).range-changes", chart: chart, series: Self.restartGapsSeries()) {
                self.enter(x: 0.6)
                self.move(x: 0.6)
                for index in 0..<100 {
                    self.model.series = index.isMultiple(of: 2) ? Self.sleepGapSeries() : Self.restartGapsSeries()
                    await self.settle(0.02)
                }
                await self.settle(1)
                return nil
            }
            await scenario("\(chart.rawValue).empty-and-single", chart: chart, series: Self.emptySeries()) {
                self.enter(x: 0)
                for x in stride(from: 0.0, through: 1.0, by: 0.05) { self.move(x: x) }
                self.model.series = Self.singlePointSeries()
                await self.settle(0.2)
                for x in stride(from: 0.0, through: 1.0, by: 0.05) { self.move(x: x) }
                for _ in 0..<100 { self.move(x: 0.99) }
                await self.settle(1)
                return nil
            }
        }
        print("HOVERLAB DONE")
        for line in results { print(line) }
        fflush(stdout)
        Darwin.exit(0)
    }

    private func scenario(_ name: String, chart: ChartKind, series: HistorySeries, body: @escaping () async -> String?) async {
        if let filter, !name.hasPrefix(filter) { return }
        print("HOVERLAB start \(name)")
        model.chart = chart
        model.series = series
        exit(x: 1.2, y: 1.2)
        await settle(0.3)
        HoverDiagnostics.reset()
        eventsDelivered = 0
        watchdog.label = name
        let cpuStart = Self.cpuSeconds()
        let wallStart = ProcessInfo.processInfo.systemUptime
        let note = await body()
        let counts = HoverDiagnostics.counts
        let cpu = Self.cpuSeconds() - cpuStart
        let wall = ProcessInfo.processInfo.systemUptime - wallStart
        let line = String(format: "%@ events %5d  handler %6d  writes %6d  overlay bodies %6d  cpu %5.2f s / %4.1f s  max stall %4.0f ms%@",
                          name.padding(toLength: 34, withPad: " ", startingAt: 0) as NSString, eventsDelivered,
                          counts.handlerCalls, counts.stateWrites, counts.crosshairBodies, cpu, wall,
                          watchdog.takeMaxStall().gap * 1_000, note.map { "  (\($0))" as NSString } ?? "")
        results.append(line)
        print(line)
        fflush(stdout)
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    /// Detects a main thread that stops responding: a timer on the main run loop beats every
    /// 50 ms; a background thread reports and exits if the beat stops for 3 s.
    final class Watchdog: @unchecked Sendable {
        /// The longest gap between beats, how much of it the main thread spent running, and the
        /// step that was running. A long gap with little CPU time is macOS delaying the timer of a
        /// background app (timer coalescing, App Nap), not work blocking the main thread.
        struct Stall {
            var gap: TimeInterval = 0
            var busy: TimeInterval = 0
            var label = ""

            var summary: String {
                String(format: "%4.0f ms (main thread busy %4.0f ms, in %@)", gap * 1_000, busy * 1_000, label as NSString)
            }
        }

        private struct State { var beat: TimeInterval; var beatCPU: TimeInterval; var label: String; var longest: Stall }
        private let state = OSAllocatedUnfairLock(initialState: State(beat: ProcessInfo.processInfo.systemUptime, beatCPU: 0, label: "start", longest: Stall()))
        private var timer: Timer?

        var label: String {
            get { state.withLock { $0.label } }
            set { state.withLock { $0.label = newValue } }
        }

        /// The longest stall since the last call.
        func takeMaxStall() -> Stall {
            state.withLock { value in
                let stall = value.longest
                value.longest = Stall()
                return stall
            }
        }

        @MainActor
        func start() {
            let cpu = Self.currentThreadCPUTime()
            state.withLock { value in
                value.beat = ProcessInfo.processInfo.systemUptime
                value.beatCPU = cpu
            }
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let cpu = Self.currentThreadCPUTime()
                self.state.withLock { value in
                    let gap = now - value.beat
                    if gap > value.longest.gap {
                        value.longest = Stall(gap: gap, busy: cpu - value.beatCPU, label: value.label)
                    }
                    value.beat = now
                    value.beatCPU = cpu
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            Thread.detachNewThread { [self] in
                var lastCheck = ProcessInfo.processInfo.systemUptime
                while true {
                    Thread.sleep(forTimeInterval: 0.25)
                    let now = ProcessInfo.processInfo.systemUptime
                    defer { lastCheck = now }
                    if now - lastCheck > 1 {
                        // This thread overslept too, so the whole process was suspended (by `leaks`
                        // or a debugger, say). That isn't the main thread failing to respond.
                        state.withLock { $0.beat = now }
                        continue
                    }
                    let (beat, label) = state.withLock { ($0.beat, $0.label) }
                    if now - beat > 3 {
                        let counts = HoverDiagnostics.counts
                        print("HOVERLAB STALL in \(label): main thread unresponsive for over 3 s; handler calls \(counts.handlerCalls), state writes \(counts.stateWrites), overlay bodies \(counts.crosshairBodies)")
                        for entry in counts.trail { print("HOVERLAB   trail: \(entry)") }
                        fflush(stdout)
                        Darwin.exit(3)
                    }
                }
            }
        }

        /// CPU time (user and system) of the calling thread.
        static func currentThreadCPUTime() -> TimeInterval {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let thread = mach_thread_self()
            defer { mach_port_deallocate(mach_task_self_, thread) }
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return 0 }
            return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
                + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
        }
    }
}
#endif
