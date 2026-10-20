import AppKit
import SwiftUI

/// Owns the menu bar item and its panel.
///
/// Left click toggles the panel; right click (or Control-click) shows a short menu. The panel's
/// SwiftUI hierarchy is created when it opens and released when it closes, so nothing renders
/// while it isn't visible, and the coordinator samples faster only while it's on screen.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    /// Always present, except in debug stress runs started with `--no-status-item`.
    private let statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var outsideClickMonitor: Any?
    private var appearanceObservations: [NSKeyValueObservation] = []
    private var lastPresentation: StatusItemPresentation?

    init(model: AppModel) {
        self.model = model
        #if DEBUG
        // `--no-status-item`: long stress runs shouldn't flicker an icon in the menu bar. Hiding
        // an item would be remembered by AppKit for later launches, so none is created.
        statusItem = CommandLine.arguments.contains("--no-status-item")
            ? nil : NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        #else
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        #endif
        super.init()

        if let button = statusItem?.button {
            button.image = Self.makeSymbolImage()
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        appearanceObservations = [
            NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.matchSystemAppearance() }
            },
            NSApp.observe(\.appearance) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.matchSystemAppearance() }
            },
        ]
        matchSystemAppearance()
        update()
    }

    /// macOS picks light or dark menu bar content for each item from what it sees behind it, and
    /// it has left RamLume's item in the light style (black) on a dark menu bar while the items
    /// around it were white. While the Mac uses Dark mode, the item uses the dark menu bar style;
    /// otherwise macOS decides. (With RamLume's own Light or Dark setting the system's mode isn't
    /// known here, so macOS decides then too.)
    private func matchSystemAppearance() {
        guard let button = statusItem?.button else { return }
        let systemIsDark = NSApp.appearance == nil
            && NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let wanted = systemIsDark ? NSAppearance(named: .vibrantDark) : nil
        if button.appearance?.name != wanted?.name {
            button.appearance = wanted
        }
    }

    private static func makeSymbolImage() -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: AppInfo.name)?
            .withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = true
        return image
    }

    // MARK: - Rendering

    func update() {
        let monitor = model.monitor
        let state = monitor.current
        let presentation = StatusItemPresentation.make(
            snapshot: state.snapshot,
            health: state.health.state,
            pressure: state.pressure.level,
            status: monitor.status,
            style: model.settings.menuBarStyle,
            tintsIcon: model.settings.tintsMenuBarIcon
        )
        guard presentation != lastPresentation, let button = statusItem?.button else { return }
        lastPresentation = presentation

        // A plain title, drawn in the menu bar's text color like the icon (see `matchSystemAppearance`).
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        if presentation.title.isEmpty {
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            button.title = " " + presentation.title
            button.imagePosition = .imageLeading
        }
        switch presentation.tint {
        case .serious?: button.contentTintColor = NSColor(srgbHex: 0xEC835A)
        case .critical?: button.contentTintColor = NSColor.systemRed
        case nil: button.contentTintColor = nil
        }
        button.appearsDisabled = presentation.isDimmed
        button.toolTip = presentation.toolTip
        button.setAccessibilityLabel(presentation.accessibilityLabel)
    }

    // MARK: - Interaction

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else if popover.isShown {
            closePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard let button = statusItem?.button, !popover.isShown else { return }
        let hosting = NSHostingController(rootView: MenuPanelView().environment(model))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        model.monitor.setVisible(true, surface: .menuPanel)
        #if DEBUG
        if DebugOptions.avoidsActivation {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            return
        }
        #endif
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        startOutsideClickMonitor()
    }

    func closePanel() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitor()
        model.monitor.setVisible(false, surface: .menuPanel)
        // Release the SwiftUI hierarchy so nothing is rendered while the panel is closed.
        popover.contentViewController = nil
        if !model.settings.hasShownWelcome {
            model.settings.hasShownWelcome = true
        }
    }

    /// Transient popovers close on clicks inside the app; this also closes on clicks elsewhere.
    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closePanel()
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }

    private func showContextMenu() {
        closePanel()
        let menu = NSMenu()
        menu.addItem(menuItem("Open Dashboard", #selector(openDashboard)))
        menu.addItem(menuItem("Settings…", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(menuItem(model.monitor.isPausedByUser ? "Resume Monitoring" : "Pause Monitoring", #selector(togglePause)))
        menu.addItem(.separator())
        menu.addItem(menuItem("About RamLume", #selector(showAbout)))
        menu.addItem(menuItem("Quit RamLume", #selector(quit)))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    private func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openDashboard() { model.openDashboard() }
    @objc private func openSettings() { model.openSettings() }
    @objc private func togglePause() { model.togglePause() }
    @objc private func showAbout() { model.showAbout() }
    @objc private func quit() { model.quit() }
}
