import SwiftUI

/// A row in the process outline: a group (with children) or a single process.
struct ProcessTableRow: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let pid: Int32?
    let footprint: UInt64?
    let peakFootprint: UInt64?
    let processCount: Int
    let restrictedCount: Int
    let userName: String?
    let iconPath: String?
    let executablePath: String?
    let bundleIdentifier: String?
    let isGroup: Bool
    let roleDescription: String
    var children: [ProcessTableRow]?

    var footprintSortKey: UInt64 { footprint ?? 0 }
    var shareSortKey: UInt64 { footprint ?? 0 }
    var pidSortKey: Int32 { pid ?? (children?.compactMap(\.pid).min() ?? -1) }
    var userSortKey: String { userName ?? "" }
    var searchText: String {
        [name, executablePath ?? "", bundleIdentifier ?? "", pid.map { String($0) } ?? ""].joined(separator: " ")
    }

    static func rows(from snapshot: ProcessSnapshot, showsRestricted: Bool, query: String) -> [ProcessTableRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshot.groups.compactMap { group -> ProcessTableRow? in
            let members = group.processes.filter { showsRestricted || $0.isAccessible }
            guard !members.isEmpty else { return nil }
            let childRows = members.map(Self.processRow)
            let groupMatches = trimmed.isEmpty || group.displayName.localizedCaseInsensitiveContains(trimmed)
                || (group.bundleIdentifier?.localizedCaseInsensitiveContains(trimmed) ?? false)
            let matchingChildren = groupMatches ? childRows : childRows.filter { $0.searchText.localizedCaseInsensitiveContains(trimmed) }
            guard groupMatches || !matchingChildren.isEmpty else { return nil }

            if group.processes.count == 1, let only = childRows.first {
                var row = only
                row = ProcessTableRow(
                    id: group.id, name: group.displayName, pid: only.pid, footprint: only.footprint,
                    peakFootprint: only.peakFootprint, processCount: 1, restrictedCount: only.restrictedCount,
                    userName: only.userName, iconPath: group.representativePath, executablePath: only.executablePath,
                    bundleIdentifier: group.bundleIdentifier, isGroup: false, roleDescription: only.roleDescription, children: nil
                )
                return row
            }
            let accessible = members.compactMap(\.footprint)
            return ProcessTableRow(
                id: group.id,
                name: group.displayName,
                pid: nil,
                footprint: accessible.isEmpty ? nil : MemoryUnits.saturatingSum(accessible),
                peakFootprint: nil,
                processCount: members.count,
                restrictedCount: members.count - accessible.count,
                userName: Set(members.compactMap(\.userName)).count == 1 ? members.first?.userName : nil,
                iconPath: group.representativePath,
                executablePath: group.bundlePath ?? members.first?.executablePath,
                bundleIdentifier: group.bundleIdentifier,
                isGroup: true,
                roleDescription: Self.groupDescription(group.kind),
                children: matchingChildren
            )
        }
    }

    private static func processRow(_ process: ProcessRecord) -> ProcessTableRow {
        ProcessTableRow(
            id: "pid:\(process.pid)",
            name: process.name,
            pid: process.pid,
            footprint: process.footprint,
            peakFootprint: process.peakFootprint,
            processCount: 1,
            restrictedCount: process.isAccessible ? 0 : 1,
            userName: process.userName,
            iconPath: process.role == .application ? process.appBundlePath : process.executablePath,
            executablePath: process.executablePath,
            bundleIdentifier: nil,
            isGroup: false,
            roleDescription: {
                switch process.role {
                case .application: "Application"
                case .helper: "Helper inside an app bundle"
                case .standalone: "Process"
                }
            }(),
            children: nil
        )
    }

    private static func groupDescription(_ kind: ProcessGroup.Kind) -> String {
        switch kind {
        case .application: "Application and its helpers (same app bundle)"
        case .sharedExecutable: "Several processes running the same program"
        case .single: "Process"
        }
    }

    static func sorted(_ rows: [ProcessTableRow], using comparators: [KeyPathComparator<ProcessTableRow>]) -> [ProcessTableRow] {
        rows.sorted(using: comparators).map { row in
            var row = row
            if let children = row.children {
                row.children = children.sorted(using: comparators)
            }
            return row
        }
    }

    static func find(_ id: String?, in rows: [ProcessTableRow]) -> ProcessTableRow? {
        guard let id else { return nil }
        for row in rows {
            if row.id == id { return row }
            if let match = find(id, in: row.children ?? []) { return match }
        }
        return nil
    }
}

