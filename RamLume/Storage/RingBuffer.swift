import Foundation

/// A fixed-capacity buffer that overwrites its oldest element when full.
///
/// Every in-memory collection that grows over time (history samples, gaps, events) uses this
/// type so RamLume's memory use stays bounded no matter how long it runs.
struct RingBuffer<Element> {
    let capacity: Int
    private var storage: [Element] = []
    /// Index in `storage` of the oldest element once the buffer has wrapped.
    private var head = 0

    init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be positive")
        self.capacity = capacity
    }

    init(capacity: Int, elements: some Sequence<Element>) {
        self.init(capacity: capacity)
        for element in elements {
            append(element)
        }
    }

    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }
    var isFull: Bool { storage.count == capacity }

    /// The element at a logical position, where 0 is the oldest.
    subscript(position: Int) -> Element {
        precondition(position >= 0 && position < storage.count, "RingBuffer index out of range")
        return storage[(head + position) % storage.count]
    }

    var first: Element? { isEmpty ? nil : self[0] }
    var last: Element? { isEmpty ? nil : self[storage.count - 1] }

    mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// Replaces the newest element, if any.
    mutating func replaceLast(with element: Element) {
        guard !storage.isEmpty else { return }
        storage[(head + storage.count - 1) % storage.count] = element
    }

    mutating func removeAll() {
        storage = []
        head = 0
    }

    /// Elements from oldest to newest.
    var elements: [Element] {
        head == 0 ? storage : Array(storage[head...] + storage[..<head])
    }

    /// Keeps only elements matching `predicate`, preserving order.
    mutating func retain(where predicate: (Element) -> Bool) {
        let kept = elements.filter(predicate)
        storage = kept
        head = 0
    }

    /// The suffix of elements (oldest to newest) for which `predicate` holds, scanning from the
    /// newest element backwards and stopping at the first element that fails. Efficient for
    /// time-ordered data: `suffix { $0.date >= cutoff }`.
    func suffix(while predicate: (Element) -> Bool) -> [Element] {
        var result: [Element] = []
        var position = storage.count - 1
        while position >= 0 {
            let element = self[position]
            guard predicate(element) else { break }
            result.append(element)
            position -= 1
        }
        return result.reversed()
    }
}

extension RingBuffer: Sequence {
    func makeIterator() -> IndexingIterator<[Element]> {
        elements.makeIterator()
    }
}

extension RingBuffer: Equatable where Element: Equatable {
    static func == (lhs: RingBuffer, rhs: RingBuffer) -> Bool {
        lhs.capacity == rhs.capacity && lhs.elements == rhs.elements
    }
}

extension RingBuffer: Sendable where Element: Sendable {}
