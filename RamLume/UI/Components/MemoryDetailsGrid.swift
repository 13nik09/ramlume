import SwiftUI

/// The figures Activity Monitor shows under its Memory tab, as tiles, plus the pressure level
/// macOS reports. Labels use Activity Monitor's names wherever RamLume means the same thing.
struct MemoryDetailsGrid: View, Equatable {
    enum Item {
        case physical
        case inUse
        case swap
        case pressure
        case app
        case wired
        case compressed
        case cached
    }

    var figures: MemoryFigures
    var pressure: MemoryPressureLevel?
    var items: [Item]
    var columns = 2
    var showsCaptions = true
    var spacing: CGFloat = 12
    var context: CardContext = .panel

    var body: some View {
        let tiles: [StatTile] = items.map(tile)
        let perRow = max(columns, 1)
        let rowStarts: [Int] = Array(stride(from: 0, to: tiles.count, by: perRow))
        Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(rowStarts, id: \.self) { start in
                GridRow {
                    ForEach(start..<min(start + perRow, tiles.count), id: \.self) { index in
                        tiles[index]
                    }
                }
            }
        }
    }

    private func tile(_ item: Item) -> StatTile {
        // Every tile in a row has a caption (or none does), so the tiles in a row are the same height.
        func caption(_ text: String) -> String? { showsCaptions ? text : nil }
        switch item {
        case .physical:
            return StatTile(label: "Physical memory", value: figures.total, caption: caption("installed"),
                            help: "The RAM installed in your Mac.", context: context)
        case .inUse:
            return StatTile(label: "Memory in use", value: figures.used, caption: caption("\(figures.percent) of \(figures.total)"),
                            provenance: .estimated,
                            help: "\(MemoryTerm.inUse.plain) Activity Monitor's Memory Used follows Apple's own formula, so it can differ slightly.",
                            context: context)
        case .swap:
            let allocated: String = figures.swapTotal.map { "of \($0) allocated" } ?? "not reported"
            return StatTile(label: "Swap used", value: figures.swapUsed ?? "Unavailable", caption: caption(allocated),
                            swatch: Palette.swap,
                            help: "\(MemoryTerm.swap.plain) Allocated swap can stay after demand drops; that's normal.",
                            context: context)
        case .pressure:
            return StatTile(label: "Memory pressure", value: pressure?.displayName ?? "Not reported", caption: caption("from macOS"),
                            swatch: Palette.pressure(pressure), help: MemoryTerm.pressure.plain, context: context)
        case .app:
            return StatTile(label: "App memory", value: figures.app, caption: caption("apps and helpers"),
                            swatch: Palette.app, help: MemoryTerm.app.plain, context: context)
        case .wired:
            return StatTile(label: "Wired memory", value: figures.wired, caption: caption("always kept in RAM"),
                            swatch: Palette.wired, help: MemoryTerm.wired.plain, context: context)
        case .compressed:
            let holds: String = figures.compressedOriginal.map { "holds \($0)" } ?? "nothing compressed"
            return StatTile(label: "Compressed", value: figures.compressed, caption: caption(holds),
                            swatch: Palette.compressed, help: MemoryTerm.compressed.plain, context: context)
        case .cached:
            return StatTile(label: "Cached files", value: figures.cached, caption: caption("usually reclaimable"),
                            provenance: .estimated, swatch: Palette.cached, help: MemoryTerm.cached.plain, context: context)
        }
    }
}
