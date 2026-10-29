#if DEBUG
import AppKit
import Darwin
import os
import SwiftUI

/// Debug-only stress harnesses for the real dashboard. They open windows without activating
/// RamLume, drive hover only through the hover lab's in-process path (never the real pointer),
/// and report per step: CPU time, memory footprint, chart overlay re-renders (a proxy for chart
/// redraws), hover handler calls, and the longest main-thread stall. A watchdog exits with
/// status 3 if the main thread stops responding for 3 s.
///
/// - `--ui-stress <cycles>`: open the dashboard, visit every section and range, sweep hover,
///   switch appearance, show the menu bar panel's content, pause/resume, sleep/wake, flap memory
///   pressure, close, then open and close it rapidly; repeat. Also reports whether each closed
///   dashboard's and panel's SwiftUI hierarchy was released.
/// - `--soak <minutes>`: keep History visible with live sampling and periodic hover.
/// - `--events-probe`: show the Events section with timelines of 5 to 300 events.
@MainActor
final class UIStress {
    private let model: AppModel
    private let dashboard: DashboardWindowController
    private let watchdog = HoverLab.Watchdog()

    init(model: AppModel, dashboard: DashboardWindowController) {
        setvbuf(stdout, nil, _IONBF, 0)
        self.model = model
        self.dashboard = dashboard
    }

    // MARK: Lifecycle cycles