struct ProcessesView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var selection: ProcessTableRow.ID?
    @State private var sortOrder = [KeyPathComparator(\ProcessTableRow.footprintSortKey, order: .reverse)]
    @State private var showsInspector = true

    var body: some View {
        @Bindable var settings = app.settings
        let monitor = app.monitor
        let totalMemory = monitor.snapshot?.breakdown.total ?? 0
        Group {
            if let snapshot = monitor.processes {
                let rows = ProcessTableRow.sorted(
                    ProcessTableRow.rows(from: snapshot, showsRestricted: settings.showsRestrictedProcesses, query: query),
                    using: sortOrder
                )
                VStack(spacing: 0) {
                    ProcessTable(rows: rows, totalMemory: totalMemory, selection: $selection, sortOrder: $sortOrder)
                    Divider()
                    ProcessFooter(snapshot: snapshot)
                }
                .inspector(isPresented: $showsInspector) {
                    ProcessInspector(row: ProcessTableRow.find(selection, in: rows), totalMemory: totalMemory)
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
                }
            } else {
                ProgressView("Scanning processes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search processes")
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $settings.showsRestrictedProcesses) {
                    Label("Show Restricted", systemImage: "lock")
                }
                .help("Show processes whose memory macOS doesn't let RamLume read")
            }
            ToolbarItem {
                Button {
                    monitor.refreshProcesses()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(monitor.isScanningProcesses)
                .help("Refresh the process list (⌘R)")
            }
            ToolbarItem {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Details", systemImage: "sidebar.trailing")
                }
                .help("Show or hide process details")
            }
        }
    }
}

private struct ProcessTable: View {
    var rows: [ProcessTableRow]
    var totalMemory: UInt64
    @Binding var selection: ProcessTableRow.ID?
    @Binding var sortOrder: [KeyPathComparator<ProcessTableRow>]

    var body: some View {
        Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { row in
                HStack(spacing: 6) {
                    ProcessIcon(path: row.iconPath, size: 16)
                    Text(row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if row.isGroup {
                        Text("\(row.processCount)")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                            .accessibilityLabel("\(row.processCount) processes")
                    }
                }
                .help(row.executablePath ?? row.name)
            }
            .width(min: 200, ideal: 320)

            TableColumn("Memory", value: \.footprintSortKey) { row in
                MemoryCell(row: row)
            }
            .width(min: 90, ideal: 110)

            TableColumn("% of RAM", value: \.shareSortKey) { row in
                if let footprint = row.footprint, totalMemory > 0 {
                    Text(MemoryFormatter.percent(Double(footprint) / Double(totalMemory)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .width(min: 60, ideal: 70)

            TableColumn("PID", value: \.pidSortKey) { row in
                Text(row.pid.map { String($0) } ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 50, ideal: 64)

            TableColumn("User", value: \.userSortKey) { row in
                Text(row.userName ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)
        }
    }
}

private struct MemoryCell: View {
    var row: ProcessTableRow

    var body: some View {
        if let footprint = row.footprint {
            HStack(spacing: 3) {
                Text(MemoryFormatter.string(fromBytes: footprint))
                    .monospacedDigit()
                if row.restrictedCount > 0 {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("\(row.restrictedCount) of these processes can't be measured, so the total is incomplete.")
                        .accessibilityLabel("\(row.restrictedCount) restricted, total incomplete")
                }
            }
        } else {
            Label("Restricted", systemImage: "lock.fill")
                .labelStyle(.titleAndIcon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("macOS doesn't let apps without administrator privileges read memory details for processes owned by the system or other users. RamLume doesn't request those privileges.")
        }
    }
}

/// One line, so its height never depends on the width it's given. (Wrapping text here fed back
/// into the split views' layout and caused a constraint-update loop.)
private struct ProcessFooter: View {
    var snapshot: ProcessSnapshot

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(snapshot.accessibleCount) of \(snapshot.totalCount) processes measured · \(snapshot.restrictedCount) restricted · Memory is physical footprint, as in Activity Monitor")
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text("Updated \(snapshot.timestamp.formatted(date: .omitted, time: .standard))")
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .help("Restricted processes are owned by macOS or other users; reading their memory requires administrator privileges, which RamLume doesn't request. Memory is each process's physical footprint, the same metric as Activity Monitor's Memory column. Group totals add up their processes and may count shared memory more than once.")
        .accessibilityElement(children: .combine)
    }
}

private struct ProcessInspector: View {
    var row: ProcessTableRow?
    var totalMemory: UInt64

    var body: some View {
        if let row {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        ProcessIcon(path: row.iconPath, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                                .font(.headline)
                                .lineLimit(2)
                            Text(row.roleDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        detail("Memory", row.footprint.map { MemoryFormatter.string(fromBytes: $0) } ?? "Restricted")
                        if let footprint = row.footprint, totalMemory > 0 {
                            detail("Share of RAM", MemoryFormatter.percent(Double(footprint) / Double(totalMemory)))
                        }
                        if let peak = row.peakFootprint {
                            detail("Peak footprint", MemoryFormatter.string(fromBytes: peak))
                        }
                        if row.isGroup {
                            detail("Processes", "\(row.processCount)")
                            if row.restrictedCount > 0 {
                                detail("Restricted", "\(row.restrictedCount)")
                            }
                        }
                        if let pid = row.pid {
                            detail("PID", "\(pid)")
                        }
                        if let user = row.userName {
                            detail("User", user)
                        }
                        if let bundleIdentifier = row.bundleIdentifier {
                            detail("Bundle ID", bundleIdentifier)
                        }
                    }
                    if let path = row.executablePath {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Location")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(path)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                            .controlSize(.small)
                        }
                    }
                    Text(row.isGroup
                         ? "Grouped because every process runs code from the same app bundle. The total is the sum of each process's physical footprint."
                         : "Physical footprint is the memory macOS attributes to this process, including compressed memory. It's the same metric as Activity Monitor's Memory column.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "cursorarrow.click", description: Text("Select a process or app to see its details."))
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}
