import Foundation

/// Thread-safe circular buffer for Float audio samples.
/// Capacity: 160,000 samples (10 seconds at 16 kHz).
final class AudioRingBuffer {
    static let capacity = 160_000

    private var buffer: [Float]
    private var writeIndex: Int = 0
    private var count: Int = 0
    private let lock = NSLock()

    init() {
        buffer = [Float](repeating: 0, count: Self.capacity)
    }

    /// Writes samples into the ring buffer, overwriting the oldest data when full.
    func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        for sample in samples {
            buffer[writeIndex] = sample
            writeIndex = (writeIndex + 1) % Self.capacity
            if count < Self.capacity {
                count += 1
            }
        }
    }

    /// Returns the next `count` samples in order, or nil if fewer are available.
    func read(count requestedCount: Int) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }

        guard requestedCount > 0, count >= requestedCount else { return nil }

        // readIndex is the oldest sample position
        let readIndex = (writeIndex - count + Self.capacity) % Self.capacity
        var result = [Float](repeating: 0, count: requestedCount)
        for i in 0..<requestedCount {
            result[i] = buffer[(readIndex + i) % Self.capacity]
        }
        return result
    }

    /// Number of samples currently stored.
    var availableCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