    func runCycles(_ cycles: Int) async {
        watchdog.start()
        print("UISTRESS cycles=\(cycles)")
        let launchFootprint = Self.footprint()
        var worstStall = HoverLab.Watchdog.Stall()
        // Every closed dashboard's and panel's hosting view, weakly: one that stays alive is a leak.
        var closedDashboards: [WeakView] = []
        var closedPanels: [WeakView] = []
        let checkpoint = ProcessInfo.processInfo.environment["RAMLUME_STRESS_CHECKPOINT"].flatMap { Int($0) }
        for cycle in 1...max(cycles, 1) {
            HoverDiagnostics.reset()
            func step(_ name: String) { watchdog.label = "cycle \(cycle) \(name)" }
            let cpuStart = Self.cpuSeconds()
            let wallStart = ProcessInfo.processInfo.systemUptime

            step("open")
            model.openDashboard(.home)
            await settle(0.4)
            for section in DashboardSection.allCases {
                step("section \(section.rawValue)")
                model.openDashboard(section)
                await settle(0.15)
            }
            for page in AdvancedPage.allCases {
                step("advanced \(page.rawValue)")
                model.showAdvanced(page)
                await settle(0.15)
            }
            model.showAdvanced(.history)
            for range in ChartRange.available(for: model.settings.historyRetention) {
                step("range \(range.rawValue)")
                model.settings.dashboardRange = range
                await settle(0.15)
            }
            step("range fifteenMinutes")
            model.settings.dashboardRange = .fifteenMinutes
            await settle(0.2)
            // RAMLUME_STRESS_HOVER=0 runs the cycle without synthetic hover.
            let hovers = ProcessInfo.processInfo.environment["RAMLUME_STRESS_HOVER"] != "0"
            step("hover history")
            if hovers { await hoverSweep() }
            step("home")
            model.openDashboard(.home)
            await settle(0.2)
            step("hover home")
            if hovers { await hoverSweep() }
            for appearance in [AppearancePreference.dark, .light, .system] {
                step("appearance \(appearance.rawValue)")
                model.settings.appearance = appearance
                await settle(0.1)
            }
            step("panel")
            closedPanels.append(await panelCycle(hovers: hovers))
            step("pause and resume")
            model.monitor.setPaused(true)
            await settle(0.1)
            model.monitor.setPaused(false)
            await settle(0.1)
            step("sleep and wake")
            model.monitor.systemWillSleep()
            await settle(0.1)
            model.monitor.systemDidWake()
            await settle(0.2)
            step("pressure flapping")
            for index in 0..<50 {
                model.monitor.handlePressureEvent(index.isMultiple(of: 2) ? .warning : .normal)
            }
            await settle(0.2)
            step("close")
            closedDashboards.append(WeakView(view: dashboard.debugHostingView))
            dashboard.close()
            await settle(0.3)
            // Rapid open/close: each window closes 20 ms after opening, while History is still
            // being built.
            step("rapid open and close")
            for _ in 0..<10 {
                model.showAdvanced(.history)
                await settle(0.02)
                closedDashboards.append(WeakView(view: dashboard.debugHostingView))
                dashboard.close()
            }
            await settle(0.3)

            let counts = HoverDiagnostics.counts
            let stall = watchdog.takeMaxStall()
            if stall.gap > worstStall.gap { worstStall = stall }
            print(String(format: "UISTRESS cycle %3d  cpu %5.2f s / %4.1f s  footprint %6.1f MB  overlay renders %5d  hover calls %5d  writes %5d  live dashboards %d  live panels %d  windows %d  max stall %@",
                         cycle, Self.cpuSeconds() - cpuStart, ProcessInfo.processInfo.systemUptime - wallStart,
                         Self.footprint() / 1_048_576, counts.crosshairBodies, counts.handlerCalls, counts.stateWrites,
                         closedDashboards.filter { $0.view != nil }.count, closedPanels.filter { $0.view != nil }.count,
                         NSApp.windows.count, stall.summary as NSString))
            if cycle == checkpoint {
                // `RAMLUME_STRESS_CHECKPOINT=<cycle>`: idle for 30 s after that cycle, so a memory graph
                // (`leaks --outputGraph`) can be compared with one taken at the end (`heap --diffFrom`).
                watchdog.label = "checkpoint"
                print("UISTRESS CHECKPOINT pid \(getpid()) after cycle \(cycle)")
                await settle(30)
                _ = watchdog.takeMaxStall()
            }
        }
        let endFootprint = Self.footprint()
        // Separates memory that's still in use from freed memory macOS hasn't reclaimed yet.
        await settle(5)
        let settledFootprint = Self.footprint()
        _ = malloc_zone_pressure_relief(nil, 0)
        await settle(1)
        print(String(format: "UISTRESS DONE footprint at launch %.1f MB, after the last close %.1f MB, 5 s later %.1f MB, after malloc pressure relief %.1f MB; dashboards still alive %d of %d; panels still alive %d of %d; worst stall %@",
                     launchFootprint / 1_048_576, endFootprint / 1_048_576, settledFootprint / 1_048_576, Self.footprint() / 1_048_576,
                     closedDashboards.filter { $0.view != nil }.count, closedDashboards.count,
                     closedPanels.filter { $0.view != nil }.count, closedPanels.count, worstStall.summary as NSString))
        await holdIfRequested()
        model.quit()
    }

    private struct WeakView {
        weak var view: NSView?
    }

    /// The menu bar panel's content in a window (stress runs have no menu bar item to show the
    /// popover from): shown, swept with hover, then released the way the popover releases it.
    private func panelCycle(hovers: Bool) async -> WeakView {
        let hosting = NSHostingController(rootView: MenuPanelView().environment(model))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        model.monitor.setVisible(true, surface: .menuPanel)
        window.orderFront(nil)
        await settle(0.4)
        if hovers { await hoverSweep(in: hosting.view, steps: 20) }
        let panel = WeakView(view: hosting.view)
        window.orderOut(nil)
        window.contentViewController = nil
        model.monitor.setVisible(false, surface: .menuPanel)
        return panel
    }

    /// `RAMLUME_STRESS_HOLD_SECONDS=<n>` keeps the process alive (and idle) after a run, for
    /// `leaks`, `heap`, or `vmmap`.
    private func holdIfRequested() async {
        guard let seconds = ProcessInfo.processInfo.environment["RAMLUME_STRESS_HOLD_SECONDS"].flatMap(Double.init), seconds > 0 else { return }
        watchdog.label = "hold"
        print("UISTRESS HOLD pid \(getpid()) for \(Int(seconds)) s")
        await settle(seconds)
    }

