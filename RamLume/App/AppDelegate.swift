import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusItemController: StatusItemController?
    private var dashboardController: DashboardWindowController?
    private var settingsController: SettingsWindowController?
    private var pressureObserver: MemoryPressureObserver?
    private let systemEvents = SystemEventsObserver()
    private var signalSources: [any DispatchSourceSignal] = []
    private var activationObserver: NSObjectProtocol?
    private var showDashboardObserver: NSObjectProtocol?
    #if DEBUG
    private var debugPanelWindow: NSWindow?
    private var hoverLab: HoverLab?
    private var uiStress: UIStress?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests are hosted by the app; don't start monitoring or add a status item.
        guard !RuntimeEnvironment.isRunningTests else { return }
        // One RamLume at a time: a second copy (say, one still in Downloads) would add a second
        // menu bar item and write the same history file.
        if !Self.isDebugHarness, handOffToRunningInstance() { return }

        NSApp.mainMenu = MainMenuBuilder.makeMainMenu(target: self)
        installTerminationSignalHandlers()

        let settings = Self.makeSettings()
        AppearanceController.apply(settings.appearance)
        settings.dashboardRange = ChartRange.clamped(settings.dashboardRange, to: settings.historyRetention)

        let monitor: MonitoringCoordinator
        #if DEBUG
        // The hover lab and the processes probe use demo readers too, so they never read or write
        // the history file.
        DebugOptions.isDemo = ["--demo", "--hover-lab", "--processes-probe"].contains { CommandLine.arguments.contains($0) }
        if DebugOptions.isDemo {
            // Example data for screenshots: no history file is read or written.
            let anchor = Date()
            monitor = MonitoringCoordinator(
                memoryReader: .success(DemoData.MemoryReader(anchor: anchor)),
                swapReader: DemoData.SwapReader(anchor: anchor),
                pressureReader: DemoData.PressureReader(anchor: anchor),
                processReader: CommandLine.arguments.contains("--processes-probe")
                    ? ScriptedProcessProvider.shared : DemoData.ProcessProvider(),
                history: DemoData.makeHistory(anchor: anchor, retention: settings.historyRetention)
            )
        } else {
            monitor = Self.makeMonitor(settings: settings)
        }
        #else
        monitor = Self.makeMonitor(settings: settings)
        #endif
        let model = AppModel(
            settings: settings,
            monitor: monitor,
            notifications: NotificationService(),
            launchAtLogin: LaunchAtLoginService()
        )
        self.model = model

        let statusItemController = StatusItemController(model: model)
        self.statusItemController = statusItemController
        let dashboardController = DashboardWindowController(model: model)
        self.dashboardController = dashboardController
        let settingsController = SettingsWindowController(model: model)
        self.settingsController = settingsController

        model.openDashboardHandler = { [weak dashboardController] section in
            dashboardController?.show(section: section)
        }
        model.openSettingsHandler = { [weak settingsController] tab in
            settingsController?.show(tab: tab)
        }
        model.closePanelHandler = { [weak statusItemController] in
            statusItemController?.closePanel()
        }
        model.notifications.onOpen = { [weak dashboardController] in
            dashboardController?.show(section: .recommendations)
        }

        configureMonitoring(model)
        observeHandOffRequests(model)

        settings.onChange = { [weak self] change in
            self?.handleSettingsChange(change)
        }

        Task { await model.notifications.refreshAuthorization() }
        // The user can change notification permission in System Settings at any time.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated {
                guard let model else { return }
                Task { await model.notifications.refreshAuthorization() }
            }
        }

        #if DEBUG
        // Debug-only launch arguments for screenshots and manual testing; see docs/building.md.
        if handleDebugLaunchArguments(model: model, statusItemController: statusItemController) { return }
        #endif

        if !settings.hasShownWelcome {
            // Point first-time users at the menu bar item. The panel shows a short welcome note.
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                statusItemController.showPanel()
            }
        }
    }

    private static func makeMonitor(settings: SettingsStore) -> MonitoringCoordinator {
        let history = HistoryStore(
            retention: settings.historyRetention,
            persistence: historyFileURL().map(HistoryPersistence.init(fileURL:))
        )
        let memoryReader: Result<any MemoryStatisticsProviding, MemoryReadError>
        do {
            memoryReader = .success(try SystemMemoryReader())
        } catch {
            memoryReader = .failure(error)
        }
        var pressureReader: any PressureLevelProviding = KernelPressureReader()
        #if DEBUG
        if CommandLine.arguments.contains("--pressure-events-only") {
            pressureReader = EventsOnlyPressureReader()
        }
        #endif
        return MonitoringCoordinator(
            memoryReader: memoryReader,
            swapReader: SystemSwapReader(),
            pressureReader: pressureReader,
            processReader: ProcessReader(),
            history: history
        )
    }

    /// The history file. Debug harnesses record made-up events and clear history, so unless they're
    /// given a scratch `--history-file` they keep history in memory only.
    private static func historyFileURL() -> URL? {
        #if DEBUG
        if isDebugHarness, !CommandLine.arguments.contains("--history-file") { return nil }
        #endif
        return HistoryPersistence.defaultFileURL()
    }

    /// The person's preferences, except in debug harness runs: those change settings (appearance,
    /// chart range) while they work, so they use a scratch domain that starts from the defaults on
    /// every launch, even when the test host has the official bundle identifier.
    private static func makeSettings() -> SettingsStore {
        #if DEBUG
        if isDebugHarness, let identifier = Bundle.main.bundleIdentifier,
           let defaults = UserDefaults(suiteName: "\(identifier).debug-harness") {
            defaults.removePersistentDomain(forName: "\(identifier).debug-harness")
            let settings = SettingsStore(defaults: defaults)
            settings.hasShownWelcome = true
            return settings
        }
        #endif
        return SettingsStore()
    }

    /// Debug harnesses run as separate processes next to a running copy (for example the test
    /// host), so they skip the single-instance hand-off.
    private static var isDebugHarness: Bool {
        #if DEBUG
        let arguments = CommandLine.arguments
        return ["--hover-lab", "--ui-stress", "--soak", "--events-probe", "--processes-probe", "--history-file"]
            .contains { arguments.contains($0) }
        #else
        return false
        #endif
    }

    /// Posted by a second copy of RamLume to ask the running one to show its dashboard.
    private static var showDashboardNotification: Notification.Name {
        Notification.Name("\(Bundle.main.bundleIdentifier ?? "RamLume").showDashboard")
    }

    /// If RamLume is already running, asks it to show its dashboard and quits this copy.
    private func handOffToRunningInstance() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let current = NSRunningApplication.current
        guard NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains(where: { $0.processIdentifier != current.processIdentifier && !$0.isTerminated }) else { return false }
        DistributedNotificationCenter.default().postNotificationName(
            Self.showDashboardNotification, object: nil, userInfo: nil, deliverImmediately: true
        )
        NSApp.terminate(nil)
        return true
    }

    private func observeHandOffRequests(_ model: AppModel) {
        showDashboardObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.showDashboardNotification,
            object: nil,
            queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated {
                model?.openDashboard()
            }
        }
    }

    #if DEBUG
    private func handleDebugLaunchArguments(model: AppModel, statusItemController: StatusItemController) -> Bool {
        let arguments = CommandLine.arguments
        DebugOptions.ordersWindowsFrontRegardless = arguments.contains("--front")
        DebugOptions.ignoresMouse = arguments.contains("--no-mouse")
        DebugOptions.assumesDashboardVisible = arguments.contains("--assume-visible")
        DebugOptions.avoidsActivation = arguments.contains("--no-activate")
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }
        // `--ui-stress <cycles>` and `--soak <minutes>`: see UIStress.
        if let dashboardController, let cycles = value(after: "--ui-stress").flatMap({ Int($0) }) {
            let stress = UIStress(model: model, dashboard: dashboardController)
            uiStress = stress
            Task { await stress.runCycles(cycles) }
            return true
        }
        if let dashboardController, let minutes = value(after: "--soak").flatMap({ Int($0) }) {
            let stress = UIStress(model: model, dashboard: dashboardController)
            uiStress = stress
            Task { await stress.soak(minutes: minutes) }
            return true
        }
        if let dashboardController, arguments.contains("--events-probe") {
            let stress = UIStress(model: model, dashboard: dashboardController)
            uiStress = stress
            Task { await stress.eventsProbe() }
            return true
        }
        if let dashboardController, arguments.contains("--processes-probe") {
            let stress = UIStress(model: model, dashboard: dashboardController)
            uiStress = stress
            Task { await stress.processesProbe() }
            return true
        }
        // `--hover-lab [scenario prefix]`: see HoverLab.
        if arguments.contains("--hover-lab") {
            let filter = value(after: "--hover-lab").flatMap { $0.hasPrefix("--") ? nil : $0 }
            let lab = HoverLab(filter: filter)
            hoverLab = lab
            Task { await lab.run() }
            return true
        }
        // `--test-notification`: the "Allow notifications" flow from Settings, then a test notification.
        if arguments.contains("--test-notification") {
            Task {
                await model.setNotificationsEnabled(true)
                debugReport("notification-authorization=\(model.notifications.authorization) enabled=\(model.settings.notificationsEnabled)")
                let sent = await model.sendTestNotification()
                debugReport("test-notification-sent=\(sent)")
            }
            return true
        }
        // `--login-item on|off|status`: the same calls the "Open RamLume at login" toggle makes.
        if let action = value(after: "--login-item") {
            let launch = model.launchAtLogin
            switch action {
            case "on": launch.setEnabled(true)
            case "off": launch.setEnabled(false)
            default: launch.refresh()
            }
            debugReport("login-item=\(launch.state) error=\(launch.lastError ?? "none") bundle=\(Bundle.main.bundlePath)")
            return true
        }
        // `--open-close-cycles <n>`: opens and closes the dashboard n times, for leak checks.
        if let cycles = value(after: "--open-close-cycles").flatMap({ Int($0) }) {
            Task { [weak dashboardController = self.dashboardController] in
                for cycle in 1...max(cycles, 1) {
                    model.openDashboard(DashboardSection.allCases[cycle % DashboardSection.allCases.count])
                    try? await Task.sleep(for: .seconds(4))
                    dashboardController?.close()
                    try? await Task.sleep(for: .seconds(2))
                }
                debugReport("open-close-cycles-done=\(cycles)")
            }
            return true
        }
        if let raw = value(after: "--dashboard") {
            // `--advanced-page <page>`: which Advanced Details page to show (for screenshots).
            if let page = value(after: "--advanced-page").flatMap(AdvancedPage.init(rawValue:)) {
                model.advancedPage = page
            }
            model.openDashboard(DashboardSection(rawValue: raw) ?? .home)
            // `--auto-close <seconds>`: close the dashboard again, to check that its memory is released.
            if let delay = value(after: "--auto-close").flatMap({ Double($0) }) {
                Task { [weak dashboardController = self.dashboardController] in
                    try? await Task.sleep(for: .seconds(delay))
                    dashboardController?.close()
                }
            }
            return true
        }
        if let raw = value(after: "--settings") {
            model.openSettings(SettingsTab(rawValue: raw) ?? .general)
            return true
        }
        if arguments.contains("--panel-window") {
            // The panel's content in a title-less window, for screenshots: unlike the popover, a
            // window renders even when the menu bar isn't on screen (for example in a full-screen Space).
            let hosting = NSHostingController(rootView: MenuPanelView().environment(model))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            window.title = "RamLume Panel (debug)"
            window.isReleasedWhenClosed = false
            debugPanelWindow = window
            model.monitor.setVisible(true, surface: .menuPanel)
            if DebugOptions.avoidsActivation {
                window.orderFront(nil)
            } else {
                window.makeKeyAndOrderFront(nil)
            }
            return true
        }
        if arguments.contains("--panel") {
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                statusItemController.showPanel()
            }
            return true
        }
        return false
    }

    private func debugReport(_ message: String) {
        print("RAMLUME-DEBUG \(message)")
        fflush(stdout)
    }
    #endif

    private func configureMonitoring(_ model: AppModel) {
        let monitor = model.monitor
        let settings = model.settings
        monitor.setProfile(settings.monitoringProfile)
        monitor.setUsesEnergySaverInLowPowerMode(settings.usesEnergySaverInLowPowerMode)
        monitor.setLowPowerMode(SystemEventsObserver.isLowPowerModeEnabled)
        // Alerts are only evaluated once macOS has confirmed permission, so an alert is never
        // "used up" (cooldown started) before it could actually be delivered.
        monitor.notificationPreferences = { [weak settings, weak notifications = model.notifications] in
            guard let settings, notifications?.authorization == .authorized else { return .disabled }
            #if DEBUG
            // Example data must never produce real notifications.
            if DebugOptions.isDemo { return .disabled }
            #endif
            return settings.notificationPreferences
        }
        monitor.onAlerts = { [weak model] alerts in
            model?.notifications.deliver(alerts)
        }
        monitor.onUpdate = { [weak self] in
            self?.statusItemController?.update()
        }

        #if DEBUG
        let observesPressure = !DebugOptions.isDemo
        #else
        let observesPressure = true
        #endif
        let pressureObserver = MemoryPressureObserver { [weak monitor] reading in
            monitor?.handlePressureEvent(reading)
            if reading != .level(.normal) {
                // Be a good citizen: drop cached icons when the system needs memory.
                IconCache.shared.purge()
            }
        }
        if observesPressure {
            pressureObserver.start()
        }
        self.pressureObserver = pressureObserver

        systemEvents.start(.init(
            willSleep: { [weak monitor] in monitor?.systemWillSleep() },
            didWake: { [weak monitor] in monitor?.systemDidWake() },
            willPowerOff: { [weak monitor] in monitor?.history.saveSynchronously() },
            screensAsleepChanged: { [weak monitor] asleep in monitor?.setScreensAsleep(asleep) },
            lowPowerModeChanged: { [weak monitor] enabled in monitor?.setLowPowerMode(enabled) }
        ))

        monitor.start()
    }

    private func handleSettingsChange(_ change: SettingsStore.Change) {
        guard let model else { return }
        switch change {
        case .menuBar:
            statusItemController?.update()
        case .appearance:
            AppearanceController.apply(model.settings.appearance)
        case .monitoring:
            model.monitor.setProfile(model.settings.monitoringProfile)
            model.monitor.setUsesEnergySaverInLowPowerMode(model.settings.usesEnergySaverInLowPowerMode)
        case .historyRetention:
            model.monitor.setRetention(model.settings.historyRetention)
            // Shorter retention drops the long-range tiers; don't leave a chart on a range with no data.
            let clamped = ChartRange.clamped(model.settings.dashboardRange, to: model.settings.historyRetention)
            if clamped != model.settings.dashboardRange {
                model.settings.dashboardRange = clamped
            }
        case .notifications:
            break
        }
    }

    /// `kill`, `pkill`, and some installers send SIGTERM, which would otherwise end the process
    /// without AppKit's termination path. Route it (and SIGINT) through `NSApp.terminate` so
    /// history is saved.
    private func installTerminationSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    NSApp.terminate(nil)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening RamLume again from Finder or Spotlight shows the dashboard.
        model?.openDashboard()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.monitor.prepareForTermination()
        pressureObserver?.stop()
        systemEvents.stop()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu actions

    @objc func showAbout(_ sender: Any?) {
        model?.showAbout()
    }

    @objc func showSettings(_ sender: Any?) {
        model?.openSettings()
    }

    @objc func showDashboard(_ sender: Any?) {
        model?.openDashboard()
    }

    @objc func showMetricsGuide(_ sender: Any?) {
        model?.showAdvanced(.definitions)
    }

    @objc func openRepository(_ sender: Any?) {
        if let url = AppInfo.repositoryURL { NSWorkspace.shared.open(url) }
    }

    @objc func reportIssue(_ sender: Any?) {
        if let url = AppInfo.issuesURL { NSWorkspace.shared.open(url) }
    }

    @objc func togglePause(_ sender: Any?) {
        model?.togglePause()
    }

    @objc func refreshProcesses(_ sender: Any?) {
        model?.monitor.refreshProcesses()
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(togglePause(_:)) {
            menuItem.title = (model?.monitor.isPausedByUser ?? false) ? "Resume Monitoring" : "Pause Monitoring"
        }
        return model != nil
    }
}

@MainActor
enum AppearanceController {
    static func apply(_ preference: AppearancePreference) {
        switch preference {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
