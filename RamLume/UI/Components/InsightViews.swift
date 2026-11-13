import SwiftUI

/// One insight. Information and suggestions are visually quieter than warnings.
struct InsightRow: View {
    var insight: Insight
    var showsEvidence = false
    var lineLimit: Int?

    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: insight.kind.symbolName)
                .foregroundStyle(Palette.insight(insight.kind))
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(insight.title)
                    .font(.callout.weight(.semibold))
                Text(insight.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(lineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                if let recommendation = insight.recommendation {
                    Text(recommendation)
                        .font(.callout)
                        .lineLimit(lineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if showsEvidence, !insight.evidence.isEmpty {
                    DisclosureGroup(isExpanded: $isExpanded) {
                        EvidenceList(items: insight.evidence)
                            .padding(.top, 4)
                    } label: {
                        Text("Why am I seeing this?")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(insight.kind.label): \(insight.title)")
    }
}

/// Facts behind an assessment, each labelled with how it was obtained.
struct EvidenceList: View {
    var items: [EvidenceItem]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(items) { item in
                GridRow {
                    Text(item.label)
                        .foregroundStyle(.secondary)
                    Text(item.value)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                    ProvenanceTag(provenance: item.provenance)
                }
                .font(.caption)
            }
        }
    }
}

struct ProvenanceTag: View {
    var provenance: Provenance

    var body: some View {
        Text(provenance.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .help(help)
    }

    private var help: String {
        switch provenance {
        case .measured: "Reported directly by macOS."
        case .derived: "Arithmetic on values reported by macOS."
        case .estimated: "An approximation; macOS doesn't report this value directly."
        case .heuristic: "A judgement made by RamLume's rules."
        }
    }
}

/// The largest accessible process groups.
struct TopAppsList: View {
    var snapshot: ProcessSnapshot?
    var totalMemory: UInt64
    var limit = 4
    var iconSize: CGFloat = 18

    var body: some View {
        if let snapshot {
            let groups = Array(snapshot.accessibleGroups.prefix(limit))
            if groups.isEmpty {
                Text("No processes could be measured.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 7) {
                    ForEach(groups) { group in
                        TopAppRow(group: group, totalMemory: totalMemory, iconSize: iconSize)
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Scanning processes…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct TopAppRow: View {
    var group: ProcessGroup
    var totalMemory: UInt64
    var iconSize: CGFloat = 18

    var body: some View {
        let share = MemoryUnits.clampedFraction(group.totalFootprint, of: totalMemory)
        HStack(spacing: 8) {
            ProcessIcon(path: group.representativePath, size: iconSize)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(group.displayName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if group.processes.count > 1 {
                        Text("\(group.processes.count)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .help(MemoryFormatter.processCount(group.processes.count))
                    }
                    Spacer(minLength: 8)
                    Text(MemoryFormatter.string(fromBytes: group.totalFootprint))
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.track)
                        Capsule().fill(Palette.app.opacity(0.75))
                            .frame(width: max(geometry.size.width * share, 2))
                    }
                }
                .frame(height: 3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.displayName), \(MemoryFormatter.string(fromBytes: group.totalFootprint)), \(MemoryFormatter.processCount(group.processes.count)), \(MemoryFormatter.percent(share)) of memory")
        .help("\(group.displayName): physical footprint summed over \(MemoryFormatter.processCount(group.accessibleCount))")
    }
}
