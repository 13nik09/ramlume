import Foundation

/// Bundle information shown for application groups.
struct BundleMetadata: Sendable, Equatable {
    var displayName: String
    var bundleIdentifier: String?
}

/// Groups processes only where the metadata makes the relationship certain.
///
/// - Processes whose executables live inside the same `.app` bundle form an application group.
///   Helpers, renderers, and XPC services shipped inside a browser's bundle are grouped with the
///   browser because their code physically belongs to it, not because of a name match.
/// - Processes outside any app bundle that run the same executable form a shared-executable
///   group (for example several `com.apple.WebKit.WebContent` processes). RamLume doesn't claim
///   to know which app such processes serve.
/// - Everything else stands alone.
enum ProcessGrouper {
    /// The outermost `.app` bundle containing an executable, e.g.
    /// `/Applications/Brave Browser.app/Contents/Frameworks/…/Helper.app/Contents/MacOS/Helper`
    /// → `/Applications/Brave Browser.app`.
    static func outermostAppBundlePath(forExecutablePath path: String) -> String? {
        guard path.hasPrefix("/"), let range = path.range(of: ".app/") else { return nil }
        let bundlePath = String(path[..<range.lowerBound]) + ".app"
        // Reject degenerate paths such as "/.app".
        return (bundlePath as NSString).lastPathComponent.count > ".app".count ? bundlePath : nil
    }

    /// The innermost `.xpc` bundle containing an executable, e.g.
    /// `/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc`.
    static func serviceBundlePath(forExecutablePath path: String) -> String? {
        guard path.hasPrefix("/"), let range = path.range(of: ".xpc/", options: .backwards) else { return nil }
        let bundlePath = String(path[..<range.lowerBound]) + ".xpc"
        return (bundlePath as NSString).lastPathComponent.count > ".xpc".count ? bundlePath : nil
    }

    static func role(executablePath: String?, bundlePath: String?) -> ProcessRecord.Role {
        guard let executablePath, let bundlePath else { return .standalone }
        let mainExecutableDirectory = bundlePath + "/Contents/MacOS/"
        if executablePath.hasPrefix(mainExecutableDirectory),
           !executablePath.dropFirst(mainExecutableDirectory.count).contains("/") {
            return .application
        }
        return .helper
    }

    static func fallbackDisplayName(forBundlePath path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    static func makeGroups(from records: [ProcessRecord], bundleMetadata: [String: BundleMetadata]) -> [ProcessGroup] {
        var byBundle: [String: [ProcessRecord]] = [:]
        var byExecutable: [String: [ProcessRecord]] = [:]
        var singles: [ProcessRecord] = []

        for record in records {
            if let bundle = record.appBundlePath {
                byBundle[bundle, default: []].append(record)
            } else if let path = record.executablePath, !path.isEmpty {
                byExecutable[path, default: []].append(record)
            } else {
                singles.append(record)
            }
        }

        var groups: [ProcessGroup] = []
        groups.reserveCapacity(byBundle.count + byExecutable.count + singles.count)

        for (bundle, members) in byBundle {
            let metadata = bundleMetadata[bundle]
            groups.append(ProcessGroup(
                id: "app:" + bundle,
                kind: .application(bundlePath: bundle),
                displayName: metadata?.displayName ?? fallbackDisplayName(forBundlePath: bundle),
                bundleIdentifier: metadata?.bundleIdentifier,
                processes: sortedMembers(members)
            ))
        }

        for (path, members) in byExecutable {
            if members.count > 1, let first = members.first {
                groups.append(ProcessGroup(
                    id: "exe:" + path,
                    kind: .sharedExecutable(path: path),
                    displayName: first.name,
                    bundleIdentifier: nil,
                    processes: sortedMembers(members)
                ))
            } else {
                singles.append(contentsOf: members)
            }
        }

        for record in singles {
            groups.append(ProcessGroup(
                id: "pid:\(record.pid)",
                kind: .single,
                displayName: record.name,
                bundleIdentifier: nil,
                processes: [record]
            ))
        }

        return groups.sorted(by: isOrderedBefore)
    }

    /// Accessible groups by footprint (largest first); fully restricted groups last, by name.
    static func isOrderedBefore(_ a: ProcessGroup, _ b: ProcessGroup) -> Bool {
        if a.isFullyRestricted != b.isFullyRestricted { return !a.isFullyRestricted }
        if a.totalFootprint != b.totalFootprint { return a.totalFootprint > b.totalFootprint }
        return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
    }

    private static func sortedMembers(_ members: [ProcessRecord]) -> [ProcessRecord] {
        members.sorted { lhs, rhs in
            switch (lhs.footprint, rhs.footprint) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.pid < rhs.pid
            }
        }
    }
}
