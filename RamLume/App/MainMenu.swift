import AppKit

/// The main menu. It's visible while a RamLume window is open (the app then shows in the Dock),
/// and its key equivalents (⌘W, ⌘C, ⌘Q, …) work in RamLume's windows at all times.
@MainActor
enum MainMenuBuilder {
    private static weak var windowMenuItem: NSMenuItem?
    private static weak var windowMenuTarget: AnyObject?
    private static var isWindowMenuRegistered = false

    static func makeMainMenu(target: AnyObject) -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(submenuItem(appMenu(target: target)))
        mainMenu.addItem(submenuItem(editMenu()))
        mainMenu.addItem(submenuItem(viewMenu(target: target)))
        let window = submenuItem(windowMenu(target: target))
        mainMenu.addItem(window)
        let help = helpMenu(target: target)
        mainMenu.addItem(submenuItem(help))
        windowMenuItem = window
        windowMenuTarget = target
        isWindowMenuRegistered = false
        NSApp.helpMenu = help
        return mainMenu
    }

    /// Makes the Window menu AppKit's windows menu while RamLume has a window, and not otherwise.
    ///
    /// AppKit adds the system's window items (tiling, Move & Resize) to its windows menu and
    /// works through them whenever the app's menus are read, and macOS can read them every time
    /// something RamLume shows changes. With only the menu bar panel open there's no menu bar of
    /// RamLume's to show that menu in; in one profile it was a third of the panel's CPU.
    ///
    /// AppKit ignores `windowsMenu = nil`, so a registered menu is taken out of use by showing a
    /// new one in its place, and registering means showing (and registering) another new one: no
    /// menu is registered twice. Windows that are open get their entries in the new menu.
    static func setWindowMenuRegistered(_ registered: Bool) {
        guard registered != isWindowMenuRegistered, let item = windowMenuItem, let target = windowMenuTarget else { return }
        isWindowMenuRegistered = registered
        let menu = windowMenu(target: target)
        item.submenu = menu
        if registered {
            NSApp.windowsMenu = menu
        }
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "", modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    private static func appMenu(target: AnyObject) -> NSMenu {
        let menu = NSMenu(title: AppInfo.name)
        menu.addItem(item("About \(AppInfo.name)", #selector(AppDelegate.showAbout(_:)), target: target))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ",", target: target))
        menu.addItem(item("Pause Monitoring", #selector(AppDelegate.togglePause(_:)), target: target))
        menu.addItem(.separator())
        menu.addItem(item("Hide \(AppInfo.name)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(AppInfo.name)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private static func viewMenu(target: AnyObject) -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Refresh Processes", #selector(AppDelegate.refreshProcesses(_:)), "r", target: target))
        menu.addItem(.separator())
        menu.addItem(item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", modifiers: [.command, .control]))
        return menu
    }

    private static func windowMenu(target: AnyObject) -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(item("Dashboard", #selector(AppDelegate.showDashboard(_:)), "0", target: target))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu(target: AnyObject) -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("How RamLume Measures Memory", #selector(AppDelegate.showMetricsGuide(_:)), "?", target: target))
        if AppInfo.repositoryURL != nil {
            // These open the browser; RamLume itself makes no network requests.
            menu.addItem(.separator())
            menu.addItem(item("RamLume on GitHub", #selector(AppDelegate.openRepository(_:)), target: target))
            menu.addItem(item("Report an Issue…", #selector(AppDelegate.reportIssue(_:)), target: target))
        }
        return menu
    }
}
