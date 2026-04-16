/// Lock-free single-producer single-consumer ring buffer.
///
/// Lives in the domain because it's a core audio primitive — not an
/// infrastructure concern. The audio thread writes, the writer thread reads.
/// Sized as power-of-2 for fast index masking.

import Foundation

public final class RingBuffer: @unchecked Sendable {
    public let capacity: Int
    private let mask: Int
    private let buffer: UnsafeMutablePointer<Float>
    private let _head = AtomicCounter(0)
    private let _tail = AtomicCounter(0)

    /// Create a ring buffer. Capacity is rounded up to the next power of 2.
    public init(minimumCapacity: Int) {
        var cap = 1
        while cap < minimumCapacity { cap <<= 1 }
        self.capacity = cap
        self.mask = cap - 1
        self.buffer = .allocate(capacity: cap)
        self.buffer.initialize(repeating: 0, count: cap)
    }

    deinit { buffer.deallocate() }

    public var availableToRead: Int { _head.load() - _tail.load() }
    public var availableToWrite: Int { capacity - availableToRead }

    /// Write frames from source. Returns frames actually written.
    /// Called from producer (audio) thread.
    @discardableResult
    public func write(from source: UnsafePointer<Float>, count: Int) -> Int {
        let writable = min(count, availableToWrite)
        guard writable > 0 else { return 0 }

        let head = _head.load()
        let start = head & mask
        let first = min(writable, capacity - start)
        let second = writable - first

        buffer.advanced(by: start).update(from: source, count: first)
        if second > 0 {
            buffer.update(from: source.advanced(by: first), count: second)
        }
        _head.store(head + writable)
        return writable
    }

    /// Read frames into destination. Returns frames actually read.
    /// Called from consumer (writer) thread.
    @discardableResult
    public func read(into destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let readable = min(count, availableToRead)
        guard readable > 0 else { return 0 }

        let tail = _tail.load()
        let start = tail & mask
        let first = min(readable, capacity - start)
        let second = readable - first

        destination.update(from: buffer.advanced(by: start), count: first)
        if second > 0 {
            destination.advanced(by: first).update(from: buffer, count: second)
        }
        _tail.store(tail + readable)
        return readable
    }
}

// MARK: - Atomic Counter

/// Minimal atomic integer for lock-free inter-thread communication.
private final class AtomicCounter: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Int>

    init(_ initial: Int) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: initial)
    }

    deinit { storage.deallocate() }

    func load() -> Int { storage.pointee }
    func store(_ value: Int) { storage.pointee = value }
}
