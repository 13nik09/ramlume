import SwiftUI

/// Explains every figure: where it comes from, the formula, and whether it's measured or
/// estimated — with the live values and raw kernel counters alongside.
struct MetricsGuideView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let snapshot = app.monitor.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DashboardCard("In plain English", subtitle: "What the words in RamLume mean") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 20, alignment: .top)], alignment: .leading, spacing: 16) {
                        ForEach(MemoryTerm.allCases) { term in
                            TermExplanation(term: term)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                ReadingTheSignsCard()

                DashboardCard("How RamLume measures memory") {
                    Text("RamLume reads statistics directly from the macOS kernel (`host_statistics64`, `sysctl`) without running command-line tools, administrator privileges, or private frameworks. Values marked ≈ are estimates. Activity Monitor's Memory Used, Cached Files, and Memory Pressure graph use Apple's own unpublished calculations, so RamLume's estimates can differ slightly from them.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DashboardCard("Figures and formulas", subtitle: "Every category below is counted once; together they add up to installed memory") {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 10) {
                        GridRow {
                            header("Figure")
                            header("Formula and source")
                            header("Now")
                            header("Kind")
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(rows(snapshot)) { row in
                            GridRow {
                                Text(row.name).fontWeight(.medium)
                                Text(row.formula)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(row.value).monospacedDigit()
                                ProvenanceTag(provenance: row.provenance)
                            }
                        }
                    }
                }

                if let snapshot {
                    KernelStatisticsCard(snapshot: snapshot, pressure: app.monitor.pressure.level)
                }

                DashboardCard("Checking the numbers yourself") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Compare RamLume with the system's own tools in Terminal:")
                            .foregroundStyle(.secondary)
                        Text("vm_stat\nsysctl vm.swapusage kern.memorystatus_vm_pressure_level\nmemory_pressure\n\"\(Bundle.main.executablePath ?? "RamLume.app/Contents/MacOS/RamLume")\" --dump-metrics")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        Text("Note that `vm_stat` prints \"Pages free\" without speculative pages, exactly as RamLume's Free figure does.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
        }
    }

    struct Row: Identifiable {
        var name: String
        var formula: String
        var value: String
        var provenance: Provenance
        var id: String { name }
    }

    private func rows(_ snapshot: MemorySnapshot?) -> [Row] {
        let b = snapshot?.breakdown
        func format(_ value: UInt64?) -> String { value.map { MemoryFormatter.string(fromBytes: $0) } ?? "—" }
        return [
            Row(name: "Installed", formula: "hw.memsize", value: format(b?.total), provenance: .measured),
            Row(name: "Reserved", formula: "hw.memsize − hw.memsize_usable", value: format(b?.reserved), provenance: .derived),
            Row(name: "Wired", formula: "wire_count × page size", value: format(b?.wired), provenance: .measured),
            Row(name: "Compressed", formula: "compressor_page_count × page size", value: format(b?.compressed), provenance: .measured),
            Row(name: "App", formula: "(internal_page_count − purgeable_count) × page size", value: format(b?.app), provenance: .derived),
            Row(name: "Cached files", formula: "(external_page_count + purgeable_count) × page size", value: format(b?.cachedFiles), provenance: .estimated),
            Row(name: "Free", formula: "(free_count − speculative_count) × page size", value: format(b?.free), provenance: .derived),
            Row(name: "Used", formula: "App + Wired + Compressed + Reserved (everything except cached and free)", value: format(b?.used), provenance: .estimated),
            Row(name: "Compressed data", formula: "total_uncompressed_pages_in_compressor × page size (not added to totals)", value: format(b?.compressedOriginal), provenance: .measured),
            Row(name: "Swap used", formula: "vm.swapusage → xsu_used", value: format(snapshot?.swap?.used), provenance: .measured),
            Row(name: "Pressure level", formula: Self.pressureSource(app.monitor.pressure), value: app.monitor.pressure.level?.displayName ?? "—", provenance: .measured),
            Row(name: "Health", formula: "Rules combining pressure level and swap activity (see Insights)", value: app.monitor.health.state.title, provenance: .heuristic),
        ]
    }

    /// Where the current level came from, so the fallback is visible rather than silent.
    static func pressureSource(_ pressure: PressureState) -> String {
        switch pressure.source {
        case .kernelLevel?:
            "kern.memorystatus_vm_pressure_level, checked on every sample and on each dispatch memory-pressure event"
        case .systemEvent?:
            "Dispatch memory-pressure events only (the kernel level isn't readable on this Mac)"
        case nil:
            "Not reported by macOS yet"
        }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

private struct KernelStatisticsCard: View {
    var snapshot: MemorySnapshot
    var pressure: MemoryPressureLevel?

    var body: some View {
        let s = snapshot.statistics
        let p = s.pages
        let c = s.counters
        let activity = snapshot.activity
        DashboardCard("Kernel statistics", subtitle: "Raw values from host_statistics64, page size \(s.pageSize) bytes") {
            AdaptiveRow(threshold: 700) {
                pageCounts(p)
                counters(c, activity: activity, pageSize: s.pageSize)
            }
        }
    }

    private func pageCounts(_ p: VMPageCounts) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow { columnHeader("Page counts"); columnHeader("Pages") }
            row("Free (incl. speculative)", p.free)
            row("Speculative", p.speculative)
            row("Active", p.active)
            row("Inactive", p.inactive)
            row("Wired", p.wired)
            row("Throttled", p.throttled)
            row("Purgeable", p.purgeable)
            row("File-backed (external)", p.fileBacked)
            row("Anonymous (internal)", p.anonymous)
            row("Occupied by compressor", p.compressorOccupied)
            row("Stored in compressor", p.compressorStored)
        }
    }

    private func counters(_ c: VMCounters, activity: MemoryActivity?, pageSize: UInt64) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow { columnHeader("Since boot"); columnHeader("Pages"); columnHeader("Now") }
            counterRow("Page-ins", c.pageIns, rate: activity.map { MemoryFormatter.rate(bytesPerSecond: $0.pageInRate) })
            counterRow("Page-outs", c.pageOuts, rate: activity.map { MemoryFormatter.rate(bytesPerSecond: $0.pageOutRate) })
            counterRow("Swap-ins", c.swapIns, rate: activity.map { MemoryFormatter.rate(bytesPerSecond: $0.swapInRate) })
            counterRow("Swap-outs", c.swapOuts, rate: activity.map { MemoryFormatter.rate(bytesPerSecond: $0.swapOutRate) })
            counterRow("Compressions", c.compressions, rate: activity.map { "\(Int($0.compressionRate.rounded()))/s" })
            counterRow("Decompressions", c.decompressions, rate: activity.map { "\(Int($0.decompressionRate.rounded()))/s" })
            counterRow("Faults", c.faults, rate: activity.map { "\(Int($0.faultRate.rounded()))/s" })
            counterRow("Copy-on-write faults", c.copyOnWriteFaults, rate: nil)
            counterRow("Zero-filled", c.zeroFilled, rate: nil)
            counterRow("Reactivations", c.reactivations, rate: nil)
            counterRow("Purged", c.purges, rate: nil)
        }
    }

    private func columnHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func row(_ label: String, _ value: UInt64) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(MemoryFormatter.count(value)).monospacedDigit().gridColumnAlignment(.trailing)
        }
        .font(.callout)
    }

    private func counterRow(_ label: String, _ value: UInt64, rate: String?) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(MemoryFormatter.count(value)).monospacedDigit().gridColumnAlignment(.trailing)
            Text(rate ?? "—").monospacedDigit().foregroundStyle(.secondary).gridColumnAlignment(.trailing)
        }
        .font(.callout)
    }
}
