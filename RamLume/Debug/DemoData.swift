#if DEBUG
import Darwin
import Foundation

/// Example data for README screenshots, enabled with the `--demo` launch argument.
///
/// This file is compiled only into Debug builds, so example values can never appear in the
/// shipping app. Demo mode doesn't read or write the history file and never sends notifications.
///
/// The numbers follow a plausible day on a 16 GB Mac: a calm present with high but normal usage,
/// a busy stretch about two hours earlier (warning pressure and some swapping), and a night's
/// sleep, shown as a gap. Every figure is derived through the same code paths as real readings.
enum DemoData {
    static let pageSize: UInt64 = 16_384
    static let physicalMemory: UInt64 = 16 * MemoryUnits.gibibyte
    /// 632 MB reserved by hardware and firmware, as on a real 16 GB Apple silicon Mac.
    static let usableMemory: UInt64 = 16_516_775_936

    private static let gib = Double(MemoryUnits.gibibyte)
    private static let mib = Double(MemoryUnits.mebibyte)

    // Times relative to the moment demo mode started, in seconds.
    static let sleepStart: TimeInterval = -11 * 3_600
    static let sleepEnd: TimeInterval = -(4 * 3_600 + 20 * 60)
    static let busyStart: TimeInterval = -(2 * 3_600 + 25 * 60)
    static let warningStart: TimeInterval = -(2 * 3_600 + 5 * 60)
    static let swapGrowth: TimeInterval = -(2 * 3_600 + 1 * 60)
    static let warningEnd: TimeInterval = -(1 * 3_600 + 53 * 60)

    struct Reading {
        var app: Double
        var wired: Double
        var compressed: Double
        var compressionRatio: Double
        var swapUsed: Double
        var swapTotal: Double
        var pressure: MemoryPressureLevel
        /// Bytes per second.
        var swapOutRate: Double
        var swapInRate: Double
        var pageInRate: Double
    }

    /// The example machine's state `t` seconds after (negative: before) demo mode started.
    static func reading(at t: TimeInterval) -> Reading {
        func wave(_ period: Double, _ phase: Double = 0) -> Double { sin(2 * .pi * (t / period + phase)) }

        // 0 while calm, 1 during the busy stretch, easing back as apps are closed.
        let busy: Double
        if t < busyStart {
            busy = 0
        } else if t < warningStart {
            busy = (t - busyStart) / (warningStart - busyStart)
        } else if t < warningEnd {
            busy = 1
        } else {
            busy = exp(-(t - warningEnd) / 900)
        }
        // Compressed memory is released more slowly than apps' memory.
        let compressedExtra: Double
        if t < busyStart {
            compressedExtra = 0
        } else if t < warningEnd {
            compressedExtra = min(1, (t - busyStart) / (warningStart - busyStart))
        } else {
            compressedExtra = exp(-(t - warningEnd) / 2_400)
        }

        let swapTotal = t < swapGrowth ? 1 * gib : 2 * gib
        let swapUsed: Double
        if t < busyStart {
            swapUsed = 0.32 * gib
        } else if t < warningEnd {
            swapUsed = 0.32 * gib + 1.05 * gib * min(1, (t - busyStart) / (warningEnd - busyStart))
        } else {
            swapUsed = 1.1 * gib + 0.27 * gib * exp(-(t - warningEnd) / 1_800)
        }

        let swapping = t >= busyStart && t < warningEnd
        return Reading(
            app: (7.9 + 0.22 * wave(5_400) + 0.1 * wave(1_300, 0.3) + 0.03 * wave(170, 0.7)) * gib + busy * 1.2 * gib,
            wired: (2.12 + 0.05 * wave(3_100, 0.2)) * gib + busy * 0.15 * gib,
            compressed: (1.42 + 0.05 * wave(2_300, 0.5)) * gib + compressedExtra * 1.8 * gib,
            compressionRatio: 2.45 + 0.1 * wave(4_000),
            swapUsed: min(swapUsed, swapTotal * 0.97),
            swapTotal: swapTotal,
            pressure: t >= warningStart && t < warningEnd ? .warning : .normal,
            swapOutRate: swapping ? 0.55 * mib * (1 + 0.5 * wave(90)) : 2_000,
            swapInRate: swapping ? 0.12 * mib : (t >= warningEnd && t < warningEnd + 1_800 ? 0.2 * mib : 20_000),
            pageInRate: (1.4 + 0.4 * wave(600)) * mib
        )
    }

