import Foundation

/// Display-ready memory figures.
///
/// Raw byte counts change every second, but the formatted text people see ("12.4 GB", "78%")
/// usually doesn't. Views take these formatted values instead of a raw snapshot and are compared
/// with `Equatable`, so SwiftUI skips re-rendering when nothing visible changed. Bar fractions are
/// quantized to 0.25 % for the same reason (well below one point on any bar RamLume draws).
struct MemoryFigures: Equatable {
    struct Segment: Equatable, Identifiable {
        var category: CompositionSegment.Category
        var fraction: Double
        var value: String
        var id: CompositionSegment.Category { category }
    }

    var used: String
    var total: String
    var percent: String
    var usedFraction: Double
    var segments: [Segment]
    var app: String
    var wired: String
    var compressed: String
    var compressedOriginal: String?
    var compressionRatio: String?
    var cached: String
    var free: String
    var available: String
    var savings: String?
    var swapUsed: String?
    var swapTotal: String?
    var swapEncrypted: Bool
    var kernelFreePercentage: Int?

    init(_ snapshot: MemorySnapshot, locale: Locale = .current) {
        let b = snapshot.breakdown
        func compact(_ bytes: UInt64) -> String { MemoryFormatter.string(fromBytes: bytes, style: .compact, locale: locale) }
        func quantized(_ fraction: Double) -> Double { (fraction * 400).rounded() / 400 }

        used = MemoryFormatter.string(fromBytes: b.used, locale: locale)
        total = compact(b.total)
        percent = MemoryFormatter.percent(b.usedFraction, locale: locale)
        usedFraction = quantized(b.usedFraction)
        let totalBytes = max(Double(b.total), 1)
        segments = CompositionSegment.segments(for: b).map { segment in
            Segment(category: segment.category, fraction: quantized(Double(segment.bytes) / totalBytes), value: compact(segment.bytes))
        }
        app = compact(b.app)
        wired = compact(b.wired)
        compressed = compact(b.compressed)
        compressedOriginal = b.compressedOriginal > 0 ? compact(b.compressedOriginal) : nil
        compressionRatio = b.compressionRatio.map { "\($0.formatted(.number.precision(.fractionLength(1)).locale(locale)))×" }
        cached = compact(b.cachedFiles)
        free = compact(b.free)
        available = compact(b.availableEstimate)
        savings = b.compressionSavings > 0 ? compact(b.compressionSavings) : nil
        swapUsed = snapshot.swap.map { compact($0.used) }
        swapTotal = snapshot.swap.map { compact($0.total) }
        swapEncrypted = snapshot.swap?.isEncrypted ?? false
        kernelFreePercentage = snapshot.kernelFreePercentage
    }

    /// Used fraction in 2 % steps; animations key off this so small changes don't animate.
    var animationStep: Int { Int((usedFraction * 50).rounded()) }

    var accessibilitySummary: String {
        segments.map { "\($0.category.title) \($0.value)" }.joined(separator: ", ")
    }
}