    // MARK: Events probe

    /// Shows the Events section in a fresh window after filling the timeline with `n` events, for
    /// growing `n`. `--events-probe`.
    func eventsProbe() async {
        for count in [5, 20, 40, 60, 80, 120, 200, 300] {
            let history = model.monitor.history
            history.clearAll()
            let now = Date()
            for index in 0..<count {
                let level: MemoryPressureLevel = index.isMultiple(of: 2) ? .warning : .normal
                history.record(MemoryEvent(date: now.addingTimeInterval(Double(index - count)), kind: .pressureChanged,
                                           title: "Memory pressure: \(level.displayName)",
                                           detail: "Changed as reported by macOS.", pressure: level))
            }
            print("EVENTSPROBE events=\(count) show")
            model.openDashboard(.home)
            await settle(0.4)
            model.showAdvanced(.events)
            await settle(0.6)
            print("EVENTSPROBE events=\(count) close")
            dashboard.close()
            await settle(0.4)
        }
        print("EVENTSPROBE done")
        model.quit()
    }

    // MARK: Processes probe

    /// Shows Processes and feeds it one kind of change per scan (see `ScriptedProcessProvider`),
    /// three times over, marking each step, so AppKit table warnings can be tied to the change
    /// that caused them. `--processes-probe`.
    ///
    /// Known issue it reproduces (present since 0.1.0): with a long list whose order changes
    /// between scans, AppKit logs "reentrant operation in its NSTableView delegate" while SwiftUI's
    /// `Table` applies the change. Structural changes to a short list (groups gaining or losing
    /// members, processes moving between groups) don't.
    func processesProbe() async {
        model.openDashboard(.applications)
        await settle(1)
        for round in 1...3 {
            for (index, step) in ScriptedProcessProvider.steps.enumerated() {
                ScriptedProcessProvider.shared.step = index
                print("PROCESSPROBE round \(round) step \(step.name)")
                model.monitor.refreshProcesses()
                await settle(1)
            }
        }
        print("PROCESSPROBE done")
        model.quit()
    }

    // MARK: Soak

    func soak(minutes: Int) async {
        watchdog.start()
        print("UISOAK minutes=\(minutes)")
        model.settings.dashboardRange = .fifteenMinutes
        model.showAdvanced(.history)
        await settle(2)
        let start = ProcessInfo.processInfo.systemUptime
        var worstStall = HoverLab.Watchdog.Stall()
        for minute in 1...max(minutes, 1) {
            HoverDiagnostics.reset()
            let cpuStart = Self.cpuSeconds()
            let minuteStart = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime - minuteStart < 60 {
                // RAMLUME_SOAK_HOVER=0 measures redraws without any hover activity.
                if ProcessInfo.processInfo.environment["RAMLUME_SOAK_HOVER"] != "0" {
                    watchdog.label = "soak minute \(minute) hover"
                    await hoverSweep(steps: 12)
                }
                watchdog.label = "soak minute \(minute) idle"
                await settle(5)
            }
            let counts = HoverDiagnostics.counts
            let stall = watchdog.takeMaxStall()
            if stall.gap > worstStall.gap { worstStall = stall }
            print(String(format: "UISOAK minute %3d  cpu %5.2f%%  footprint %6.1f MB  overlay renders %5d  hover calls %5d  writes %5d  max stall %@",
                         minute, (Self.cpuSeconds() - cpuStart) / 60 * 100, Self.footprint() / 1_048_576,
                         counts.crosshairBodies, counts.handlerCalls, counts.stateWrites, stall.summary as NSString))
        }
        print(String(format: "UISOAK DONE %.1f minutes, worst stall %@", (ProcessInfo.processInfo.systemUptime - start) / 60, worstStall.summary as NSString))
        await holdIfRequested()
        model.quit()
    }

    // MARK: Helpers

