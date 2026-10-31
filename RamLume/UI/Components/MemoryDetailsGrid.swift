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

    /// What one tile shows.
    struct Tile: Equatable {
        var label: String
        var value: String
        var caption: String?
        var provenance: Provenance = .measured
        var swatch: Color?
        var help: String
    }

    var figures: MemoryFigures
    var pressure: MemoryPressureLevel?
    var items: [Item]
    var columns = 2
    var showsCaptions = true
    var spacing: CGFloat = 12
    var context: CardContext = .panel

    /// Compares only what the tiles show. "Used" and "free" change with nearly every sample, and
    /// the panel's tiles show neither, so comparing all the figures would redraw it every second.
    nonisolated static func == (lhs: MemoryDetailsGrid, rhs: MemoryDetailsGrid) -> Bool {
        lhs.columns == rhs.columns && lhs.spacing == rhs.spacing && lhs.context == rhs.context
            && lhs.tiles == rhs.tiles
    }

    var body: some View {
        let tiles = self.tiles
        let perRow = max(columns, 1)
        let rowStarts: [Int] = Array(stride(from: 0, to: tiles.count, by: perRow))
        Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
            ForEach(rowStarts, id: \.self) { start in
                GridRow {
                    ForEach(start..<min(start + perRow, tiles.count), id: \.self) { index in
                        let tile = tiles[index]
                        StatTile(label: tile.label, value: tile.value, caption: tile.caption, provenance: tile.provenance,
                                 swatch: tile.swatch, help: tile.help, context: context)
                    }
                }
            }
        }
    }

    nonisolated private var tiles: [Tile] { items.map(tile) }

    nonisolated private func tile(_ item: Item) -> Tile {
        // Every tile in a row has a caption (or none does), so the tiles in a row are the same height.
        func caption(_ text: String) -> String? { showsCaptions ? text : nil }
        switch item {
        case .physical:
            return Tile(label: "Physical memory", value: figures.total, caption: caption("installed"),
                        help: "The RAM installed in your Mac.")
        case .inUse:
            return Tile(label: "Memory in use", value: figures.used, caption: caption("\(figures.percent) of \(figures.total)"),
                        provenance: .estimated,
                        help: "\(MemoryTerm.inUse.plain) Activity Monitor's Memory Used follows Apple's own formula, so it can differ slightly.")
        case .swap:
            let allocated: String = figures.swapTotal.map { "of \($0) allocated" } ?? "not reported"
            return Tile(label: "Swap used", value: figures.swapUsed ?? "Unavailable", caption: caption(allocated),
                        swatch: Palette.swap,
                        help: "\(MemoryTerm.swap.plain) Allocated swap can stay after demand drops; that's normal.")
        case .pressure:
            return Tile(label: "Memory pressure", value: pressure?.displayName ?? "Not reported", caption: caption("from macOS"),
                        swatch: Palette.pressure(pressure), help: MemoryTerm.pressure.plain)
        case .app:
            return Tile(label: "App memory", value: figures.app, caption: caption("apps and helpers"),
                        swatch: Palette.app, help: MemoryTerm.app.plain)
        case .wired:
            return Tile(label: "Wired memory", value: figures.wired, caption: caption("always kept in RAM"),
                        swatch: Palette.wired, help: MemoryTerm.wired.plain)
        case .compressed:
            let holds: String = figures.compressedOriginal.map { "holds \($0)" } ?? "nothing compressed"
            return Tile(label: "Compressed", value: figures.compressed, caption: caption(holds),
                        swatch: Palette.compressed, help: MemoryTerm.compressed.plain)
        case .cached:
            return Tile(label: "Cached files", value: figures.cached, caption: caption("usually reclaimable"),
                        provenance: .estimated, swatch: Palette.cached, help: MemoryTerm.cached.plain)
        }
    }
}