    /// Page counts that partition `usableMemory` exactly, as the kernel's do.
    static func pages(for reading: Reading) -> VMPageCounts {
        func pages(_ bytes: Double) -> UInt64 { UInt64(max(bytes, 0) / Double(pageSize)) }
        let usablePages = usableMemory / pageSize
        let wired = pages(reading.wired)
        let compressor = pages(reading.compressed)
        let app = pages(reading.app)
        let inUse = wired + compressor + app
        let remaining = usablePages > inUse ? usablePages - inUse : 0
        let free = min(max(remaining * 15 / 100, 5_000), remaining)
        let cached = remaining - free
        let purgeable = min(2_800, app, cached)
        let speculative = min(1_500, cached)
        let anonymous = app + purgeable
        let fileBacked = cached - purgeable
        // active + inactive + speculative == internal + external, as XNU reports them.
        let queued = anonymous + fileBacked - speculative
        let active = queued * 56 / 100
        return VMPageCounts(
            free: free + speculative, active: active, inactive: queued - active, speculative: speculative,
            throttled: 0, wired: wired, purgeable: purgeable, fileBacked: fileBacked, anonymous: anonymous,
            compressorOccupied: compressor, compressorStored: UInt64(Double(compressor) * reading.compressionRatio)
        )
    }

    static func statistics(at t: TimeInterval, timestamp: Date, uptime: TimeInterval) -> MemoryStatistics {
        func counter(_ base: UInt64, _ perSecond: Double) -> UInt64 { base + UInt64(perSecond * max(uptime, 0)) }
        return MemoryStatistics(
            timestamp: timestamp,
            uptime: uptime,
            pageSize: pageSize,
            physicalMemory: physicalMemory,
            usableMemory: usableMemory,
            pages: pages(for: reading(at: t)),
            counters: VMCounters(
                pageIns: counter(4_100_000, 95), pageOuts: counter(9_800, 0.02),
                swapIns: counter(210_000, 1.1), swapOuts: counter(380_000, 0.12),
                compressions: counter(31_000_000, 700), decompressions: counter(26_500_000, 640),
                faults: counter(152_000_000, 5_200), copyOnWriteFaults: counter(3_900_000, 40),
                zeroFilled: counter(141_000_000, 4_800), reactivations: counter(22_000_000, 210),
                purges: counter(4_100_000, 9)
            )
        )
    }

    static func swap(at t: TimeInterval) -> SwapUsage {
        let reading = reading(at: t)
        let total = UInt64(reading.swapTotal)
        let used = UInt64(reading.swapUsed)
        return SwapUsage(total: total, used: used, available: total - min(used, total), isEncrypted: true)
    }

    // MARK: - History

