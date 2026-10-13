import SwiftUI
import UniformTypeIdentifiers

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        let launch = app.launchAtLogin
        Form {
            Section {
                Toggle("Open RamLume at login", isOn: Binding(
                    get: { launch.isEnabled },
                    set: { launch.setEnabled($0) }
                ))
                if launch.state == .requiresApproval {
                    LabeledContent {
                        Button("Open Login Items…") { launch.openSystemSettings() }
                    } label: {
                        Text("macOS needs your approval in System Settings › General › Login Items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !launch.isInApplicationsFolder {
                    Text("Move RamLume to your Applications folder first. macOS opens it at login from where it is now, so a copy in Downloads or on a disk image won't open reliably.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = launch.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Menu bar") {
                Picker("Show", selection: $settings.menuBarStyle) {
                    ForEach(MenuBarDisplayStyle.allCases) { style in
                        Text(style.example.isEmpty ? style.title : "\(style.title) (\(style.example))").tag(style)
                    }
                }
                Toggle("Tint the icon when memory needs attention", isOn: $settings.tintsMenuBarIcon)
                Text("The icon turns orange or red only when RamLume's health assessment is Under pressure or Critical — never because of the usage percentage alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppearancePreference.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct MonitoringSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Picker("Monitoring mode", selection: $settings.monitoringProfile) {
                    ForEach(MonitoringProfile.allCases) { profile in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.title)
                            Text(description(for: profile))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(profile)
                    }
                }
                .pickerStyle(.radioGroup)
                Toggle("Use Energy Saver while Low Power Mode is on", isOn: $settings.usesEnergySaverInLowPowerMode)
            } footer: {
                Text("While the displays are asleep RamLume samples every 30–60 seconds. Pressure changes reported by macOS are still recorded immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Pause monitoring", isOn: Binding(
                    get: { app.monitor.isPausedByUser },
                    set: { app.monitor.setPaused($0) }
                ))
            } footer: {
                Text("While paused, RamLume stops sampling entirely. History shows the pause as a gap.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func description(for profile: MonitoringProfile) -> String {
        let table = SamplingScheduler.intervals(for: profile)
        return "Every \(MemoryFormatter.duration(table.visibleMemory)) while a window is open, \(MemoryFormatter.duration(table.backgroundMemory)) in the background; processes every \(MemoryFormatter.duration(table.visibleProcesses)) / \(MemoryFormatter.duration(table.backgroundProcesses))."
    }
}

struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var testResult: String?

    var body: some View {
        @Bindable var settings = app.settings
        Form {
            Section {
                Toggle("Allow notifications", isOn: Binding(
                    get: { settings.notificationsEnabled },
                    set: { enabled in Task { await app.setNotificationsEnabled(enabled) } }
                ))
                if app.notifications.authorization == .denied || app.notificationPermissionDenied {
                    LabeledContent {
                        Button("Open Notification Settings…") { openNotificationSettings() }
                    } label: {
                        Text("Notifications for RamLume are turned off in System Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent {
                    Button("Send Test Notification") {
                        Task {
                            let sent = await app.sendTestNotification()
                            testResult = sent ? "Sent. If it didn't appear, check Focus and Notification settings." : "macOS didn't accept the notification. Check that notifications for RamLume are allowed in System Settings."
                        }
                    }
                    .disabled(!settings.notificationsEnabled)
                } label: {
                    Text(testResult ?? "Check that notifications reach you.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Off until you turn it on. RamLume never notifies you just because memory usage is high.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notify me about") {
                Toggle(isOn: $settings.notifiesCriticalPressure) {
                    labelled("Critical memory pressure", "When macOS reports critical pressure. At most every 15 minutes.")
                }
                Toggle(isOn: $settings.notifiesSustainedPressure) {
                    labelled("Sustained memory pressure", "Elevated pressure for 5 minutes or more while your Mac is swapping. At most hourly.")
                }
                Toggle(isOn: $settings.notifiesRapidSwapGrowth) {
                    labelled("Rapid swap growth", "Swap use grows by 2 GB or more within 15 minutes. At most hourly.")
                }
                Toggle(isOn: $settings.notifiesAppMemoryGrowth) {
                    labelled("Steady app memory growth", "An app's memory grows by 1 GB+ steadily for 20 minutes or more. Can be normal for some apps. At most every 6 hours per app.")
                }
            }
            .disabled(!settings.notificationsEnabled)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func labelled(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func openNotificationSettings() {
        let identifier = AppInfo.bundleIdentifier
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(identifier)",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}

struct HistorySettingsView: View {
    @Environment(AppModel.self) private var app
    @State private var confirmingClear = false
    @State private var fileSize: UInt64?

    var body: some View {
        @Bindable var settings = app.settings
        let store = app.monitor.history
        Form {
            Section {
                Picker("Keep history for", selection: $settings.historyRetention) {
                    ForEach(HistoryRetention.allCases) { retention in
                        Text(retention.title).tag(retention)
                    }
                }
                Text("Older data is aggregated (10-second, 1-minute, and 5-minute averages with peaks) so the file stays small.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("History file") {
                    Text(fileSize.map { MemoryFormatter.string(fromBytes: $0, style: .compact) } ?? "Not saved yet")
                        .monospacedDigit()
                }
                if let url = store.fileURL {
                    LabeledContent("Location") {
                        Button("Show in Finder") {
                            let target = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
                            NSWorkspace.shared.activateFileViewerSelecting([target])
                        }
                    }
                }
                if let problem = store.loadProblem {
                    Text("A previous history file couldn't be read and was set aside: \(problem)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("History stays on this Mac. It contains memory statistics and event descriptions only — no app or process names.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Clear History…", role: .destructive) { confirmingClear = true }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { fileSize = store.storedFileSize() }
        .confirmationDialog("Clear all memory history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) {
                app.monitor.clearHistory()
                fileSize = nil
            }
        } message: {
            Text("Charts and the event timeline will start over. This can't be undone.")
        }
    }
}

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(AppInfo.name)
                .font(.title.weight(.semibold))
            Text("Version \(AppInfo.version) (\(AppInfo.build))")
                .foregroundStyle(.secondary)
            Text(AppInfo.tagline)
                .font(.title3)
            VStack(spacing: 6) {
                Text("Free and open source under the MIT License.")
                Text("RamLume runs entirely on your Mac. It makes no network requests and has no analytics, accounts, or cloud services.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)

            if let repositoryURL = AppInfo.repositoryURL {
                HStack(spacing: 16) {
                    Link("View on GitHub", destination: repositoryURL)
                    if let issuesURL = AppInfo.issuesURL {
                        Link("Report an Issue", destination: issuesURL)
                    }
                }
            } else {
                Text("GitHub repository: link coming soon")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            Text("Built with Apple frameworks only — no third-party dependencies. This build is not notarized unless stated in its release notes.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }
}
