import Foundation

@main
private enum ExternalFontResetStateTests {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    private final class FlushFontResetHarness: @unchecked Sendable {
        let lock = NSLock()
        let notificationStaged = DispatchSemaphore(value: 0)
        let flushCommitted = DispatchSemaphore(value: 0)
        var resetState = ExternalFontResetState(initialGeneration: 1)
        var committedGeneration: UInt64 = 1
        var committedCounts = [12, 18]
    }

    static func main() {
        do {
            var backoff = FlushRetryBackoff()
            require(backoff.takeDelaySeconds() == 0.016, "flush retry did not start at 16ms")
            require(backoff.takeDelaySeconds() == 0.032, "flush retry did not double")
            for _ in 0..<16 {
                _ = backoff.takeDelaySeconds()
            }
            require(backoff.takeDelaySeconds() == 2.0, "flush retry did not saturate at 2s")
            backoff.reset()
            require(backoff.takeDelaySeconds() == 0.016, "successful flush did not reset retry delay")
        }

        // Production ordering: the core stages gen2 before beginFlush. The
        // bracket must adopt gen2 even though its source commit is still gen1,
        // and the delayed main-queue notification must not mutate row storage.
        do {
            let harness = FlushFontResetHarness()
            DispatchQueue.global().async {
                harness.notificationStaged.wait()
                harness.lock.lock()
                let flushGeneration = harness.resetState.beginFlushGeneration(
                    sourceGeneration: harness.committedGeneration
                )
                harness.committedGeneration = harness.resetState.commitGeneration(
                    sourceGeneration: harness.committedGeneration,
                    flushGeneration: flushGeneration,
                    regeneratedRows: 2,
                    totalRows: 2
                )
                harness.committedCounts = [20, 24]
                harness.lock.unlock()
                harness.flushCommitted.signal()
            }
            harness.lock.lock()
            harness.resetState.stage(generation: 2)
            harness.lock.unlock()
            harness.notificationStaged.signal()
            harness.flushCommitted.wait()

            // This is the delayed main-queue delivery of the same change.
            harness.lock.lock()
            harness.resetState.stage(generation: 2)
            harness.lock.unlock()
            require(harness.committedGeneration == 2, "flush published the old font generation")
            require(harness.committedCounts == [20, 24], "new-generation commit was reset")
            require(harness.resetState.isCurrent(committedGeneration: harness.committedGeneration), "new-generation commit remained stale")
        }

        // Cancel/contentless or partial commits keep the source generation and
        // remain logically stale without mutating their row arrays.
        do {
            var state = ExternalFontResetState(initialGeneration: 1)
            state.stage(generation: 2)
            let flushGeneration = state.beginFlushGeneration(sourceGeneration: 1)
            let committedGeneration = state.commitGeneration(
                sourceGeneration: 1,
                flushGeneration: flushGeneration,
                regeneratedRows: 1,
                totalRows: 2
            )
            require(committedGeneration == 1, "partial commit was relabelled as current")
            require(!state.isCurrent(committedGeneration: committedGeneration), "old generation survived partial commit")
        }

        // A delayed main-queue notification after the new commit is harmless.
        do {
            var state = ExternalFontResetState(initialGeneration: 3)
            state.stage(generation: 3)
            require(state.isCurrent(committedGeneration: 3), "delayed notification invalidated current generation")
        }

        print("ExternalGridStateTests: OK")
    }
}
