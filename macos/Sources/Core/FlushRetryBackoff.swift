import Foundation

/// UI-thread retry cadence for a failed core flush. The caller serializes
/// mutation with its retry-state lock.
struct FlushRetryBackoff {
    static let baseDelaySeconds: TimeInterval = 0.016
    // Bounds how stale a retry's provisioned row capacity can get. A longer
    // cap lets more nvim redraw content accumulate during the wait, so the
    // eventual retry is already behind the current content again — under
    // sustained fast scroll this became a self-reinforcing loop where the
    // delay itself was the reason capacity never caught up (observed: once
    // the cap was 2.0s, retries stopped converging entirely for seconds at
    // a time). Capped low enough that even worst-case staleness stays
    // small relative to a redraw's typical cadence.
    static let maxDelaySeconds: TimeInterval = 0.128

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
