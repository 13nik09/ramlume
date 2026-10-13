import SwiftUI

/// A labelled figure: label · value · optional caption. Estimates show a "≈" mark.
struct StatTile: View {
    var label: String
    var value: String
    var caption: String?
    var provenance: Provenance = .measured
    var swatch: Color?
    var help: String?
    var context: CardContext = .panel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if let swatch {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(swatch)
                        .frame(width: 7, height: 7)
                }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                ProvenanceMark(provenance: provenance)
                Text(value)
                    .font(.system(.body, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(context, padding: 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .help(help ?? "")
    }

    private var accessibilityText: String {
        var parts = [label, (provenance == .estimated ? "approximately " : "") + value]
        if let caption { parts.append(caption) }
        return parts.joined(separator: ", ")
    }
}

/// Loads and caches app icons for process groups, on the main actor.
@MainActor
final class IconCache {
    static let shared = IconCache()
    private var icons: [String: NSImage] = [:]
    private let limit = 256

    func icon(forPath path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        if let cached = icons[path] { return cached }
        if icons.count >= limit { icons.removeAll() }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = NSSize(width: 32, height: 32)
        icons[path] = image
        return image
    }

    /// Frees cached icons, e.g. when macOS reports memory pressure.
    func purge() {
        icons.removeAll()
    }
}

struct ProcessIcon: View {
    var path: String?
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let image = IconCache.shared.icon(forPath: path) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "gearshape")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
