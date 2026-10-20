import SwiftUI

/// Memory terms in plain English, for info buttons and the Definitions page.
enum MemoryTerm: String, CaseIterable, Identifiable {
    case pressure
    case inUse
    case app
    case wired
    case compressed
    case cached
    case swap
    case free

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pressure: "Memory pressure"
        case .inUse: "Memory in use"
        case .app: "App memory"
        case .wired: "Wired memory"
        case .compressed: "Compressed memory"
        case .cached: "Cached files"
        case .swap: "Swap"
        case .free: "Free memory"
        }
    }

    /// One sentence.
    var plain: String {
        switch self {
        case .pressure: "Shows how hard your Mac is working to handle its current memory needs."
        case .inUse: "RAM that isn't available for new work right now: apps, macOS itself, and compressed data."
        case .app: "Memory used by your apps and their helper processes."
        case .wired: "Memory that macOS must keep in RAM at all times."
        case .compressed: "macOS makes inactive data smaller to save RAM."
        case .cached: "RAM holding recently used data that macOS can usually reuse when needed."
        case .swap: "Your Mac can temporarily use storage to hold memory data."
        case .free: "RAM that isn't being used for anything right now."
        }
    }

    /// A little more, for people who want it.
    var detail: String {
        switch self {
        case .pressure:
            "macOS reports it as normal, warning, or critical. Normal means apps have the memory they need, even when most of your RAM is in use. RamLume's status combines this reading with recent swap activity."
        case .inUse:
            "RamLume estimates it as everything except cached files and free memory. A high number is normal: macOS puts spare RAM to work to make things faster."
        case .app:
            "It grows as you open apps, browser tabs, and documents, and shrinks when you quit them."
        case .wired:
            "It's used by macOS itself, for example the kernel and drivers. Apps can't use it, and it can't be compressed or moved to storage."
        case .compressed:
            "Compressing memory is much faster than moving data to storage, so it's a normal, efficient way for macOS to make room. It isn't a problem by itself."
        case .cached:
            "Files you used recently stay in memory so they open faster next time. macOS hands this memory to apps whenever they need it."
        case .swap:
            "When RAM runs short, macOS moves inactive data to storage. Swap that stays in use after a busy period is normal; constant swapping while memory pressure is high can slow your Mac down. You don't need to restart to clear it."
        case .free:
            "macOS prefers to put free memory to work as cache, so a small number here is normal and not a sign of a problem."
        }
    }
}

/// A small ⓘ button that explains a term in a popover.
struct InfoButton: View {
    var term: MemoryTerm
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(term.plain)
        .accessibilityLabel("About \(term.title)")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            TermExplanation(term: term)
                .padding(16)
                .frame(width: 300)
        }
    }
}

/// A term's title, one-line meaning, and longer explanation.
struct TermExplanation: View {
    var term: MemoryTerm

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(term.title)
                .font(.headline)
            Text(term.plain)
                .fixedSize(horizontal: false, vertical: true)
            Text(term.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }
}
