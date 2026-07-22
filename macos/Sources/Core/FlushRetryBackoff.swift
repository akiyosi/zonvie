import Foundation

/// UI-thread retry cadence for a failed core flush. The caller serializes
/// mutation with its retry-state lock.
struct FlushRetryBackoff {
    static let baseDelaySeconds: TimeInterval = 0.016
    static let maxDelaySeconds: TimeInterval = 2.0

    private(set) var nextDelaySeconds = baseDelaySeconds

    mutating func takeDelaySeconds() -> TimeInterval {
        let delaySeconds = nextDelaySeconds
        nextDelaySeconds = min(nextDelaySeconds * 2, Self.maxDelaySeconds)
        return delaySeconds
    }

    mutating func reset() {
        nextDelaySeconds = Self.baseDelaySeconds
    }
}
