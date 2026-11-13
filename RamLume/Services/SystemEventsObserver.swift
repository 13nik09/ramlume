import AppKit

/// Forwards sleep/wake, display sleep, and Low Power Mode changes. Event-driven; no polling.
@MainActor
final class SystemEventsObserver {
    struct Handlers {
        var willSleep: () -> Void
        var didWake: () -> Void
        /// Logout, restart, or shutdown is about to happen.
        var willPowerOff: () -> Void
        var screensAsleepChanged: (Bool) -> Void
        var lowPowerModeChanged: (Bool) -> Void
    }

    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private let workspaceCenter: NotificationCenter
    /// The two reasons nobody can see this session's menu bar. They change independently: the
    /// displays can sleep and wake while another user's session is in front.
    private var displaysAsleep = false
    private var sessionInactive = false

    init(workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.workspaceCenter = workspaceCenter
    }

    static var isLowPowerModeEnabled: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func start(_ handlers: Handlers) {
        stop()
        let workspace = workspaceCenter
        observe(workspace, NSWorkspace.willSleepNotification) { _ in handlers.willSleep() }
        observe(workspace, NSWorkspace.didWakeNotification) { _ in handlers.didWake() }
        observe(workspace, NSWorkspace.willPowerOffNotification) { _ in handlers.willPowerOff() }
        func report(_ observer: SystemEventsObserver) {
            handlers.screensAsleepChanged(observer.displaysAsleep || observer.sessionInactive)
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysAsleep = true; report($0) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysAsleep = false; report($0) }
        // Fast user switching: nobody can see this session's menu bar while it's inactive.
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true; report($0) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false; report($0) }
        observe(.default, Notification.Name.NSProcessInfoPowerStateDidChange) { _ in
            handlers.lowPowerModeChanged(Self.isLowPowerModeEnabled)
        }
    }

    func stop() {
        for (center, token) in tokens {
            center.removeObserver(token)
        }
        tokens = []
        displaysAsleep = false
        sessionInactive = false
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (SystemEventsObserver) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        tokens.append((center, token))
    }
}
