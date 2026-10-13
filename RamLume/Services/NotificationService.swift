import Foundation
import Observation
import UserNotifications

/// Delivers RamLume's optional notifications through `UserNotifications`.
///
/// Permission is requested only when the user turns notifications on in Settings.
@MainActor
@Observable
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    enum Authorization: Sendable, Equatable {
        case unknown
        case notDetermined
        case denied
        case authorized
    }

    private(set) var authorization: Authorization = .unknown

    /// Called when the user clicks a RamLume notification.
    @ObservationIgnored var onOpen: (() -> Void)?

    @ObservationIgnored private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        authorization = Self.map(settings.authorizationStatus)
    }

    /// Asks for permission if needed. Returns whether notifications can be delivered.
    func requestAuthorization() async -> Bool {
        await refreshAuthorization()
        if authorization == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            await refreshAuthorization()
        }
        return authorization == .authorized
    }

    func deliver(_ alerts: [AlertCandidate]) {
        guard !alerts.isEmpty else { return }
        Task {
            // Permission may have changed in System Settings since it was last checked.
            await refreshAuthorization()
            guard authorization == .authorized else { return }
            post(alerts)
        }
    }

    /// Posts a clearly labelled sample notification. Returns whether macOS accepted it.
    func sendTestNotification() async -> Bool {
        await refreshAuthorization()
        guard authorization == .authorized else { return false }
        let content = UNMutableNotificationContent()
        content.title = "RamLume notifications are working"
        content.body = "This is a test. RamLume notifies you only about the conditions you choose in Settings."
        content.threadIdentifier = "test"
        let request = UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    private func post(_ alerts: [AlertCandidate]) {
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.threadIdentifier = alert.kind.rawValue
            if alert.kind == .criticalPressure {
                content.sound = .default
            }
            let request = UNNotificationRequest(identifier: "\(alert.key)-\(UUID().uuidString)", content: content, trigger: nil)
            center.add(request)
        }
    }

    private static func map(_ status: UNAuthorizationStatus) -> Authorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional: .authorized
        @unknown default: .unknown
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await handleOpen()
    }

    private func handleOpen() {
        onOpen?()
    }
}
