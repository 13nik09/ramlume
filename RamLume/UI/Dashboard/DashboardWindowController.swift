import AppKit
import SwiftUI

/// Shows RamLume in the Dock and app switcher while one of its windows is open, and returns
/// it to a menu-bar-only app when the last one closes.
@MainActor
enum ActivationPolicyController {
    private static var openWindows = Set<ObjectIdentifier>()

    static func windowDidOpen(_ window: NSWindow) {
        openWindows.insert(ObjectIdentifier(window))
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    static func windowWillClose(_ window: NSWindow) {
        openWindows.remove(ObjectIdentifier(window))
        if openWindows.isEmpty, NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Activates RamLume and brings `window` forward.
    static func present(_ window: NSWindow) {
        windowDidOpen(window)
        #if DEBUG
        if DebugOptions.avoidsActivation {
            window.orderFront(nil)
            return
        }
        #endif
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

/// Owns the dashboard window. The SwiftUI hierarchy exists only while the window is open, and
/// the coordinator samples at the dashboard cadence only while the window is actually visible.
@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
    private var occlusionObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
    }

    func show(section: DashboardSection?) {
        if let section {
            model.dashboardSection = section
        }
        let window = window ?? makeWindow()
        self.window = window
        ActivationPolicyController.present(window)
        #if DEBUG
        if DebugOptions.ordersWindowsFrontRegardless {
            // Background apps can't order normal windows above the active app; float instead.
            window.level = .floating
            window.orderFrontRegardless()
        }
        window.ignoresMouseEvents = DebugOptions.ignoresMouse
        #endif
        updateVisibility()
    }

    func close() {
        window?.performClose(nil)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: DashboardView().environment(model))
        hosting.sceneBridgingOptions = [.toolbars, .title]
        // The user sizes this window; never grow it to fit content (e.g. a long process table).
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "RamLume"
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 820, height: 540)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        window.setContentSize(NSSize(width: 1_080, height: 720))
        if !window.setFrameUsingName("RamLumeDashboard") {
            window.center()
        }
        window.setFrameAutosaveName("RamLumeDashboard")

        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        }
        return window
    }

    private func updateVisibility() {
        var visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        #if DEBUG
        if DebugOptions.assumesDashboardVisible, window != nil { visible = true }
        #endif
        model.monitor.setVisible(visible, surface: .dashboard)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        ActivationPolicyController.windowWillClose(window)
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
        occlusionObserver = nil
        // Drop the window and its SwiftUI hierarchy; it's rebuilt on the next open.
        window.contentViewController = nil
        self.window = nil
        model.monitor.setVisible(false, surface: .dashboard)
    }
}