    /// A day of history ending at `anchor`, built from the same readings the live demo uses.
    @MainActor
    static func makeHistory(anchor: Date, retention: HistoryRetention) -> HistoryStore {
        let store = HistoryStore(retention: retention, persistence: nil, now: anchor)
        let start = -min(retention.duration, 86_400) + 120
        func date(_ t: TimeInterval) -> Date { anchor.addingTimeInterval(t) }

        var t = start
        var previous: TimeInterval?
        var sleeping = false
        while t < 0 {
            if t >= sleepStart, t < sleepEnd {
                if !sleeping {
                    store.beginGap(at: date(t), reason: .systemSleep)
                    sleeping = true
                }
                t = sleepEnd
                previous = nil
                continue
            }
            if sleeping {
                store.endGap(at: date(t))
                sleeping = false
            }
            let reading = reading(at: t)
            let statistics = statistics(at: t, timestamp: date(t), uptime: 50_000 + t)
            // Like the real app, no rates right after a gap.
            let activity = previous.map { previous -> MemoryActivity in
                let interval = t - previous
                return MemoryActivity(
                    interval: interval,
                    swapInBytes: UInt64(reading.swapInRate * interval),
                    swapOutBytes: UInt64(reading.swapOutRate * interval),
                    pageInBytes: UInt64(reading.pageInRate * interval),
                    pageOutBytes: 0,
                    compressedPages: UInt64(700 * interval),
                    decompressedPages: UInt64(640 * interval),
                    faults: UInt64(5_200 * interval)
                )
            }
            let snapshot = MemorySnapshot(
                statistics: statistics,
                breakdown: MemoryBreakdown(statistics: statistics),
                swap: swap(at: t),
                kernelFreePercentage: 58,
                activity: activity
            )
            store.append(HistoryPoint(snapshot: snapshot, pressure: reading.pressure))
            previous = t
            // Background sampling every 5 s; the dashboard samples every second while open.
            t += t > -900 ? 1 : 5
        }

        for event in events(anchor: anchor, start: start) {
            store.record(event)
        }
        return store
    }

    /// The timeline the real coordinator would have recorded for this day.
    private static func events(anchor: Date, start: TimeInterval) -> [MemoryEvent] {
        func date(_ t: TimeInterval) -> Date { anchor.addingTimeInterval(t) }
        return [
            MemoryEvent(date: date(start), kind: .monitoringStarted, title: "Monitoring started"),
            MemoryEvent(date: date(sleepStart), kind: .systemSleep, title: "Mac went to sleep"),
            MemoryEvent(date: date(sleepEnd), kind: .systemWake, title: "Mac woke from sleep"),
            MemoryEvent(date: date(warningStart), kind: .pressureChanged, title: "Memory pressure: Warning",
                        detail: "Changed from Normal, as reported by macOS.", pressure: .warning),
            MemoryEvent(date: date(warningStart), kind: .healthChanged, title: "Health: \(HealthState.underPressure.title)",
                        detail: "Memory pressure is elevated", health: .underPressure),
            MemoryEvent(date: date(swapGrowth), kind: .swapExpanded, title: "Swap space grew to 2 GB",
                        detail: "macOS allocated more swap file space (+1 GB)."),
            MemoryEvent(date: date(warningEnd), kind: .pressureChanged, title: "Memory pressure: Normal",
                        detail: "Changed from Warning, as reported by macOS.", pressure: .normal),
            MemoryEvent(date: date(warningEnd), kind: .healthChanged, title: "Health: \(HealthState.elevated.title)",
                        detail: "Recovering from pressure", health: .elevated),
            MemoryEvent(date: date(warningEnd + 600), kind: .healthChanged, title: "Health: \(HealthState.healthy.title)",
                        detail: "Memory pressure is normal", health: .healthy),
        ]
    }

    // MARK: - Processes

    private struct DemoProcess {
        var pid: Int32
        var name: String
        var path: String?
        /// Megabytes, or `nil` for a process macOS doesn't let an unprivileged app measure.
        var megabytes: Double?
        var user: (id: UInt32, name: String) = (501, "jappleseed")
    }

    private static let root: (id: UInt32, name: String) = (0, "root")

