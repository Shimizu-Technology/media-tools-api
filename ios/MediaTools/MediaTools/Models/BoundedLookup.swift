import Foundation

/// Runs a lookup that a screen would like to have before it opens, but must never wait
/// for past a deadline. The wait ends at the deadline whatever the lookup is doing, and
/// a lookup still running carries on so its answer can be used next time, until `cancel`.
///
/// A task group can't do this: leaving a group waits for its children, and cancelling
/// a child that awaits another task's value does not stop the wait.
@MainActor
final class BoundedLookup {
    private var task: Task<Void, Never>?

    func start(_ lookup: @escaping @MainActor () async -> Void) {
        task?.cancel()
        task = Task { await lookup() }
    }

    /// Returns when the lookup finishes, at the deadline, or when the caller is
    /// cancelled, whichever is first.
    func wait(until deadline: ContinuousClock.Instant) async {
        guard let task else { return }
        let finished = AsyncStream<Void> { continuation in
            let lookupWatch = Task {
                await task.value
                continuation.finish()
            }
            let deadlineWatch = Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                lookupWatch.cancel()
                deadlineWatch.cancel()
            }
        }
        for await _ in finished {}
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
