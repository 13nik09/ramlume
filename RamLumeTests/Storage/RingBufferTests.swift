import Foundation
import Testing
@testable import RamLume

@Suite("Ring buffer")
struct RingBufferTests {
    @Test func staysWithinCapacity() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for value in 1...10 {
            buffer.append(value)
            #expect(buffer.count <= 3)
        }
        #expect(buffer.elements == [8, 9, 10])
        #expect(buffer.isFull)
    }

    @Test func keepsChronologicalOrderAfterWrapping() {
        var buffer = RingBuffer<Int>(capacity: 4, elements: 1...6)
        #expect(buffer.elements == [3, 4, 5, 6])
        #expect(buffer.first == 3)
        #expect(buffer.last == 6)
        #expect(buffer[0] == 3)
        #expect(buffer[3] == 6)
        buffer.append(7)
        #expect(Array(buffer) == [4, 5, 6, 7])
    }

    @Test func replaceLastAndRetain() {
        var buffer = RingBuffer<Int>(capacity: 4, elements: 1...6)
        buffer.replaceLast(with: 60)
        #expect(buffer.elements == [3, 4, 5, 60])
        buffer.retain { $0.isMultiple(of: 2) == false || $0 == 60 }
        #expect(buffer.elements == [3, 5, 60])
        buffer.append(70)
        buffer.append(80)
        #expect(buffer.elements == [5, 60, 70, 80])
    }

    @Test func suffixWhileScansFromNewest() {
        let buffer = RingBuffer<Int>(capacity: 5, elements: [1, 5, 2, 6, 7, 8])
        #expect(buffer.suffix { $0 >= 6 } == [6, 7, 8])
        #expect(buffer.suffix { $0 > 100 }.isEmpty)
    }

    @Test func emptyBufferIsSafe() {
        var buffer = RingBuffer<String>(capacity: 2)
        #expect(buffer.isEmpty)
        #expect(buffer.first == nil)
        #expect(buffer.last == nil)
        buffer.replaceLast(with: "x")
        #expect(buffer.isEmpty)
        buffer.append("a")
        buffer.removeAll()
        #expect(buffer.elements.isEmpty)
    }

    @Test func equalityComparesLogicalContents() {
        let wrapped = RingBuffer<Int>(capacity: 3, elements: [0, 1, 2, 3])
        let direct = RingBuffer<Int>(capacity: 3, elements: [1, 2, 3])
        #expect(wrapped == direct)
    }
}
