import Foundation
import Testing

/// Runs a second copy of the test host app (a Debug build) with debug-only harness arguments, for
/// tests that need real windows and SwiftUI: a hang or crash then fails the test instead of
/// stopping the test runner. Needs a logged-in GUI session.
enum ChildApp {
    /// Launches the app with `arguments` and returns everything it printed. A child that is still
    /// running after `timeout` is terminated and the output ends with "TIMED OUT".
    static func run(_ arguments: [String], timeout: TimeInterval) throws -> String {
        let executable = try #require(Bundle.main.executablePath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // The child must start as a normal app, not as another test host.
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("XCTest") || key.hasPrefix("XCInject") || key == "DYLD_INSERT_LIBRARIES" {
            environment[key] = nil
        }
        process.environment = environment
        let output = FileManager.default.temporaryDirectory.appending(path: "ramlume-child-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: output)
        }
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return (try String(contentsOf: output, encoding: .utf8)) + "\nTIMED OUT after \(Int(timeout)) s"
        }
        let text = try String(contentsOf: output, encoding: .utf8)
        return process.terminationStatus == 0 ? text : text + "\nEXIT STATUS \(process.terminationStatus)"
    }

    /// A path for a scratch history file, so child apps never touch the real one. The caller
    /// deletes it.
    static func scratchHistoryFile() -> String {
        FileManager.default.temporaryDirectory.appending(path: "ramlume-child-history-\(UUID().uuidString).json").path
    }

    /// Arguments that keep a child app invisible to the person at the Mac: no activation, no menu
    /// bar item, and windows treated as visible so they render at their on-screen cadence.
    static let quiet = ["--no-activate", "--assume-visible", "--no-status-item"]
}
