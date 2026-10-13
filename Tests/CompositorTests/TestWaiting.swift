import Foundation

/// Polls `condition` on the main actor until it holds, letting work that lands there (off-main results, deferred
/// tool switches) take its turn in between. The deadline is generous: the whole suite shares the main actor and can
/// hold it for seconds. False when it never held.
@MainActor
func waitUntil(timeout: Duration = .seconds(60), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}
