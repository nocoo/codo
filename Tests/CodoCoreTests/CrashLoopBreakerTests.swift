import Foundation
import Testing
@testable import CodoCore

@Suite("CrashLoopBreaker")
struct CrashLoopBreakerTests {

    @Test("initial state is not tripped")
    func initialState() {
        let breaker = CrashLoopBreaker(maxFailures: 3, stabilityInterval: 10.0)
        #expect(breaker.isTripped == false)
        #expect(breaker.currentFailureCount == 0)
    }

    @Test("single failure does not trip")
    func singleFailure() {
        let breaker = CrashLoopBreaker(maxFailures: 3)
        let tripped = breaker.recordFailure()
        #expect(tripped == false)
        #expect(breaker.isTripped == false)
        #expect(breaker.currentFailureCount == 1)
    }

    @Test("failures at threshold do not trip")
    func failuresAtThreshold() {
        let breaker = CrashLoopBreaker(maxFailures: 3)
        for _ in 0..<3 {
            breaker.recordFailure()
        }
        #expect(breaker.isTripped == false)
        #expect(breaker.currentFailureCount == 3)
    }

    @Test("failures exceeding threshold trip the breaker")
    func failuresExceedThreshold() {
        let breaker = CrashLoopBreaker(maxFailures: 3)
        for _ in 0..<3 {
            breaker.recordFailure()
        }
        let tripped = breaker.recordFailure()
        #expect(tripped == true)
        #expect(breaker.isTripped == true)
        #expect(breaker.currentFailureCount == 4)
    }

    @Test("onTripped callback fires when breaker trips")
    func onTrippedCallback() {
        let breaker = CrashLoopBreaker(maxFailures: 1)
        var callbackFired = false
        breaker.onTripped = { callbackFired = true }

        breaker.recordFailure()
        // First failure at count 1, maxFailures is 1, so count > max trips
        let tripped = breaker.recordFailure()
        #expect(tripped == true)

        // Callback is async on queue, give it a moment
        Thread.sleep(forTimeInterval: 0.05)
        #expect(callbackFired == true)
    }

    @Test("recordFailure after tripped is no-op")
    func failureAfterTripped() {
        let breaker = CrashLoopBreaker(maxFailures: 1)
        breaker.recordFailure()
        breaker.recordFailure() // trips
        #expect(breaker.isTripped == true)

        let result = breaker.recordFailure()
        #expect(result == false) // no-op, already tripped
        #expect(breaker.currentFailureCount == 2) // unchanged
    }

    @Test("recordStart after tripped is no-op")
    func startAfterTripped() {
        let breaker = CrashLoopBreaker(maxFailures: 1)
        breaker.recordFailure()
        breaker.recordFailure()
        #expect(breaker.isTripped == true)

        breaker.recordStart()
        // Should not change tripped state
        #expect(breaker.isTripped == true)
    }

    @Test("reset clears tripped state and failure count")
    func resetBreaker() {
        let breaker = CrashLoopBreaker(maxFailures: 1)
        breaker.recordFailure()
        breaker.recordFailure()
        #expect(breaker.isTripped == true)
        #expect(breaker.currentFailureCount == 2)

        breaker.reset()
        #expect(breaker.isTripped == false)
        #expect(breaker.currentFailureCount == 0)
    }

    @Test("stability timer resets failure count after interval")
    func stabilityTimerResets() async throws {
        // Use a very short stability interval for testing
        let breaker = CrashLoopBreaker(maxFailures: 3, stabilityInterval: 0.1)

        // Record 2 failures (below threshold)
        breaker.recordFailure()
        breaker.recordFailure()
        #expect(breaker.currentFailureCount == 2)

        // Simulate successful start
        breaker.recordStart()

        // Wait for stability timer to fire
        try await Task.sleep(for: .milliseconds(200))

        // Failure count should be reset
        #expect(breaker.currentFailureCount == 0)
        #expect(breaker.isTripped == false)
    }

    @Test("failure before stability timer cancels the timer")
    func failureCancelsStabilityTimer() async throws {
        let breaker = CrashLoopBreaker(maxFailures: 3, stabilityInterval: 0.2)

        breaker.recordFailure()
        breaker.recordStart()

        // Crash before stability timer fires
        try await Task.sleep(for: .milliseconds(50))
        breaker.recordFailure()

        // Wait past the original stability interval
        try await Task.sleep(for: .milliseconds(250))

        // Count should NOT have been reset — timer was cancelled
        #expect(breaker.currentFailureCount == 2)
    }

    @Test("immediate failure after recordStart is counted and timer is cancelled")
    func immediateFailureAfterStart() async throws {
        // Regression: if recordStart() were async, a synchronous recordFailure()
        // right after could execute first, then the queued recordStart() would
        // re-arm the stability timer and later clear the failure — masking a
        // real crash. With recordStart() synchronous, the ordering is guaranteed:
        // start arms timer → failure cancels timer and increments count.
        let breaker = CrashLoopBreaker(maxFailures: 3, stabilityInterval: 0.1)

        breaker.recordStart()
        breaker.recordFailure() // immediate crash
        #expect(breaker.currentFailureCount == 1)

        // Wait past stability interval — timer should have been cancelled
        try await Task.sleep(for: .milliseconds(200))
        #expect(breaker.currentFailureCount == 1) // NOT reset to 0
        #expect(breaker.isTripped == false)
    }

    @Test("rapid crash-loop scenario trips breaker")
    func rapidCrashLoop() {
        let breaker = CrashLoopBreaker(maxFailures: 3, stabilityInterval: 10.0)

        // Simulate 4 rapid crashes with starts that never stabilize
        for i in 1...4 {
            breaker.recordStart()
            let tripped = breaker.recordFailure()
            if i <= 3 {
                #expect(tripped == false)
            } else {
                #expect(tripped == true)
            }
        }
        #expect(breaker.isTripped == true)
    }

    @Test("stable recovery between crashes prevents tripping")
    func stableRecoveryPreventsTripping() async throws {
        let breaker = CrashLoopBreaker(maxFailures: 2, stabilityInterval: 0.05)

        // Crash 1
        breaker.recordStart()
        breaker.recordFailure()
        #expect(breaker.currentFailureCount == 1)

        // Restart and stabilize
        breaker.recordStart()
        try await Task.sleep(for: .milliseconds(100))
        #expect(breaker.currentFailureCount == 0) // reset by stability timer

        // Crash 2 — should not trip because count was reset
        breaker.recordFailure()
        #expect(breaker.currentFailureCount == 1)
        #expect(breaker.isTripped == false)

        // Stabilize again
        breaker.recordStart()
        try await Task.sleep(for: .milliseconds(100))
        #expect(breaker.currentFailureCount == 0)

        // Crash 3 — still not tripped
        breaker.recordFailure()
        #expect(breaker.currentFailureCount == 1)
        #expect(breaker.isTripped == false)
    }
}
