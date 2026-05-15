import Foundation

// MARK: - Data types

/// A single heart-rate sample captured from HealthKit.
struct HRSample: Sendable {
    let bpm: Double
    let timestamp: Date
}

/// A single point on the stress-derivative chart (BPM/min).
struct StressPoint: Sendable {
    let value: Double   // positive = rising HR, negative = falling HR
    let timestamp: Date
}

/// Authorization state for the HeartRate service.
enum HRAuthorizationStatus: Sendable {
    case notDetermined
    case authorized
    case denied
}

// MARK: - Errors

enum HeartRateServiceError: Error {
    case healthKitUnavailable
    case authorizationDenied
    case queryFailed(underlying: Error)
}

// MARK: - Circular buffer

/// Fixed-capacity FIFO ring buffer. Append is O(1); oldest entry is evicted when full.
struct RingBuffer<T>: Sendable where T: Sendable {
    private var storage: [T?]
    private var writeIndex = 0
    private(set) var count = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        storage = [T?](repeating: nil, count: capacity)
    }

    mutating func append(_ element: T) {
        storage[writeIndex % capacity] = element
        writeIndex += 1
        if count < capacity { count += 1 }
    }

    /// Elements in insertion order (oldest first).
    var elements: [T] {
        guard count > 0 else { return [] }
        if count < capacity {
            return storage.prefix(count).compactMap { $0 }
        }
        let start = writeIndex % capacity
        return (storage[start...] + storage[..<start]).compactMap { $0 }
    }

    mutating func clear() {
        storage = [T?](repeating: nil, count: capacity)
        writeIndex = 0
        count = 0
    }
}

// MARK: - Stress derivative

extension Array where Element == HRSample {
    /// Computes the numerical first derivative of heart rate over the sample window (BPM/min).
    /// Uses central differences in the interior, forward/backward at the endpoints.
    func stressDerivative() -> [StressPoint] {
        guard count >= 2 else { return [] }
        var result = [StressPoint]()
        result.reserveCapacity(count)
        for i in indices {
            let dt: Double
            let dBPM: Double
            if i == startIndex {
                let next = self[index(after: i)]
                dt = next.timestamp.timeIntervalSince(self[i].timestamp)
                dBPM = next.bpm - self[i].bpm
            } else if i == index(before: endIndex) {
                let prev = self[index(before: i)]
                dt = self[i].timestamp.timeIntervalSince(prev.timestamp)
                dBPM = self[i].bpm - prev.bpm
            } else {
                let prev = self[index(before: i)]
                let next = self[index(after: i)]
                dt = next.timestamp.timeIntervalSince(prev.timestamp)
                dBPM = next.bpm - prev.bpm
            }
            guard dt > 0 else { continue }
            // Convert from BPM/s to BPM/min for readability
            result.append(StressPoint(value: dBPM / dt * 60, timestamp: self[i].timestamp))
        }
        return result
    }
}
