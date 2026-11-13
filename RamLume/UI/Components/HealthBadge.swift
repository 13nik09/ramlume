import SwiftUI

/// Health state as icon + label (never color alone).
struct HealthBadge: View {
    var state: HealthState
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: state.symbolName)
                .foregroundStyle(Palette.health(state))
                .imageScale(.small)
            Text(state.title)
                .font(compact ? .caption.weight(.medium) : .callout.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, compact ? 7 : 9)
        .padding(.vertical, compact ? 3 : 4)
        .background(Palette.health(state).opacity(0.14), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Memory health: \(state.title)")
        .help("RamLume's assessment, based on the pressure level macOS reports and recent swap activity. Not Apple's Memory Pressure graph.")
    }
}

/// Marks a value's provenance. Estimates carry a visible "≈" so they're never mistaken for
/// direct readings.
struct ProvenanceMark: View {
    var provenance: Provenance

    var body: some View {
        switch provenance {
        case .estimated, .heuristic:
            Text("≈")
                .foregroundStyle(.secondary)
                .accessibilityLabel(provenance.label)
        case .measured, .derived:
            EmptyView()
        }
    }
}
