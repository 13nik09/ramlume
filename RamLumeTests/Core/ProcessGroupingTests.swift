import Foundation
import Testing
@testable import RamLume

@Suite("Process grouping")
struct ProcessGroupingTests {
    @Test func findsOutermostAppBundle() {
        #expect(ProcessGrouper.outermostAppBundlePath(forExecutablePath: Fixtures.braveRenderer) == "/Applications/Brave Browser.app")
        #expect(ProcessGrouper.outermostAppBundlePath(forExecutablePath: Fixtures.braveMain) == "/Applications/Brave Browser.app")
        #expect(ProcessGrouper.outermostAppBundlePath(forExecutablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder") == "/System/Library/CoreServices/Finder.app")
        #expect(ProcessGrouper.outermostAppBundlePath(forExecutablePath: "/private/var/folders/x/T/AppTranslocation/ABC/d/Tool.app/Contents/MacOS/Tool") == "/private/var/folders/x/T/AppTranslocation/ABC/d/Tool.app")
    }

    @Test func rejectsPathsOutsideAppBundles() {
        #expect(ProcessGrouper.outermostAppBundlePath(forExecutablePath: Fixtures.webContent) == nil)
        #expect(ProcessGrouper.outermostAppBundlePath(forExecutablePath: "/usr/libexec/trustd") == nil)
        #expect(ProcessGrouper.outermostAppBundlePath(forExecutablePath: "/.app/Contents/MacOS/x") == nil)
        #expect(ProcessGrouper.outermostAppBundlePath(forExecutablePath: "relative/Foo.app/Contents/MacOS/Foo") == nil)
        // A name that merely contains "Brave" isn't evidence of belonging to Brave.
        #expect(ProcessGrouper.outermostAppBundlePath(forExecutablePath: "/usr/local/bin/brave-helper") == nil)
    }

    @Test func findsServiceBundles() {
        let vm = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
        #expect(ProcessGrouper.serviceBundlePath(forExecutablePath: vm) == "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc")
        #expect(ProcessGrouper.serviceBundlePath(forExecutablePath: "/usr/libexec/trustd") == nil)
    }

    @Test func classifiesRoles() {
        let bundle = "/Applications/Brave Browser.app"
        #expect(ProcessGrouper.role(executablePath: Fixtures.braveMain, bundlePath: bundle) == .application)
        #expect(ProcessGrouper.role(executablePath: Fixtures.braveRenderer, bundlePath: bundle) == .helper)
        #expect(ProcessGrouper.role(executablePath: "/usr/libexec/trustd", bundlePath: nil) == .standalone)
    }

    @Test func groupsHelpersWithTheirApp() throws {
        let snapshot = Fixtures.braveSnapshot()
        let brave = try #require(snapshot.groups.first)
        #expect(brave.displayName == "Brave Browser")
        #expect(brave.bundleIdentifier == "com.brave.Browser")
        #expect(brave.processes.count == 4)
        #expect(brave.totalFootprint == 4_000 * Fixtures.mib)
        // Members are sorted largest first.
        #expect(brave.processes.first?.footprint == 1_800 * Fixtures.mib)
    }

    @Test func sharedExecutablesAreGroupedWithoutClaimingAnOwner() throws {
        let records = (0..<3).map { Fixtures.process(pid: 300 + Int32($0), path: Fixtures.webContent, footprint: 100 * Fixtures.mib) }
            + [Fixtures.process(pid: 400, path: "/usr/libexec/trustd", footprint: 10 * Fixtures.mib)]
        let snapshot = Fixtures.processSnapshot(records: records)
        let webKit = try #require(snapshot.groups.first { $0.processes.count == 3 })
        #expect(webKit.kind == .sharedExecutable(path: Fixtures.webContent))
        #expect(webKit.bundleIdentifier == nil)
        // A plain name that doesn't claim Safari (or any app) as the owner.
        #expect(webKit.displayName == "Web pages (WebKit)")
        let single = try #require(snapshot.groups.first { $0.id == "pid:400" })
        #expect(single.kind == .single)
    }

    // Scenario: missing or inaccessible process statistics.
    @Test func restrictedProcessesAreKeptButNeverGivenFakeValues() throws {
        let records = [
            Fixtures.process(pid: 1, path: "/sbin/launchd", footprint: nil),
            Fixtures.process(pid: 50, path: "/usr/sbin/WindowServer", footprint: nil),
            Fixtures.process(pid: 500, path: "/Applications/Notes.app/Contents/MacOS/Notes", footprint: 90 * Fixtures.mib),
        ]
        let snapshot = Fixtures.processSnapshot(records: records, bundleMetadata: [:])
        #expect(snapshot.restrictedCount == 2)
        #expect(snapshot.accessibleCount == 1)
        #expect(snapshot.accessibleGroups.count == 1)
        // Fully restricted groups sort last and report no footprint.
        let last = try #require(snapshot.groups.last)
        #expect(last.isFullyRestricted)
        #expect(last.totalFootprint == 0)
        #expect(last.processes.allSatisfy { $0.footprint == nil && !$0.isAccessible })
        // Without bundle metadata the name falls back to the bundle's file name.
        #expect(snapshot.groups.first?.displayName == "Notes")
    }

    @Test func partiallyRestrictedGroupSumsOnlyMeasuredMembers() throws {
        let records = [
            Fixtures.process(pid: 10, path: Fixtures.braveMain, footprint: 500 * Fixtures.mib),
            Fixtures.process(pid: 11, path: Fixtures.braveRenderer, footprint: nil),
        ]
        let group = try #require(Fixtures.processSnapshot(records: records).groups.first)
        #expect(group.totalFootprint == 500 * Fixtures.mib)
        #expect(group.restrictedCount == 1)
        #expect(!group.isFullyRestricted)
    }

    @Test func emptyScanIsHandled() {
        let snapshot = Fixtures.processSnapshot(records: [])
        #expect(snapshot.groups.isEmpty)
        #expect(snapshot.largestAccessibleGroup == nil)
        #expect(snapshot.totalAccessibleFootprint == 0)
    }
}
