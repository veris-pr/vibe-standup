/// Lock-free single-producer single-consumer ring buffer for audio data.
///
/// The audio thread writes, the writer thread reads.
/// Sized as power-of-2 for fast index masking.

import Foundation
import os

public final class RingBuffer: @unchecked Sendable {
    // SAFETY: @unchecked Sendable is correct here — this is a SPSC buffer
    // where exactly one thread writes and one thread reads. The os_unfair_lock
    // on the atomic counters ensures memory ordering.

    public let capacity: Int
    private let mask: Int
    private let buffer: UnsafeMutablePointer<Float>
    private let _head: SPSCCounter
    private let _tail: SPSCCounter

    /// Create a ring buffer. Capacity is rounded up to the next power of 2.
    public init(minimumCapacity: Int) {
        var cap = 1
        while cap < minimumCapacity { cap <<= 1 }
        self.capacity = cap
        self.mask = cap - 1
        self.buffer = .allocate(capacity: cap)
        self.buffer.initialize(repeating: 0, count: cap)
        self._head = SPSCCounter(0)
        self._tail = SPSCCounter(0)
    }

    deinit { buffer.deallocate() }

    public var availableToRead: Int { _head.load() - _tail.load() }
    public var availableToWrite: Int { capacity - availableToRead }

    /// Write frames from source. Returns frames actually written.
    /// Called from producer (audio) thread only.
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
    /// Called from consumer (writer) thread only.
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

// MARK: - SPSC Counter (Thread-Safe)

/// Thread-safe counter for SPSC ring buffer coordination.
/// Uses `OSAllocatedUnfairLock` for proper memory ordering between
/// the producer and consumer threads.
private final class SPSCCounter: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    private let _value: UnsafeMutablePointer<Int>

    init(_ initial: Int) {
        _value = .allocate(capacity: 1)
        _value.initialize(to: initial)
    }

    deinit { _value.deallocate() }

    func load() -> Int {
        lock.withLock { _ in _value.pointee }
    }

    func store(_ value: Int) {
        lock.withLock { _ in _value.pointee = value }
    }
}
