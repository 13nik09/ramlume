import Foundation
import Observation

/// User preferences, persisted in `UserDefaults`.
///
/// Launch at login is deliberately not stored here: `SMAppService` is the source of truth and
/// the user can change it in System Settings at any time.
@MainActor
@Observable
final class SettingsStore {
    /// Settings that other components react to.
    enum Change: Sendable, Equatable {
        case menuBar
        case appearance
        case monitoring
        case historyRetention
        case notifications
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// Called after a setting that affects behaviour changes.
    @ObservationIgnored var onChange: ((Change) -> Void)?

    var menuBarStyle: MenuBarDisplayStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: Key.menuBarStyle); onChange?(.menuBar) }
    }

    /// Tint the menu bar icon amber/red when memory needs attention.
    var tintsMenuBarIcon: Bool {
        didSet { defaults.set(tintsMenuBarIcon, forKey: Key.tintsMenuBarIcon); onChange?(.menuBar) }
    }

    var appearance: AppearancePreference {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance); onChange?(.appearance) }
    }

    var monitoringProfile: MonitoringProfile {
        didSet { defaults.set(monitoringProfile.rawValue, forKey: Key.monitoringProfile); onChange?(.monitoring) }
    }

    var usesEnergySaverInLowPowerMode: Bool {
        didSet { defaults.set(usesEnergySaverInLowPowerMode, forKey: Key.usesEnergySaverInLowPowerMode); onChange?(.monitoring) }
    }

    var historyRetention: HistoryRetention {
        didSet { defaults.set(historyRetention.rawValue, forKey: Key.historyRetention); onChange?(.historyRetention) }
    }

    /// Master switch; off until the user opts in.
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled); onChange?(.notifications) }
    }

    var notifiesCriticalPressure: Bool {
        didSet { defaults.set(notifiesCriticalPressure, forKey: Key.notifiesCriticalPressure); onChange?(.notifications) }
    }

    var notifiesSustainedPressure: Bool {
        didSet { defaults.set(notifiesSustainedPressure, forKey: Key.notifiesSustainedPressure); onChange?(.notifications) }
    }

    var notifiesRapidSwapGrowth: Bool {
        didSet { defaults.set(notifiesRapidSwapGrowth, forKey: Key.notifiesRapidSwapGrowth); onChange?(.notifications) }
    }

    var notifiesAppMemoryGrowth: Bool {
        didSet { defaults.set(notifiesAppMemoryGrowth, forKey: Key.notifiesAppMemoryGrowth); onChange?(.notifications) }
    }

    var showsRestrictedProcesses: Bool {
        didSet { defaults.set(showsRestrictedProcesses, forKey: Key.showsRestrictedProcesses) }
    }

    var dashboardRange: ChartRange {
        didSet { defaults.set(dashboardRange.rawValue, forKey: Key.dashboardRange) }
    }

    var hasShownWelcome: Bool {
        didSet { defaults.set(hasShownWelcome, forKey: Key.hasShownWelcome) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBarStyle = Self.enumValue(defaults, Key.menuBarStyle, fallback: .percentage)
        tintsMenuBarIcon = Self.boolValue(defaults, Key.tintsMenuBarIcon, fallback: true)
        appearance = Self.enumValue(defaults, Key.appearance, fallback: .system)
        monitoringProfile = Self.enumValue(defaults, Key.monitoringProfile, fallback: .balanced)
        usesEnergySaverInLowPowerMode = Self.boolValue(defaults, Key.usesEnergySaverInLowPowerMode, fallback: true)
        historyRetention = Self.enumValue(defaults, Key.historyRetention, fallback: .oneDay)
        notificationsEnabled = Self.boolValue(defaults, Key.notificationsEnabled, fallback: false)
        notifiesCriticalPressure = Self.boolValue(defaults, Key.notifiesCriticalPressure, fallback: true)
        notifiesSustainedPressure = Self.boolValue(defaults, Key.notifiesSustainedPressure, fallback: true)
        notifiesRapidSwapGrowth = Self.boolValue(defaults, Key.notifiesRapidSwapGrowth, fallback: true)
        notifiesAppMemoryGrowth = Self.boolValue(defaults, Key.notifiesAppMemoryGrowth, fallback: false)
        showsRestrictedProcesses = Self.boolValue(defaults, Key.showsRestrictedProcesses, fallback: false)
        dashboardRange = Self.enumValue(defaults, Key.dashboardRange, fallback: .fifteenMinutes)
        hasShownWelcome = Self.boolValue(defaults, Key.hasShownWelcome, fallback: false)
    }

    var notificationPreferences: NotificationPreferences {
        NotificationPreferences(
            isEnabled: notificationsEnabled,
            criticalPressure: notifiesCriticalPressure,
            sustainedPressure: notifiesSustainedPressure,
            rapidSwapGrowth: notifiesRapidSwapGrowth,
            appMemoryGrowth: notifiesAppMemoryGrowth
        )
    }

    private enum Key {
        static let menuBarStyle = "menuBarStyle"
        static let tintsMenuBarIcon = "tintsMenuBarIcon"
        static let appearance = "appearance"
        static let monitoringProfile = "monitoringProfile"
        static let usesEnergySaverInLowPowerMode = "usesEnergySaverInLowPowerMode"
        static let historyRetention = "historyRetention"
        static let notificationsEnabled = "notificationsEnabled"
        static let notifiesCriticalPressure = "notifiesCriticalPressure"
        static let notifiesSustainedPressure = "notifiesSustainedPressure"
        static let notifiesRapidSwapGrowth = "notifiesRapidSwapGrowth"
        static let notifiesAppMemoryGrowth = "notifiesAppMemoryGrowth"
        static let showsRestrictedProcesses = "showsRestrictedProcesses"
        static let dashboardRange = "dashboardRange"
        static let hasShownWelcome = "hasShownWelcome"
    }

    private static func enumValue<T: RawRepresentable>(_ defaults: UserDefaults, _ key: String, fallback: T) -> T where T.RawValue == String {
        guard let raw = defaults.string(forKey: key), let value = T(rawValue: raw) else { return fallback }
        return value
    }

    private static func boolValue(_ defaults: UserDefaults, _ key: String, fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
}