    private func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// A view that owns one of SwiftUI's hover tracking areas, and its frame in window coordinates.
    private struct HoverHost {
        var view: NSView
        var tag: Int
        var frame: NSRect
    }

    /// Every hover-tracking hosting view in the dashboard (the split view's columns each host
    /// their own SwiftUI hierarchy, so hover areas live below the window's content view).
    private func hoverHosts(in root: NSView) -> [HoverHost] {
        var result: [HoverHost] = []
        func visit(_ view: NSView) {
            for area in view.trackingAreas where area.owner === view
                && area.options.contains(.mouseMoved) && area.options.contains(.inVisibleRect) {
                result.append(HoverHost(view: view, tag: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()),
                                        frame: view.convert(view.bounds, to: nil)))
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return result
    }

    private func enterExit(_ type: NSEvent.EventType, _ host: HoverHost, at location: NSPoint) {
        guard let window = host.view.window,
              let event = NSEvent.enterExitEvent(with: type, location: location, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, trackingNumber: host.tag, userData: nil) else { return }
        if type == .mouseEntered { host.view.mouseEntered(with: event) } else { host.view.mouseExited(with: event) }
    }

    /// Moves a synthetic pointer across the dashboard (or `view`) in rows, through SwiftUI's hover
    /// path, passing the middle-right of each row (where the original hang happened).
    private func hoverSweep(in view: NSView? = nil, steps: Int = 40) async {
        guard let root = view ?? dashboard.debugHostingView, let window = root.window else { return }
        let hosts = hoverHosts(in: root)
        guard !hosts.isEmpty else {
            print("UISTRESS no hover tracking areas in \(view == nil ? "the dashboard" : "the panel")")
            return
        }
        let frame = root.convert(root.bounds, to: nil)
        var current: HoverHost?
        for row in [0.25, 0.45, 0.65] as [CGFloat] {
            for step in 0...steps {
                let location = NSPoint(x: frame.minX + (0.25 + 0.75 * CGFloat(step) / CGFloat(steps)) * frame.width,
                                       y: frame.maxY - row * frame.height)
                // The innermost hover-tracking view under the pointer.
                let host = hosts.filter { $0.frame.contains(location) }.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
                if host?.view !== current?.view {
                    if let current { enterExit(.mouseExited, current, at: location) }
                    if let host { enterExit(.mouseEntered, host, at: location) }
                    current = host
                }
                if let host, let move = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                    host.view.mouseMoved(with: move)
                }
                if step.isMultiple(of: 8) { await settle(0.01) }
            }
            await settle(0.3)
        }
        if let current { enterExit(.mouseExited, current, at: NSPoint(x: -10, y: -10)) }
        await settle(0.1)
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    /// Physical footprint in bytes, the figure Activity Monitor and `footprint` report.
    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) : 0
    }
}

/// Process lists for `--processes-probe`. Each step changes the previous list in one way that
/// matters to an outline table: re-sorting, a group gaining or losing a member, a process moving
/// into or out of a group, processes starting and exiting, and a long list being reordered.
final class ScriptedProcessProvider: ProcessProviding, @unchecked Sendable {
    static let shared = ScriptedProcessProvider()
    private let current = OSAllocatedUnfairLock(initialState: 0)

    var step: Int {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }

    func scanProcesses() async -> ProcessSnapshot {
        let steps = Self.steps
        let records = steps[min(max(step, 0), steps.count - 1)].records
        let accessible = records.count(where: \.isAccessible)
        return ProcessSnapshot(timestamp: Date(), groups: ProcessGrouper.makeGroups(from: records, bundleMetadata: [:]),
                               totalCount: records.count, accessibleCount: accessible,
                               restrictedCount: records.count - accessible, scanDuration: 0.01)
    }

