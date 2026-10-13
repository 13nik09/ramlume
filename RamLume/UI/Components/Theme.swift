import AppKit
import SwiftUI

/// Colors used for data. Series hues come from a validated categorical palette (separate
/// light and dark steps; checked for color-vision-deficiency separation in both modes), and
/// health colors from a reserved status scale that is never reused for a series.
enum Palette {
    // Categorical, in validated order: App → Wired → Compressed are adjacent in stacks.
    static let app = dynamic(light: 0x2A78D6, dark: 0x3987E5)        // blue
    static let wired = dynamic(light: 0x1BAF7A, dark: 0x199E70)      // aqua
    static let compressed = dynamic(light: 0x4A3AA7, dark: 0x9085E9) // violet
    static let swap = dynamic(light: 0xE87BA4, dark: 0xD55181)       // magenta (own charts)

    /// Neutral for cached files: real memory, but readily reclaimable.
    static let cached = Color.secondary.opacity(0.45)
    /// Darker neutral for hardware-reserved/unaccounted memory.
    static let reserved = Color.secondary.opacity(0.75)
    /// Track for free memory.
    static let track = Color.primary.opacity(0.07)

    // Status scale (fixed in both modes). Always shown with an icon and a label.
    static let good = Color(nsColor: NSColor(srgbHex: 0x0CA30C))
    static let warning = Color(nsColor: NSColor(srgbHex: 0xFAB219))
    static let serious = Color(nsColor: NSColor(srgbHex: 0xEC835A))
    static let critical = Color(nsColor: NSColor(srgbHex: 0xD03B3B))
    static let unknown = Color(nsColor: NSColor(srgbHex: 0x898781))

    static func health(_ state: HealthState) -> Color {
        switch state {
        case .healthy: good
        case .elevated: warning
        case .underPressure: serious
        case .critical: critical
        case .insufficientData: unknown
        }
    }

    static func pressure(_ level: MemoryPressureLevel?) -> Color {
        switch level {
        case .normal?: good
        case .warning?: warning
        case .critical?: critical
        case nil: unknown
        }
    }

    static func insight(_ kind: Insight.Kind) -> Color {
        switch kind {
        case .info: unknown
        case .suggestion: Color.accentColor
        case .warning: serious
        case .critical: critical
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(srgbHex: dark)
                : NSColor(srgbHex: light)
        })
    }
}

extension NSColor {
    convenience init(srgbHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// Spacing and shape tokens.
enum Metrics {
    static let panelWidth: CGFloat = 360
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 12
    static let sectionSpacing: CGFloat = 12
    static let barGap: CGFloat = 2
}

/// Where a card is drawn: on the popover's material or on an opaque window background.
enum CardContext {
    case panel
    case window
}

struct CardBackground: ViewModifier {
    var context: CardContext
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(context == .panel ? AnyShapeStyle(Color.primary.opacity(0.045)) : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))
                    .overlay {
                        RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(context == .panel ? 0.06 : 0.08), lineWidth: 0.5)
                    }
            }
    }
}

extension View {
    func card(_ context: CardContext = .window, padding: CGFloat = Metrics.cardPadding) -> some View {
        modifier(CardBackground(context: context, padding: padding))
    }
}

/// Small uppercase section heading used in the panel.
struct SectionHeading: View {
    var title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