    private static let processes: [DemoProcess] = {
        var list: [DemoProcess] = [
            DemoProcess(pid: 812, name: "Xcode", path: "/Applications/Xcode.app/Contents/MacOS/Xcode", megabytes: 2_150),
            DemoProcess(pid: 1_240, name: "SourceKitService", path: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/sourcekitd.framework/Versions/A/XPCServices/SourceKitService.xpc/Contents/MacOS/SourceKitService", megabytes: 690),
            DemoProcess(pid: 1_251, name: "XCBBuildService", path: "/Applications/Xcode.app/Contents/SharedFrameworks/XCBuild.framework/Versions/A/PlugIns/XCBBuildService.bundle/Contents/MacOS/XCBBuildService", megabytes: 245),
            DemoProcess(pid: 641, name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari", megabytes: 385),
            DemoProcess(pid: 733, name: "Photos", path: "/System/Applications/Photos.app/Contents/MacOS/Photos", megabytes: 455),
            DemoProcess(pid: 702, name: "Mail", path: "/System/Applications/Mail.app/Contents/MacOS/Mail", megabytes: 372),
            DemoProcess(pid: 715, name: "Music", path: "/System/Applications/Music.app/Contents/MacOS/Music", megabytes: 268),
            DemoProcess(pid: 744, name: "Notes", path: "/System/Applications/Notes.app/Contents/MacOS/Notes", megabytes: 164),
            DemoProcess(pid: 751, name: "Messages", path: "/System/Applications/Messages.app/Contents/MacOS/Messages", megabytes: 142),
            DemoProcess(pid: 905, name: "System Settings", path: "/System/Applications/System Settings.app/Contents/MacOS/System Settings", megabytes: 121),
            DemoProcess(pid: 760, name: "Calendar", path: "/System/Applications/Calendar.app/Contents/MacOS/Calendar", megabytes: 118),
            DemoProcess(pid: 777, name: "Preview", path: "/System/Applications/Preview.app/Contents/MacOS/Preview", megabytes: 96),
            DemoProcess(pid: 512, name: "Finder", path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", megabytes: 138),
            DemoProcess(pid: 498, name: "Dock", path: "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock", megabytes: 72),
            DemoProcess(pid: 530, name: "Spotlight", path: "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight", megabytes: 58),
            DemoProcess(pid: 541, name: "ControlCenter", path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter", megabytes: 48),
            DemoProcess(pid: 547, name: "NotificationCenter", path: "/System/Library/CoreServices/NotificationCenter.app/Contents/MacOS/NotificationCenter", megabytes: 61),
            DemoProcess(pid: 563, name: "WallpaperAgent", path: "/System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent", megabytes: 54),
            DemoProcess(pid: 1_402, name: "RamLume", path: "/Applications/RamLume.app/Contents/MacOS/RamLume", megabytes: 41),
            DemoProcess(pid: 622, name: "photoanalysisd", path: "/System/Library/PrivateFrameworks/PhotoAnalysis.framework/Versions/A/Support/photoanalysisd", megabytes: 210),
            DemoProcess(pid: 628, name: "mediaanalysisd", path: "/System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd", megabytes: 96),
            DemoProcess(pid: 590, name: "cloudd", path: "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd", megabytes: 64),
            DemoProcess(pid: 603, name: "bird", path: "/System/Library/PrivateFrameworks/iCloudDriveCore.framework/Versions/A/Support/bird", megabytes: 38),
            DemoProcess(pid: 0, name: "kernel_task", path: nil, megabytes: nil, user: root),
            DemoProcess(pid: 1, name: "launchd", path: "/sbin/launchd", megabytes: nil, user: root),
            DemoProcess(pid: 167, name: "WindowServer", path: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer", megabytes: nil, user: (88, "_windowserver")),
            DemoProcess(pid: 120, name: "mds", path: "/System/Library/Frameworks/CoreServices.framework/Frameworks/Metadata.framework/Support/mds", megabytes: nil, user: root),
            DemoProcess(pid: 140, name: "coreaudiod", path: "/usr/sbin/coreaudiod", megabytes: nil, user: (202, "_coreaudiod")),
        ]
        // Seven web content processes: shared WebKit processes that RamLume doesn't attribute to Safari.
        let webContent = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"
        for (index, megabytes) in [410.0, 296, 214, 182, 140, 96, 64].enumerated() {
            list.append(DemoProcess(pid: Int32(2_100 + index * 7), name: "com.apple.WebKit.WebContent", path: webContent, megabytes: megabytes))
        }
        // A typical Mac runs a few hundred small background processes (paths as on macOS 26).
        let daemons = [
            "/usr/libexec/nsurlsessiond", "/usr/libexec/sharingd", "/usr/libexec/trustd", "/usr/libexec/secd",
            "/usr/sbin/cfprefsd", "/usr/sbin/distnoted", "/usr/libexec/rapportd", "/usr/libexec/routined",
            "/System/Library/PrivateFrameworks/UserActivity.framework/Agents/useractivityd",
            "/System/Library/PrivateFrameworks/CoreSuggestions.framework/Versions/A/Support/suggestd",
            "/usr/libexec/knowledge-agent", "/usr/libexec/siriknowledged",
            "/System/Library/Frameworks/Contacts.framework/Support/contactsd",
            "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/callservicesd",
            "/System/Library/Frameworks/Accounts.framework/Versions/A/Support/accountsd",
            "/System/Library/PrivateFrameworks/AuthKit.framework/Versions/A/Support/akd",
            "/System/Library/PrivateFrameworks/AssistantServices.framework/Versions/A/Support/assistantd",
            "/usr/libexec/lsd", "/usr/libexec/pboard", "/usr/sbin/universalaccessd",
            "/System/Library/PrivateFrameworks/TCC.framework/Support/tccd",
            "/System/Library/Frameworks/FileProvider.framework/Support/fileproviderd",
            "/System/Library/PrivateFrameworks/CacheDelete.framework/deleted", "/usr/libexec/duetexpertd",
            "/usr/libexec/biomesyncd", "/System/Library/PrivateFrameworks/ChronoCore.framework/Support/chronod",
            "/System/Library/PrivateFrameworks/CommerceKit.framework/Versions/A/Resources/commerce",
            "/System/Library/Frameworks/CryptoTokenKit.framework/ctkd",
        ]
        for (index, path) in daemons.enumerated() {
            let name = (path as NSString).lastPathComponent
            list.append(DemoProcess(pid: Int32(3_000 + index * 3), name: name, path: path, megabytes: Double(4 + (index * 37) % 29)))
        }
        let systemDaemons = [
            "/usr/libexec/logd", "/usr/libexec/configd", "/usr/libexec/opendirectoryd", "/usr/libexec/airportd",
            "/usr/sbin/bluetoothd", "/System/Library/CoreServices/powerd.bundle/powerd", "/usr/sbin/notifyd",
            "/usr/sbin/securityd", "/usr/libexec/syspolicyd", "/usr/libexec/kernelmanagerd",
            "/usr/libexec/diskarbitrationd", "/System/Library/CoreServices/coreservicesd", "/usr/libexec/thermalmonitord",
            "/usr/libexec/symptomsd", "/System/Library/PrivateFrameworks/ApplePushService.framework/apsd",
            "/usr/libexec/timed", "/usr/libexec/watchdogd", "/usr/libexec/runningboardd", "/usr/libexec/UserEventAgent",
        ]
        for (index, path) in systemDaemons.enumerated() {
            let name = (path as NSString).lastPathComponent
            list.append(DemoProcess(pid: Int32(90 + index * 4), name: name, path: path, megabytes: nil, user: root))
        }
        return list
    }()

    private static let bundleMetadata: [String: BundleMetadata] = [
        "/Applications/Xcode.app": BundleMetadata(displayName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode"),
        "/Applications/Safari.app": BundleMetadata(displayName: "Safari", bundleIdentifier: "com.apple.Safari"),
        "/Applications/RamLume.app": BundleMetadata(displayName: "RamLume", bundleIdentifier: nil),
        "/System/Applications/Photos.app": BundleMetadata(displayName: "Photos", bundleIdentifier: "com.apple.Photos"),
        "/System/Applications/Mail.app": BundleMetadata(displayName: "Mail", bundleIdentifier: "com.apple.mail"),
        "/System/Applications/Music.app": BundleMetadata(displayName: "Music", bundleIdentifier: "com.apple.Music"),
        "/System/Applications/Notes.app": BundleMetadata(displayName: "Notes", bundleIdentifier: "com.apple.Notes"),
        "/System/Applications/Messages.app": BundleMetadata(displayName: "Messages", bundleIdentifier: "com.apple.MobileSMS"),
        "/System/Applications/System Settings.app": BundleMetadata(displayName: "System Settings", bundleIdentifier: "com.apple.systempreferences"),
        "/System/Applications/Calendar.app": BundleMetadata(displayName: "Calendar", bundleIdentifier: "com.apple.iCal"),
        "/System/Applications/Preview.app": BundleMetadata(displayName: "Preview", bundleIdentifier: "com.apple.Preview"),
        "/System/Library/CoreServices/Finder.app": BundleMetadata(displayName: "Finder", bundleIdentifier: "com.apple.finder"),
        "/System/Library/CoreServices/Dock.app": BundleMetadata(displayName: "Dock", bundleIdentifier: "com.apple.dock"),
        "/System/Library/CoreServices/Spotlight.app": BundleMetadata(displayName: "Spotlight", bundleIdentifier: "com.apple.Spotlight"),
        "/System/Library/CoreServices/ControlCenter.app": BundleMetadata(displayName: "Control Center", bundleIdentifier: "com.apple.controlcenter"),
        "/System/Library/CoreServices/NotificationCenter.app": BundleMetadata(displayName: "Notification Center", bundleIdentifier: "com.apple.notificationcenterui"),
        "/System/Library/CoreServices/WallpaperAgent.app": BundleMetadata(displayName: "WallpaperAgent", bundleIdentifier: "com.apple.wallpaper.agent"),
    ]

    static func processSnapshot(at date: Date) -> ProcessSnapshot {
        let records = processes.map { process -> ProcessRecord in
            let bundle = process.path.flatMap(ProcessGrouper.outermostAppBundlePath(forExecutablePath:))
            let footprint = process.megabytes.map { UInt64($0 * mib) }
            return ProcessRecord(
                pid: process.pid,
                name: process.name,
                executablePath: process.path,
                appBundlePath: bundle,
                role: ProcessGrouper.role(executablePath: process.path, bundlePath: bundle),
                userID: process.user.id,
                userName: process.user.name,
                parentPID: process.pid == 1 ? 0 : 1,
                footprint: footprint,
                peakFootprint: footprint.map { $0 + $0 / 4 },
                access: footprint == nil ? .restricted(errno: EPERM) : .accessible
            )
        }
        let accessible = records.count(where: \.isAccessible)
        return ProcessSnapshot(
            timestamp: date,
            groups: ProcessGrouper.makeGroups(from: records, bundleMetadata: bundleMetadata),
            totalCount: records.count,
            accessibleCount: accessible,
            restrictedCount: records.count - accessible,
            scanDuration: 0.011
        )
    }

    // MARK: - Readers

    struct MemoryReader: MemoryStatisticsProviding {
        let anchor: Date
        func readStatistics() throws(MemoryReadError) -> MemoryStatistics {
            let now = Date()
            return DemoData.statistics(at: now.timeIntervalSince(anchor), timestamp: now, uptime: ProcessInfo.processInfo.systemUptime)
        }
    }

    struct SwapReader: SwapUsageProviding {
        let anchor: Date
        func readSwapUsage() -> SwapUsage? { DemoData.swap(at: Date().timeIntervalSince(anchor)) }
    }

    struct PressureReader: PressureLevelProviding {
        let anchor: Date
        func readIndicators() -> KernelPressureIndicators {
            KernelPressureIndicators(level: DemoData.reading(at: Date().timeIntervalSince(anchor)).pressure, freePercentage: 58)
        }
    }

    struct ProcessProvider: ProcessProviding {
        func scanProcesses() async -> ProcessSnapshot { DemoData.processSnapshot(at: Date()) }
    }
}
#endif
