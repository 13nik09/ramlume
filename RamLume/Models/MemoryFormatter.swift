import Foundation

/// Formats byte counts, rates, and percentages consistently across the app.
enum MemoryFormatter {
    enum Style: Sendable {
        /// Up to two fractional digits, e.g. "11.82 GB", "512.3 MB".
        case standard
        /// Shorter output for tight spaces, e.g. "11.8 GB", "512 MB".
        case compact
    }

    static func string(fromBytes bytes: UInt64, style: Style = .standard, locale: Locale = .current) -> String {
        string(fromBytes: Double(bytes), style: style, locale: locale)
    }

    static func string(fromBytes bytes: Double, style: Style = .standard, locale: Locale = .current) -> String {
        let value = bytes.isFinite ? max(bytes, 0) : 0
        let mebibytes = value / Double(MemoryUnits.mebibyte)
        let kibibytes = value / Double(MemoryUnits.kibibyte)

        // Switch to gigabytes from 1,000 MB so values never read "1,014 MB". Each unit is chosen
        // from the rounded value, so 999.7 MB doesn't read "1,000 MB" either.
        if mebibytes.rounded() >= 1_000 {
            let gibibytes = value / Double(MemoryUnits.gibibyte)
            var digits: Int
            switch style {
            case .standard: digits = gibibytes >= 100 ? 0 : (gibibytes >= 10 ? 1 : 2)
            case .compact: digits = gibibytes >= 10 ? 0 : 1
            }
            // Compact values drop a trailing ".0" ("2 GB", not "2.0 GB").
            if style == .compact, digits == 1, (gibibytes * 10).rounded() == (gibibytes.rounded() * 10) {
                digits = 0
            }
            return "\(number(gibibytes, fractionDigits: digits, locale: locale)) GB"
        }
        if kibibytes.rounded() >= 1_024 {
            let digits = (style == .compact || mebibytes >= 100) ? 0 : 1
            return "\(number(mebibytes, fractionDigits: digits, locale: locale)) MB"
        }
        return "\(number(kibibytes, fractionDigits: 0, locale: locale)) KB"
    }

    /// "11.8/16 GB" — used/total for the menu bar, sharing one unit when possible.
    static func usedOfTotal(used: UInt64, total: UInt64, locale: Locale = .current) -> String {
        let usedGB = Double(used) / Double(MemoryUnits.gibibyte)
        let totalGB = Double(total) / Double(MemoryUnits.gibibyte)
        let totalDigits = totalGB.rounded() == totalGB ? 0 : 1
        let usedText = number(usedGB, fractionDigits: usedGB >= 100 ? 0 : 1, locale: locale)
        let totalText = number(totalGB, fractionDigits: totalDigits, locale: locale)
        return "\(usedText)/\(totalText) GB"
    }

    /// Throughput such as "12.4 MB/s". Values below 1 KB/s read "0 KB/s".
    static func rate(bytesPerSecond: Double, locale: Locale = .current) -> String {
        "\(string(fromBytes: bytesPerSecond, style: .compact, locale: locale))/s"
    }

    /// "74%" from a 0...1 fraction.
    static func percent(_ fraction: Double, locale: Locale = .current) -> String {
        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        return clamped.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// A share that is never rounded to a misleading "0%" or "100%": "<1%" and ">99%" at the edges.
    static func share(_ fraction: Double, locale: Locale = .current) -> String {
        guard fraction.isFinite else { return percent(0, locale: locale) }
        if fraction > 0, fraction < 0.01 { return "<" + percent(0.01, locale: locale) }
        if fraction < 1, fraction > 0.99 { return ">" + percent(0.99, locale: locale) }
        return percent(fraction, locale: locale)
    }

    /// "+1.2 GB" / "−300 MB" / "No change".
    static func signedChange(bytes: Int64, locale: Locale = .current) -> String {
        if bytes == 0 { return "No change" }
        let magnitude = string(fromBytes: Double(bytes.magnitude), style: .compact, locale: locale)
        return bytes > 0 ? "+\(magnitude)" : "−\(magnitude)"
    }

    /// Compact duration such as "45 s", "12 min", "1 h 5 min".
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = Int(max(interval, 0).rounded())
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) h" : "\(hours) h \(remainder) min"
    }

    /// "1 process", "12 processes".
    static func processCount(_ count: Int) -> String {
        count == 1 ? "1 process" : "\(count) processes"
    }

    /// Large page counts with grouping separators, e.g. "1,048,576".
    static func count(_ value: UInt64, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale))
    }

    private static func number(_ value: Double, fractionDigits: Int, locale: Locale) -> String {
        NumberFormatterCache.shared.formatter(fractionDigits: fractionDigits, locale: locale)
            .string(from: NSNumber(value: value)) ?? String(value)
    }
}

/// Reuses configured `NumberFormatter`s; formatting runs many times per second while a window
/// is open, and creating a formatter each time is comparatively expensive.
///
/// `NumberFormatter` is thread-safe for formatting once configured, and the cache itself is
/// guarded by a lock.
final class NumberFormatterCache: @unchecked Sendable {
    static let shared = NumberFormatterCache()

    private struct Key: Hashable {
        var fractionDigits: Int
        var localeIdentifier: String
    }

    private let lock = NSLock()
    private var formatters: [Key: NumberFormatter] = [:]

    func formatter(fractionDigits: Int, locale: Locale) -> NumberFormatter {
        let key = Key(fractionDigits: fractionDigits, localeIdentifier: locale.identifier)
        lock.lock()
        defer { lock.unlock() }
        if let existing = formatters[key] { return existing }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        formatter.roundingMode = .halfEven
        formatters[key] = formatter
        return formatter
    }
}
