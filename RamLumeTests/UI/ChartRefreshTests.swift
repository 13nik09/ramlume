import AppKit
import SwiftUI
import Testing
@testable import RamLume

/// History charts in a real (invisible) window: what they show when history changes under them.
@MainActor
@Suite("Chart refresh")
struct ChartRefreshTests {
    final class Rendered: @unchecked Sendable {
        var pointCounts: [Int] = []
    }

    /// The 24-hour range redraws on a 30-second timer. Clearing history mustn't wait for it.
    @Test func aChartShowsClearedHistoryAtOnce() async throws {
        let clock = TestClock(Date().addingTimeInterval(-10))
        let history = HistoryStore(retention: .oneDay, persistence: nil, now: clock.now)
        let coordinator = MonitoringCoordinator(
            memoryReader: .success(FakeMemoryReader(clock: clock)),
            swapReader: FakeSwapReader(),
            pressureReader: FakePressureReader(),
            processReader: FakeProcessProvider(snapshot: Fixtures.braveSnapshot()),
            history: history,
            clock: { clock.now },
            schedulesSampling: false
        )
        let suite = "RamLumeTests.ChartRefresh.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(
            settings: SettingsStore(defaults: defaults),
            monitor: coordinator,
            notifications: NotificationService(),
            launchAtLogin: LaunchAtLoginService()
        )
        coordinator.start()
        coordinator.setVisible(true, surface: .dashboard)
        clock.advance(by: 5)
        coordinator.sampleNow()

        let rendered = Rendered()
        let chart = HistorySeriesReader(range: .oneDay) { series in
            let _ = rendered.pointCounts.append(series.points.count)
            Color.clear
        }
        // Invisible and never activated, like the hover lab's window.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: chart.environment(model))
        window.orderFrontRegardless()
        defer { window.close() }

        try await Task.sleep(for: .milliseconds(300))
        #expect((rendered.pointCounts.last ?? 0) > 0)

        coordinator.clearHistory()
        try await Task.sleep(for: .milliseconds(300))
        #expect(rendered.pointCounts.last == 0)
    }
}
