import Foundation
import Testing
@testable import RamLume

/// Guards against hover feedback loops in the history charts (the cause of a 100% CPU hang).
///
/// Runs the hover lab (`RamLume/Debug/HoverLab.swift`) in a child copy of the app: SwiftUI's real
/// hover handling, driven by in-process synthetic events, never the real pointer. A loop makes the
/// child's main thread stall, which its watchdog reports; running it in a separate process keeps a
/// regression from hanging the test runner.
@Suite("Hover feedback loops", .serialized)
struct HoverLoopRegressionTests {
    struct ScenarioResult {
        var name: String
        var events: Int
        var handlerCalls: Int
        var stateWrites: Int
    }

    @Test(.timeLimit(.minutes(3)))
    func restingOrMovingPointerNeverLoops() throws {
        let output = try ChildApp.run(["--hover-lab", "regression"] + ChildApp.quiet, timeout: 150)
        #expect(!output.contains("STALL"), "A hover loop stalled the main thread:\n\(output)")
        #expect(output.contains("HOVERLAB DONE"), "The lab didn't finish:\n\(output)")

        let results = Self.parse(output)
        #expect(results.count == 24, "Expected 4 scenarios for each of the 6 charts:\n\(output)")
        for result in results {
            // Without a loop, every delivered event causes at most a couple of handler calls and
            // state writes. The hang produced over 10,000 per second.
            #expect(result.handlerCalls <= 3 * result.events + 20, "\(result.name): \(result.handlerCalls) handler calls for \(result.events) events")
            #expect(result.stateWrites <= 3 * result.events + 20, "\(result.name): \(result.stateWrites) state writes for \(result.events) events")
        }
    }

    /// Reads the summary the lab prints after "HOVERLAB DONE" (each result appears once there).
    static func parse(_ output: String) -> [ScenarioResult] {
        guard let done = output.range(of: "HOVERLAB DONE") else { return [] }
        return output[done.upperBound...].split(separator: "\n").compactMap { line -> ScenarioResult? in
            let text = String(line)
            guard text.hasPrefix("regression."), !text.contains("HOVERLAB") else { return nil }
            func number(after label: String) -> Int? {
                guard let range = text.range(of: label + " ") else { return nil }
                let rest = text[range.upperBound...].drop { $0 == " " }
                return Int(rest.prefix { $0.isNumber })
            }
            guard let events = number(after: "events"), let handler = number(after: "handler"),
                  let writes = number(after: "writes") else { return nil }
            let name = text.split(separator: " ").first.map(String.init) ?? text
            return ScenarioResult(name: name, events: events, handlerCalls: handler, stateWrites: writes)
        }
    }
}

/// Guards the dashboard's UI lifecycle end to end, in a child copy of the app.
@Suite("Dashboard lifecycle", .serialized)
struct DashboardLifecycleTests {
    /// With a couple of hundred events, the Events timeline used to be a `List` whose table view
    /// logged "reentrant operation in its NSTableView delegate" (AppKit: "will become an assert").
    @Test(.timeLimit(.minutes(2)))
    func longEventTimelineShowsWithoutTableWarnings() throws {
        let history = ChildApp.scratchHistoryFile()
        defer { try? FileManager.default.removeItem(atPath: history) }
        let output = try ChildApp.run(["--events-probe", "--history-file", history] + ChildApp.quiet, timeout: 90)
        #expect(output.contains("EVENTSPROBE done"), "The probe didn't finish:\n\(output)")
        #expect(output.contains("events=300 show"))
        #expect(!output.contains("reentrant operation"), "AppKit table warning:\n\(output)")
    }

    /// Three full cycles: open, every section and range, hover, appearance, the panel, pause, sleep
    /// and wake, memory-pressure flapping, close, then rapid open/close. Fails on a main-thread
    /// stall, an AppKit table warning, or a closed dashboard or panel whose SwiftUI hierarchy stays
    /// in memory.
    @Test(.timeLimit(.minutes(3)))
    func fullLifecycleCyclesStayResponsive() throws {
        let history = ChildApp.scratchHistoryFile()
        defer { try? FileManager.default.removeItem(atPath: history) }
        let output = try ChildApp.run(["--ui-stress", "3", "--pressure-events-only", "--history-file", history] + ChildApp.quiet, timeout: 150)
        #expect(output.contains("UISTRESS DONE"), "The stress run didn't finish:\n\(output)")
        #expect(!output.contains("STALL"), "The main thread stalled:\n\(output)")
        #expect(!output.contains("reentrant operation"), "AppKit table warning:\n\(output)")
        // Each cycle closes 11 dashboards: the full one and 10 opened and closed in quick succession.
        #expect(output.contains("dashboards still alive 0 of 33"), "A closed dashboard wasn't released:\n\(output)")
        #expect(output.contains("panels still alive 0 of 3"), "A closed panel wasn't released:\n\(output)")
    }
}
