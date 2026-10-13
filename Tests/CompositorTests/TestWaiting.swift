import Foundation

/// Polls `condition` on the main actor until it holds, letting work that lands there (off-main results, deferred
/// tool switches) take its turn in between. False when it never held.
///
/// The deadline only guards against a hang, so it is far longer than any result should take: the whole suite runs at
/// once, sharing the main actor and the cooperative pool, and on a 3-core CI runner a background job can wait behind
/// other tests for most of the run (over a minute has been seen).
@MainActor
func waitUntil(timeout: Duration = .seconds(300), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}
