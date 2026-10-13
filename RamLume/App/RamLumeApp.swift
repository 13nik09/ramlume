import AppKit

@main
enum RamLumeApp {
    /// The application delegate must outlive `NSApplication.run()`; `NSApplication.delegate` is weak.
    @MainActor private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        // `RamLume --dump-metrics` prints one reading with formulas and exits. Useful for
        // comparing against `vm_stat` and for bug reports. See scripts/compare-with-system-tools.sh.
        if CommandLine.arguments.contains("--dump-metrics") {
            MetricsReport.printReport()
            exit(0)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
    }
}
