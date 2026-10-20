import AppKit
import Observation

/// The dashboard's sections: three for everyone, plus the technical detail behind them.
enum DashboardSection: String, CaseIterable, Identifiable, Sendable {
    case home
    case applications
    case recommendations
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .applications: "Applications"
        case .recommendations: "Recommendations"
        case .advanced: "Advanced Details"
        }
    }

    var symbolName: String {
        switch self {
        case .home: "house"
        case .applications: "square.grid.2x2"
        case .recommendations: "lightbulb"
        case .advanced: "slider.horizontal.3"
        }
    }
}

/// Pages inside Advanced Details.
enum AdvancedPage: String, CaseIterable, Identifiable, Sendable {
    case memory
    case history
    case events
    case definitions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .memory: "Memory"
        case .history: "History"
        case .events: "Events"
        case .definitions: "Definitions"
        }
    }
}

enum SettingsTab: String, CaseIterable, Sendable {
    case general
    case monitoring
    case notifications
    case history
    case about
}

/// The composition root shared by every window: settings, the monitoring coordinator, services,
/// and navigation actions. Views receive it through the SwiftUI environment.
@MainActor
@Observable
final class AppModel {
    let settings: SettingsStore
    let monitor: MonitoringCoordinator
    let notifications: NotificationService
    let launchAtLogin: LaunchAtLoginService

    var dashboardSection: DashboardSection? = .home
    var advancedPage: AdvancedPage = .memory
    /// Set when notification permission was refused, to explain what happened in Settings.
    var notificationPermissionDenied = false

    @ObservationIgnored var openDashboardHandler: ((DashboardSection?) -> Void)?
    @ObservationIgnored var openSettingsHandler: ((SettingsTab?) -> Void)?
    @ObservationIgnored var closePanelHandler: (() -> Void)?

    init(settings: SettingsStore, monitor: MonitoringCoordinator, notifications: NotificationService, launchAtLogin: LaunchAtLoginService) {
        self.settings = settings
        self.monitor = monitor
        self.notifications = notifications
        self.launchAtLogin = launchAtLogin
    }

    // MARK: Navigation

    func openDashboard(_ section: DashboardSection? = nil) {
        closePanelHandler?()
        openDashboardHandler?(section)
    }

    /// Opens Advanced Details at `page`.
    func showAdvanced(_ page: AdvancedPage) {
        advancedPage = page
        openDashboard(.advanced)
    }

    /// Carries out a recommendation's action. Actions only navigate or open Apple's own tools;
    /// none of them changes system settings or ends a process.
    func perform(_ action: Recommendation.Action) {
        switch action {
        case .viewApplications:
            openDashboard(.applications)
        case .viewMemoryDetails:
            showAdvanced(.definitions)
        case .openActivityMonitor:
            closePanelHandler?()
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .openLoginItemsSettings:
            closePanelHandler?()
            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    func openSettings(_ tab: SettingsTab? = nil) {
        closePanelHandler?()
        openSettingsHandler?(tab)
    }

    func showAbout() {
        closePanelHandler?()
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: AppInfo.aboutPanelOptions)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    func togglePause() {
        monitor.setPaused(!monitor.isPausedByUser)
    }

    // MARK: Notifications

    /// Turns notifications on (asking macOS for permission first) or off.
    func setNotificationsEnabled(_ enabled: Bool) async {
        guard enabled else {
            settings.notificationsEnabled = false
            return
        }
        let granted = await notifications.requestAuthorization()
        notificationPermissionDenied = !granted
        settings.notificationsEnabled = granted
    }

    /// Posts a sample notification from Settings so people can check that notifications reach them.
    func sendTestNotification() async -> Bool {
        let sent = await notifications.sendTestNotification()
        notificationPermissionDenied = notifications.authorization == .denied
        return sent
    }
}

/// Static facts about the app.
enum AppInfo {
    static let name = "RamLume"
    static let tagline = "Understand your Mac's memory."

    /// The public repository. Forks can point this at their own repository, or set it to `nil`
    /// to hide the link.
    static let repositoryURL: URL? = URL(string: "https://github.com/13nik09/RamLume")

    static var issuesURL: URL? {
        repositoryURL?.appendingPathComponent("issues/new/choose")
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    static var bundleIdentifier: String {
        Bundle.main.bundleIdentifier ?? "RamLume"
    }

    @MainActor
    static var aboutPanelOptions: [NSApplication.AboutPanelOptionKey: Any] {
        let credits = NSMutableAttributedString(
            string: "\(tagline)\n\nFree and open source under the MIT License.\nEverything stays on your Mac: no network access, analytics, or accounts.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        return [
            .applicationName: name,
            .applicationVersion: version,
            .version: build,
            .credits: credits,
        ]
    }
}

#if DEBUG
/// Debug-only switches set from launch arguments (see `AppDelegate`).
@MainActor
enum DebugOptions {
    /// `--front`: show windows above other apps without activating RamLume (for screenshots).
    static var ordersWindowsFrontRegardless = false
    /// `--no-mouse`: windows ignore the pointer, for reproducible performance measurements.
    static var ignoresMouse = false
    /// `--assume-visible`: treat the dashboard as on screen even if it's covered or on another
    /// Space, to measure rendering cost without disturbing the desktop.
    static var assumesDashboardVisible = false
    /// `--no-activate`: open windows without activating RamLume, so automated screenshots don't
    /// take keyboard focus from whatever the person at the Mac is doing.
    static var avoidsActivation = false
    /// `--demo`: example data for README screenshots (see `DemoData`).
    static var isDemo = false
}
#endif

enum RuntimeEnvironment {
    /// True when the app is hosting unit tests; the app then skips its UI and monitoring.
    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }
}
