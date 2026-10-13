import Foundation

/// What the status item shows next to its icon.
enum MenuBarDisplayStyle: String, Sendable, Codable, CaseIterable, Identifiable {
    case iconOnly
    case percentage
    case usedOfTotal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iconOnly: "Icon only"
        case .percentage: "Icon and percentage"
        case .usedOfTotal: "Icon and used/total"
        }
    }

    var example: String {
        switch self {
        case .iconOnly: ""
        case .percentage: "62%"
        case .usedOfTotal: "9.9/16 GB"
        }
    }
}

/// How often RamLume samples. See `SamplingScheduler` for the exact intervals.
enum MonitoringProfile: String, Sendable, Codable, CaseIterable, Identifiable {
    case responsive
    case balanced
    case energySaver

    var id: String { rawValue }

    var title: String {
        switch self {
        case .responsive: "Responsive"
        case .balanced: "Balanced"
        case .energySaver: "Energy Saver"
        }
    }
}

/// How much history RamLume keeps on disk.
enum HistoryRetention: String, Sendable, Codable, CaseIterable, Identifiable {
    case oneHour
    case oneDay
    case sevenDays

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .oneHour: 3_600
        case .oneDay: 86_400
        case .sevenDays: 604_800
        }
    }

    var title: String {
        switch self {
        case .oneHour: "1 hour"
        case .oneDay: "24 hours"
        case .sevenDays: "7 days"
        }
    }
}

enum AppearancePreference: String, Sendable, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

/// Time ranges offered by the charts.
enum ChartRange: String, Sendable, Codable, CaseIterable, Identifiable {
    case fiveMinutes
    case fifteenMinutes
    case oneHour
    case oneDay
    case sevenDays

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .fiveMinutes: 300
        case .fifteenMinutes: 900
        case .oneHour: 3_600
        case .oneDay: 86_400
        case .sevenDays: 604_800
        }
    }

    var shortTitle: String {
        switch self {
        case .fiveMinutes: "5m"
        case .fifteenMinutes: "15m"
        case .oneHour: "1h"
        case .oneDay: "24h"
        case .sevenDays: "7d"
        }
    }

    var accessibilityTitle: String {
        switch self {
        case .fiveMinutes: "Last 5 minutes"
        case .fifteenMinutes: "Last 15 minutes"
        case .oneHour: "Last hour"
        case .oneDay: "Last 24 hours"
        case .sevenDays: "Last 7 days"
        }
    }

    /// Ranges that make sense for a retention setting.
    static func available(for retention: HistoryRetention) -> [ChartRange] {
        allCases.filter { $0.duration <= max(retention.duration, ChartRange.fifteenMinutes.duration) }
    }

    /// `range` if the retention setting keeps enough history for it, otherwise the longest range it does.
    static func clamped(_ range: ChartRange, to retention: HistoryRetention) -> ChartRange {
        let available = available(for: retention)
        return available.contains(range) ? range : (available.last ?? .fifteenMinutes)
    }
}
