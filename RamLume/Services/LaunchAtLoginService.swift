import Foundation
import Observation
import ServiceManagement

/// Launch at login via `SMAppService.mainApp` (macOS 13+). The system is the source of truth:
/// the user can also change this in System Settings › General › Login Items.
@MainActor
@Observable
final class LaunchAtLoginService {
    enum State: Sendable, Equatable {
        case enabled
        case disabled
        /// Registered, but the user must approve it in System Settings.
        case requiresApproval
    }

    private(set) var state: State = .disabled
    private(set) var lastError: String?

    /// macOS registers the app at its current location, so a copy that later moves (or one
    /// started from Downloads or a disk image) wouldn't open at login reliably.
    let isInApplicationsFolder: Bool

    init(bundleURL: URL = Bundle.main.bundleURL) {
        isInApplicationsFolder = Self.isInApplicationsFolder(bundleURL)
        refresh()
    }

    var isEnabled: Bool { state == .enabled || state == .requiresApproval }

    func refresh() {
        state = Self.map(SMAppService.mainApp.status)
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func map(_ status: SMAppService.Status) -> State {
        switch status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        // `.notFound` is what macOS reports for an app that has never been registered; it isn't
        // an error. Registration failures are reported by `register()` itself.
        case .notRegistered, .notFound: .disabled
        @unknown default: .disabled
        }
    }

    static func isInApplicationsFolder(_ bundleURL: URL) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        let folders = ["/Applications/", NSHomeDirectory() + "/Applications/"]
        return folders.contains { path.hasPrefix($0) }
    }
}
