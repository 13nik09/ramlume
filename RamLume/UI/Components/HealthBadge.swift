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

/// The kernel-reported pressure level as icon + label.
struct PressureLabel: View {
    var level: MemoryPressureLevel?

    var body: some View {
        Label {
            Text(level?.displayName ?? "Not reported")
        } icon: {
            Circle()
                .fill(Palette.pressure(level))
                .frame(width: 8, height: 8)
        }
        .labelStyle(.titleAndIcon)
        .accessibilityLabel("macOS memory pressure: \(level?.displayName ?? "not reported")")
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
