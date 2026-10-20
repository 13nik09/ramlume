import Foundation

/// App-specific context for insights about large memory consumers.
///
/// Matching uses bundle identifiers (or an exact executable name for system services), never a
/// substring of a process name. The wording describes what *may* contribute; RamLume can't see
/// which tab or document uses the memory.
struct ApplicationAdvice: Sendable, Equatable {
    /// Why this kind of app may use a lot of memory.
    var context: String
    /// An optional, gentle suggestion.
    var suggestion: String?
}

enum KnownApplications {
    static func advice(forBundleIdentifier bundleIdentifier: String?, executableName: String?) -> ApplicationAdvice? {
        if let bundleIdentifier, let advice = byBundleIdentifier[bundleIdentifier] {
            return advice
        }
        if let executableName, let advice = byExecutableName[executableName] {
            return advice
        }
        return nil
    }

    private static let chromiumContext = "Its tabs, extensions, and renderer processes may contribute to this usage."
    private static let electronAdvice = ApplicationAdvice(
        context: "Apps built on web technologies run several helper processes, which add up.",
        suggestion: "Quitting and reopening it releases memory it has accumulated."
    )

    private static let byBundleIdentifier: [String: ApplicationAdvice] = {
        var table: [String: ApplicationAdvice] = [:]

        let brave = ApplicationAdvice(
            context: chromiumContext,
            suggestion: "Consider enabling Memory Saver in Brave's settings so inactive tabs release their memory."
        )
        for id in ["com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly"] { table[id] = brave }

        let chrome = ApplicationAdvice(
            context: chromiumContext,
            suggestion: "Consider enabling Memory Saver in Chrome's performance settings so inactive tabs release their memory."
        )
        for id in ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"] { table[id] = chrome }

        let edge = ApplicationAdvice(
            context: chromiumContext,
            suggestion: "Consider turning on sleeping tabs in Edge's settings so inactive tabs release their memory."
        )
        for id in ["com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary"] { table[id] = edge }

        let genericChromium = ApplicationAdvice(context: chromiumContext, suggestion: "Closing tabs you aren't using reduces its memory use.")
        for id in ["com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium", "company.thebrowser.Browser"] { table[id] = genericChromium }

        let firefox = ApplicationAdvice(
            context: "Its tabs, extensions, and content processes may contribute to this usage.",
            suggestion: "Firefox unloads inactive tabs when memory runs low; you can also unload tabs manually from about:unloads."
        )
        for id in ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"] { table[id] = firefox }

        table["com.apple.Safari"] = ApplicationAdvice(
            context: "Safari's web pages run in shared WebKit processes that RamLume can't attribute to Safari, so its real total may be higher than shown.",
            suggestion: nil
        )

        for id in ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.VSCode", "com.microsoft.teams2",
                   "notion.id", "com.spotify.client", "com.figma.Desktop", "md.obsidian", "com.todesktop.230313mzl4w4u92"] {
            table[id] = electronAdvice
        }

        table["com.apple.dt.Xcode"] = ApplicationAdvice(
            context: "Indexing, builds, previews, and simulators can temporarily use a lot of memory.",
            suggestion: nil
        )
        table["com.docker.docker"] = ApplicationAdvice(
            context: "Docker's virtual machine can use memory up to the limit set in Docker's settings.",
            suggestion: "If you don't need that much, you can lower the memory limit in Docker's resource settings."
        )
        return table
    }()

    private static let byExecutableName: [String: ApplicationAdvice] = [
        "com.apple.Virtualization.VirtualMachine": ApplicationAdvice(
            context: "A virtual machine is running. Its memory allocation is chosen by the app that started it.",
            suggestion: nil
        ),
    ]
}

/// Browsers RamLume can give specific advice for, matched by bundle identifier.
enum KnownBrowser: Sendable, Equatable {
    case brave
    case chrome
    case edge
    case firefox
    case safari
    case otherChromium

    /// How to turn on the browser's own setting that releases memory held by inactive tabs, if
    /// it has one.
    var memorySaverSteps: [String]? {
        switch self {
        case .brave:
            [
                "In Brave, open Settings (Brave › Settings, or press ⌘,).",
                "Choose System, then find Performance.",
                "Turn on Memory Saver. If you don't see it, type “memory saver” in the settings search field.",
            ]
        case .chrome:
            [
                "In Chrome, open Settings (Chrome › Settings, or press ⌘,).",
                "Choose Performance.",
                "Turn on Memory Saver.",
            ]
        case .edge:
            [
                "In Edge, open Settings (Microsoft Edge › Settings, or press ⌘,).",
                "Choose System and performance.",
                "Turn on “Save resources with sleeping tabs”. If you don't see it, search Settings for “sleeping tabs”.",
            ]
        case .firefox:
            [
                "Type about:unloads in Firefox's address bar to unload tabs you aren't using; they reload when you open them again.",
            ]
        case .safari, .otherChromium:
            nil
        }
    }

    /// The name of that setting, for one-line summaries.
    var memorySaverName: String? {
        switch self {
        case .brave, .chrome: "Memory Saver"
        case .edge: "sleeping tabs"
        case .firefox, .safari, .otherChromium: nil
        }
    }
}

extension KnownApplications {
    static func browser(forBundleIdentifier bundleIdentifier: String?) -> KnownBrowser? {
        guard let bundleIdentifier else { return nil }
        return browsers[bundleIdentifier]
    }

    private static let browsers: [String: KnownBrowser] = {
        var table: [String: KnownBrowser] = [:]
        for id in ["com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly"] { table[id] = .brave }
        for id in ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"] { table[id] = .chrome }
        for id in ["com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary"] { table[id] = .edge }
        for id in ["org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly"] { table[id] = .firefox }
        for id in ["com.apple.Safari", "com.apple.SafariTechnologyPreview"] { table[id] = .safari }
        for id in ["com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.chromium.Chromium", "company.thebrowser.Browser"] { table[id] = .otherChromium }
        return table
    }()
}

extension KnownApplications {
    /// Plain names for system services whose executable names mean little to most people. The
    /// name never claims an owner: WebKit's processes serve Safari and every other app that shows
    /// web content, and RamLume can't tell which.
    static func friendlyName(forExecutableName name: String) -> String? {
        friendlyNames[name]
    }

    private static let friendlyNames: [String: String] = [
        "com.apple.WebKit.WebContent": "Web pages (WebKit)",
        "com.apple.WebKit.GPU": "Web graphics (WebKit)",
        "com.apple.WebKit.Networking": "Web networking (WebKit)",
    ]
}

