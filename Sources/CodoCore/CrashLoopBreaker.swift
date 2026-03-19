import Foundation

/// Circuit breaker for crash-loop detection.
///
/// Tracks consecutive rapid crashes and trips after `maxFailures` within
/// a stability window. If a process survives longer than `stabilityInterval`
/// after starting, the failure counter resets — so only rapid crash-loops
/// (not occasional failures spread over hours) trigger the breaker.
///
/// Thread-safety: all mutations happen on `queue` (serial).
public final class CrashLoopBreaker: @unchecked Sendable {
    /// Maximum consecutive failures before tripping the breaker.
    public let maxFailures: Int

    /// How long a process must stay alive after start to be considered stable.
    /// Once stable, the failure counter resets to 0.
    public let stabilityInterval: TimeInterval

    private let queue = DispatchQueue(label: "codo.crashloop")
    private var failureCount: Int = 0
    private var tripped: Bool = false
    private var stabilityTimer: DispatchWorkItem?

    /// Called on `queue` when the breaker trips (failure count exceeded).
    public var onTripped: (() -> Void)?

    public init(maxFailures: Int = 3, stabilityInterval: TimeInterval = 10.0) {
        self.maxFailures = maxFailures
        self.stabilityInterval = stabilityInterval
    }

    /// Whether the breaker has tripped. Once tripped, `recordStart` is a no-op.
    public var isTripped: Bool {
        queue.sync { tripped }
    }

    /// Current consecutive failure count (for testing/logging).
    public var currentFailureCount: Int {
        queue.sync { failureCount }
    }

    /// Record that the process started successfully.
    /// Starts the stability timer — if it fires without an intervening
    /// `recordFailure`, the failure counter resets.
    public func recordStart() {
        queue.async { [self] in
            guard !tripped else { return }
            cancelTimerUnsafe()

            let timer = DispatchWorkItem { [weak self] in
                self?.queue.async {
                    self?.failureCount = 0
                }
            }
            stabilityTimer = timer
            queue.asyncAfter(
                deadline: .now() + stabilityInterval,
                execute: timer
            )
        }
    }

    /// Record a process failure (unexpected termination).
    /// Returns `true` if the breaker just tripped.
    @discardableResult
    public func recordFailure() -> Bool {
        queue.sync {
            guard !tripped else { return false }
            cancelTimerUnsafe()

            failureCount += 1
            if failureCount > maxFailures {
                tripped = true
                let callback = onTripped
                queue.async { callback?() }
                return true
            }
            return false
        }
    }

    /// Reset the breaker to initial state (e.g., user re-enables Guardian).
    public func reset() {
        queue.sync {
            cancelTimerUnsafe()
            failureCount = 0
            tripped = false
        }
    }

    // Must be called on `queue`.
    private func cancelTimerUnsafe() {
        stabilityTimer?.cancel()
        stabilityTimer = nil
    }
}
