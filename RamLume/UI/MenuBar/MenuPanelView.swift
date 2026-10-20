import SwiftUI

/// The panel shown from the menu bar item.
struct MenuPanelView: View {
    @Environment(AppModel.self) private var app
    /// Height of the content; the scroll view matches it until the screen runs out of room.
    @State private var contentHeight: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader()
            Divider()
            // One copy of the content (`ViewThatFits` would build and update two). It only
            // scrolls on displays too short to show everything.
            ScrollView {
                PanelContent()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, maxContentHeight))
            Divider()
            PanelFooter()
        }
        .frame(width: Metrics.panelWidth)
    }

    /// Keeps the panel within the screen on small displays; content scrolls beyond this.
    private var maxContentHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        return max(screenHeight - 140, 320)
    }
}

private struct PanelHeader: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            Text(AppInfo.name)
                .font(.headline)
            Spacer()
            HealthBadge(state: app.monitor.health.state, compact: true)
            Menu {
                Button("Open Dashboard") { app.openDashboard() }
                Button("Settings…") { app.openSettings() }
                Divider()
                Button(app.monitor.isPausedByUser ? "Resume Monitoring" : "Pause Monitoring") { app.togglePause() }
                Divider()
                Button("About RamLume") { app.showAbout() }
                Button("Quit RamLume") { app.quit() }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings and actions")
            .accessibilityLabel("Settings and actions")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct PanelContent: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let monitor = app.monitor
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            if !app.settings.hasShownWelcome {
                WelcomeCard()
            }
            if monitor.isPausedByUser {
                PausedNote()
            }
            if let snapshot = monitor.snapshot {
                HealthSummaryView(
                    summary: HealthSummary(assessment: monitor.health, figures: MemoryFigures(snapshot), pressure: monitor.pressure.level),
                    compact: true
                )
                .equatable()
                .card(.panel)
                TopAppsSection()
                RecommendationSection()
            } else {
                UnavailableCard(error: monitor.readError)
            }
        }
        .padding(14)
    }
}

/// A short, skippable introduction on first launch.
private struct WelcomeCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Welcome to RamLume", systemImage: "hand.wave.fill")
                .font(.headline)
                .labelStyle(.titleAndIcon)
            VStack(alignment: .leading, spacing: 7) {
                point("memorychip", "RamLume watches your Mac's memory and shows which apps use the most.")
                point("chart.bar.fill", "High RAM use is normal: macOS keeps memory busy so things open faster.")
                point("gauge.with.dots.needle.33percent", "Memory pressure shows how hard your Mac is working to make room. That's the number that matters.")
                point("lightbulb", "When something would help, you'll find it under Recommendations.")
            }
            HStack {
                Spacer()
                Button("Got It") { app.settings.hasShownWelcome = true }
                    .controlSize(.small)
            }
        }
        .card(.panel)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PausedNote: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Monitoring is paused. Values below are from \(lastUpdate).")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Resume") { app.togglePause() }
                .controlSize(.small)
        }
        .card(.panel)
    }

    private var lastUpdate: String {
        app.monitor.snapshot?.timestamp.formatted(date: .omitted, time: .shortened) ?? "earlier"
    }
}

private struct UnavailableCard: View {
    var error: MemoryReadError?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error {
                Label("Memory statistics unavailable", systemImage: "exclamationmark.triangle")
                    .font(.callout.weight(.semibold))
                Text(error.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("RamLume will keep trying. No values are shown rather than guessing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Taking the first measurement…", systemImage: "hourglass")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .card(.panel)
    }
}

private struct TopAppsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let monitor = app.monitor
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeading(title: "Top apps")
                Button("See All") { app.openDashboard(.applications) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            TopAppsList(snapshot: monitor.processes, totalMemory: monitor.current.snapshot?.breakdown.total ?? 0, limit: 3)
        }
    }
}

private struct RecommendationSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let recommendations = app.monitor.recommendations
        if let first = recommendations.first {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeading(title: "Recommendation")
                RecommendationSummaryView(
                    recommendation: first,
                    moreCount: recommendations.dropFirst().filter { $0.priority == .tip }.count
                ) {
                    app.openDashboard(.recommendations)
                }
            }
        }
    }
}

private struct PanelFooter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack {
            Button {
                app.openDashboard()
            } label: {
                Label("Open Dashboard", systemImage: "macwindow")
            }
            .keyboardShortcut("d", modifiers: .command)
            Spacer()
            Button {
                app.openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
