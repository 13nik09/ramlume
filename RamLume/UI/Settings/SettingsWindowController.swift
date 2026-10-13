import AppKit
import SwiftUI

/// A standard toolbar-tab Settings window, managed by AppKit so it opens reliably and comes to
/// the front from a menu-bar-only app.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
    private var tabController: NSTabViewController?

    init(model: AppModel) {
        self.model = model
    }

    func show(tab: SettingsTab?) {
        let window = window ?? makeWindow()
        self.window = window
        if let tab, let index = SettingsTab.allCases.firstIndex(of: tab) {
            tabController?.selectedTabViewItemIndex = index
        }
        model.launchAtLogin.refresh()
        Task { await model.notifications.refreshAuthorization() }
        ActivationPolicyController.present(window)
        #if DEBUG
        if DebugOptions.ordersWindowsFrontRegardless {
            // Background apps can't order normal windows above the active app; float instead.
            window.level = .floating
            window.orderFrontRegardless()
        }
        #endif
    }

    private func makeWindow() -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        for tab in SettingsTab.allCases {
            let item = NSTabViewItem(viewController: hostingController(for: tab))
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        tabController = tabs

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.tabbingMode = .disallowed
        window.center()
        return window
    }

    private func hostingController(for tab: SettingsTab) -> NSViewController {
        let content: AnyView
        switch tab {
        case .general: content = AnyView(GeneralSettingsView())
        case .monitoring: content = AnyView(MonitoringSettingsView())
        case .notifications: content = AnyView(NotificationSettingsView())
        case .history: content = AnyView(HistorySettingsView())
        case .about: content = AnyView(AboutSettingsView())
        }
        let controller = NSHostingController(rootView: content.environment(model).frame(width: 520))
        controller.sizingOptions = [.preferredContentSize]
        // NSTabViewController shows the selected child's title in the window's title bar.
        controller.title = tab.title
        return controller
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        ActivationPolicyController.windowWillClose(window)
    }
}

extension SettingsTab {
    var title: String {
        switch self {
        case .general: "General"
        case .monitoring: "Monitoring"
        case .notifications: "Notifications"
        case .history: "History"
        case .about: "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .monitoring: "gauge.with.dots.needle.33percent"
        case .notifications: "bell.badge"
        case .history: "clock.arrow.circlepath"
        case .about: "info.circle"
        }
    }
}
