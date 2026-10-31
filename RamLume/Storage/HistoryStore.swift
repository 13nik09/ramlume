import Foundation
import Observation

/// The history file: aggregated samples, gaps, and the event timeline.
struct HistoryFile: Sendable, Codable, Equatable {
    var history: MemoryHistory.Archive
    var events: [MemoryEvent]
}

/// Reads and writes `~/Library/Application Support/RamLume/History.json`.
///
/// The file is plain JSON so anyone can inspect exactly what RamLume stores. It never contains
/// process names or anything other than aggregate memory statistics and event descriptions.
struct HistoryPersistence: Sendable {
    let fileURL: URL

    static func defaultFileURL() -> URL? {
        #if DEBUG
        // `--history-file <path>`: keeps stress tests away from the real history file.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--history-file"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1])
        }
        #endif
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base
            .appending(path: "RamLume", directoryHint: .isDirectory)
            .appending(path: "History.json", directoryHint: .notDirectory)
    }

    enum LoadResult: Sendable {
        case loaded(HistoryFile)
        case missing
        /// The file couldn't be decoded; it was moved aside and RamLume starts fresh.
        case unreadable(String)
    }

    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let file = try decoder.decode(HistoryFile.self, from: data)
            guard file.history.version == MemoryHistory.Archive.currentVersion else {
                moveAside()
                return .unreadable("Unsupported history format version \(file.history.version).")
            }
            return .loaded(file)
        } catch {
            moveAside()
            return .unreadable(error.localizedDescription)
        }
    }

    func save(_ file: HistoryFile) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(file)
        try data.write(to: fileURL, options: [.atomic])
    }

    func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    func fileSize() -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value
    }

    private func moveAside() {
        let destination = fileURL.deletingPathExtension().appendingPathExtension("unreadable.json")
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: fileURL, to: destination)
    }
}

/// Serializes history writes off the main thread.
actor HistoryWriter {
    private let persistence: HistoryPersistence

    init(persistence: HistoryPersistence) {
        self.persistence = persistence
    }

    func save(_ file: HistoryFile) throws {
        try persistence.save(file)
    }

    func delete() throws {
        try persistence.delete()
    }
}

/// Observable owner of memory history and the event timeline.
@MainActor
@Observable
final class HistoryStore {
    static let eventCapacity = 300
    /// History is written at most this often while running, plus on sleep, power-off, and quit.
    /// Each save rewrites the whole file (about 0.7 MB with 24 hours of history), so not often.
    static let saveInterval: TimeInterval = 900
    /// The first save happens this soon after launch, so short sessions are kept too.
    static let firstSaveDelay: TimeInterval = 60

    /// Not observed directly: it changes every sample. Views that need live updates read
    /// `revision`; long-range charts refresh on their own, slower schedule.
    @ObservationIgnored private(set) var history: MemoryHistory
    /// Incremented whenever `history` changes.
    private(set) var revision = 0
    private(set) var events: RingBuffer<MemoryEvent>
    /// Set when an existing history file couldn't be read at launch.
    private(set) var loadProblem: String?

    @ObservationIgnored private let persistence: HistoryPersistence?
    @ObservationIgnored private let writer: HistoryWriter?
    @ObservationIgnored private var lastSaved: Date?
    /// Sample appends are published (via `revision`) only when `publishChanges()` is called,
    /// so history doesn't invalidate views that aren't on screen.
    @ObservationIgnored private var hasUnpublishedChanges = false

    init(retention: HistoryRetention, persistence: HistoryPersistence?, now: Date = Date()) {
        self.persistence = persistence
        writer = persistence.map(HistoryWriter.init(persistence:))
        var history = MemoryHistory(retention: retention)
        var events = RingBuffer<MemoryEvent>(capacity: Self.eventCapacity)

        switch persistence?.load() {
        case .loaded(let file):
            history = MemoryHistory(archive: file.history, retention: retention, now: now)
            let cutoff = now.addingTimeInterval(-retention.duration)
            events = RingBuffer(capacity: Self.eventCapacity, elements: file.events.filter { $0.date >= cutoff }.sorted { $0.date < $1.date })
        case .unreadable(let reason):
            loadProblem = reason
        case .missing, .none:
            break
        }
        self.history = history
        self.events = events
        lastSaved = now.addingTimeInterval(Self.firstSaveDelay - Self.saveInterval)
    }

    // MARK: - Recording

    func append(_ point: HistoryPoint) {
        history.append(point)
        hasUnpublishedChanges = true
    }

    /// Bumps `revision` if samples were appended since the last call.
    func publishChanges() {
        guard hasUnpublishedChanges else { return }
        hasUnpublishedChanges = false
        revision &+= 1
    }

    func beginGap(at date: Date, reason: HistoryGap.Reason) {
        history.beginGap(at: date, reason: reason)
        revision &+= 1
    }

    func endGap(at date: Date) {
        history.endGap(at: date)
        revision &+= 1
    }

    func record(_ event: MemoryEvent) {
        events.append(event)
    }

    func setRetention(_ retention: HistoryRetention, now: Date = Date()) {
        history.setRetention(retention, now: now)
        revision &+= 1
        let cutoff = now.addingTimeInterval(-retention.duration)
        events.retain { $0.date >= cutoff }
    }

    /// Erases all history in memory and on disk.
    func clearAll() {
        history.clear()
        events.removeAll()
        revision &+= 1
        if let writer {
            Task { try? await writer.delete() }
        }
    }

    // MARK: - Persistence

    var fileURL: URL? { persistence?.fileURL }

    func storedFileSize() -> UInt64? {
        persistence?.fileSize()
    }

    /// Saves in the background if the save interval has elapsed.
    func saveIfDue(now: Date = Date()) {
        guard let lastSaved, lastSaved.hasElapsed(Self.saveInterval, by: now) else { return }
        save(now: now)
    }

    /// Saves in the background.
    func save(now: Date = Date()) {
        pruneExpired(now: now)
        guard let writer else { return }
        let file = makeFile(now: now)
        lastSaved = now
        Task { try? await writer.save(file) }
    }

    /// Saves on the calling thread; used when the app is about to quit.
    func saveSynchronously(now: Date = Date()) {
        pruneExpired(now: now)
        guard let persistence else { return }
        try? persistence.save(makeFile(now: now))
        lastSaved = now
    }

    /// Drops history and events older than the retention window.
    func pruneExpired(now: Date = Date()) {
        history.prune(now: now)
        let cutoff = now.addingTimeInterval(-history.retention.duration)
        if let oldest = events.first, oldest.date < cutoff {
            events.retain { $0.date >= cutoff }
        }
    }

    private func makeFile(now: Date) -> HistoryFile {
        HistoryFile(history: history.archive(savedAt: now), events: events.elements)
    }
}