    private static func record(_ pid: Int32, _ name: String, _ path: String, _ megabytes: Double) -> ProcessRecord {
        let bundle = ProcessGrouper.outermostAppBundlePath(forExecutablePath: path)
        let footprint = UInt64(megabytes * 1_048_576)
        return ProcessRecord(pid: pid, name: name, executablePath: path, appBundlePath: bundle,
                             role: ProcessGrouper.role(executablePath: path, bundlePath: bundle),
                             userID: 501, userName: "probe", parentPID: 1, footprint: footprint,
                             peakFootprint: footprint, access: .accessible)
    }

    /// An app with one process, an app with a helper, two processes sharing an executable, and
    /// standalone processes (enough to scroll).
    private static let base: [ProcessRecord] = {
        var records: [ProcessRecord] = [
            record(100, "Alpha", "/Applications/Alpha.app/Contents/MacOS/Alpha", 900),
            record(200, "Beta", "/Applications/Beta.app/Contents/MacOS/Beta", 700),
            record(201, "Beta Helper", "/Applications/Beta.app/Contents/Frameworks/Beta Helper.app/Contents/MacOS/Beta Helper", 300),
            record(300, "worker", "/usr/libexec/worker", 120),
            record(301, "worker", "/usr/libexec/worker", 110),
        ]
        for index in 0..<40 {
            let megabytes = Double(50 + index)
            records.append(record(Int32(1_000 + index), "tool\(index)", "/usr/local/bin/tool\(index)", megabytes))
        }
        return records
    }()

    static let steps: [(name: String, records: [ProcessRecord])] = {
        var list: [(String, [ProcessRecord])] = [("base", base), ("unchanged", base)]
        let resorted: [ProcessRecord] = base.map { (item: ProcessRecord) -> ProcessRecord in
            let megabytes: Double = 2_000 - Double(item.footprint ?? 0) / 1_048_576
            return record(item.pid, item.name, item.executablePath ?? "", megabytes)
        }
        list.append(("re-sorted", resorted))
        list.append(("base again", base))
        list.append(("app gains a helper", base + [record(101, "Alpha Helper", "/Applications/Alpha.app/Contents/MacOS/Alpha Helper", 80)]))
        list.append(("app loses its helper", base))
        list.append(("group loses a member", base.filter { $0.pid != 201 }))
        list.append(("group gets it back", base))
        list.append(("process joins a shared executable", base + [record(1_041, "tool0", "/usr/local/bin/tool0", 60)]))
        list.append(("process leaves it again", base))
        list.append(("shared executable splits", base.filter { $0.pid != 301 }))
        list.append(("shared executable rejoins", base))
        list.append(("processes exit", base.filter { $0.pid < 1_030 }))
        list.append(("processes start", base))
        list.append(("everything at once", base.filter { $0.pid != 201 && $0.pid != 1_005 } + [
            record(101, "Alpha Helper", "/Applications/Alpha.app/Contents/MacOS/Alpha Helper", 80),
            record(1_042, "tool1", "/usr/local/bin/tool1", 61),
        ]))
        list.append(("base at the end", base))
        // A list as long as a real one, whose footprints shift by up to 3% on every scan, as real
        // ones do (deterministically, so every run sees the same lists).
        // Explicit types and small steps: Xcode 26's type checker gives up on these closures otherwise.
        let large: [ProcessRecord] = (0..<600).map { (index: Int) -> ProcessRecord in
            let megabytes = Double(20 + index % 300)
            return record(Int32(5_000 + index), "service\(index)", "/usr/libexec/service\(index)", megabytes)
        }
        for scan in 1...8 {
            var shifted: [ProcessRecord] = []
            for (index, item) in large.enumerated() {
                let step: Int = (index * 7_919 + scan * 104_729) % 61 - 30
                let shift: Double = 1 + Double(step) / 1_000
                let megabytes: Double = Double(item.footprint ?? 0) / 1_048_576 * shift
                shifted.append(record(item.pid, item.name, item.executablePath ?? "", megabytes))
            }
            list.append(("600 processes, footprints shift (\(scan))", shifted))
        }
        return list
    }()
}
#endif
