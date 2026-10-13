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

    static var isLowPowerModeEnabled: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func start(_ handlers: Handlers) {
        stop()
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { handlers.willSleep() }
        observe(workspace, NSWorkspace.didWakeNotification) { handlers.didWake() }
        observe(workspace, NSWorkspace.willPowerOffNotification) { handlers.willPowerOff() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { handlers.screensAsleepChanged(true) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { handlers.screensAsleepChanged(false) }
        // Fast user switching: nobody can see this session's menu bar while it's inactive.
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { handlers.screensAsleepChanged(true) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { handlers.screensAsleepChanged(false) }
        observe(.default, Notification.Name.NSProcessInfoPowerStateDidChange) {
            handlers.lowPowerModeChanged(Self.isLowPowerModeEnabled)
        }
    }

    func stop() {
        for (center, token) in tokens {
            center.removeObserver(token)
        }
        tokens = []
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        tokens.append((center, token))
    }
}
