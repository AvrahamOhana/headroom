//
//  RingBuffer.swift
//  NamRig — lock-free SPSC float ring buffer bridging the input (sink) and
//  output (source) real-time render callbacks.
//

import Synchronization

/// Single-producer / single-consumer lock-free float ring buffer.
/// Producer = the input (sink) render callback; consumer = the output (source) render callback.
final class FloatRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0)
    }
    deinit { storage.deallocate() }

    /// Append `count` samples. Called only on the input render thread.
    func write(_ src: UnsafePointer<Float>, count: Int) {
        let w = writeIndex.load(ordering: .relaxed)
        let base = storage.baseAddress!
        for i in 0..<count { base[(w &+ i) % capacity] = src[i] }
        writeIndex.store(w &+ count, ordering: .releasing)
    }

    /// Read `count` samples into `dst`. Returns false (reading nothing) on underrun.
    /// Called only on the output render thread.
    func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        let w = writeIndex.load(ordering: .acquiring)
        let r = readIndex.load(ordering: .relaxed)
        if w &- r < count { return false }
        let base = storage.baseAddress!
        for i in 0..<count { dst[i] = base[(r &+ i) % capacity] }
        readIndex.store(r &+ count, ordering: .releasing)
        return true
    }

    /// Drop all buffered samples (call when (re)starting the engine).
    func reset() {
        readIndex.store(writeIndex.load(ordering: .acquiring), ordering: .releasing)
    }
}
