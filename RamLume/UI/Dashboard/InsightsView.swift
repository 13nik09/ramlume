import SwiftUI

struct InsightsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let monitor = app.monitor
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HealthDetailCard(assessment: monitor.health)

                DashboardCard("Insights", subtitle: "Plain-English explanations generated from your Mac's measurements") {
                    if monitor.insights.isEmpty {
                        Text(monitor.snapshot == nil ? "Insights appear once RamLume has measurements." : "Nothing to report right now.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(monitor.insights.enumerated()), id: \.element.id) { index, insight in
                                if index > 0 { Divider() }
                                InsightRow(insight: insight, showsEvidence: true)
                            }
                        }
                    }
                }

                DashboardCard("How RamLume reads the signs") {
                    VStack(alignment: .leading, spacing: 8) {
                        principle("High usage alone isn't a problem.", "macOS deliberately keeps memory busy with apps and file caches. A Mac using 12 GB of 16 GB with normal pressure is working as designed.")
                        principle("Memory pressure comes from macOS.", "RamLume shows the pressure level macOS reports (normal, warning, critical). Its own health rating adds recent swap activity and is labelled as an assessment.")
                        principle("Compression is normal.", "Compressing inactive memory is faster than swapping. RamLume only treats it as a concern when swapping and pressure rise with it.")
                        principle("Allocated swap isn't always active swapping.", "macOS can keep swapped-out data after a busy period. RamLume looks at how much is being written right now.")
                        principle("No restart advice for normal swap.", "Restarting to clear swap is rarely useful; RamLume won't suggest it.")
                    }
                }
            }
            .padding(20)
        }
    }

    private func principle(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct EventsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let events = app.monitor.history.events.elements.reversed()
        let days = Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.date) }
        let sortedDays = days.keys.sorted(by: >)
        Group {
            if events.isEmpty {
                ContentUnavailableView("No Events Yet", systemImage: "clock", description: Text("Pressure changes, sleep and wake, and other notable moments will appear here."))
            } else {
                List {
                    ForEach(sortedDays, id: \.self) { day in
                        Section(day.formatted(date: .complete, time: .omitted)) {
                            ForEach(days[day] ?? []) { event in
                                EventRow(event: event)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct EventRow: View {
    var event: MemoryEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: event.kind.symbolName)
                .foregroundStyle(color)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                if let detail = event.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(event.date.formatted(date: .omitted, time: .standard))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        if let pressure = event.pressure { return Palette.pressure(pressure) }
        if let health = event.health { return Palette.health(health) }
        return .secondary
    }
}
