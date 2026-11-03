import Foundation
import Synchronization

// Time that the tests move, and ways to wait for what the store does in the background.

// MARK: Time

/// A clock that stands still until the test moves it. `sleep` waits until the clock has been moved past its end.
final class FakeClock: Sendable {
    private struct Sleeper {
        let id: UUID
        let until: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Duration = .zero
        var sleepers: [Sleeper] = []
        /// Sleepers that were cancelled before they were noted.
        var cancelled: Set<UUID> = []
    }

    private let state = Mutex(State())

    var sleepers: Int { state.withLock { $0.sleepers.count } }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let early = state.withLock { state -> Bool in
                    if state.cancelled.remove(id) != nil { return true }
                    state.sleepers.append(Sleeper(id: id, until: state.now + duration, continuation: continuation))
                    return false
                }
                if early { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let index = state.sleepers.firstIndex(where: { $0.id == id }) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return state.sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves the clock on by `duration`, waking each sleeper on the way at its time, and waiting each time until
    /// whatever it woke has gone to sleep again (or a second has passed).
    func advance(by duration: Duration) async {
        let end = state.withLock { $0.now } + duration
        while true {
            let woken = state.withLock { state -> Sleeper? in
                let sleepers = state.sleepers
                guard let index = sleepers.indices.min(by: { sleepers[$0].until < sleepers[$1].until }),
                    state.sleepers[index].until <= end
                else { return nil }
                let sleeper = state.sleepers.remove(at: index)
                state.now = sleeper.until
                return sleeper
            }
            guard let woken else { break }
            woken.continuation.resume()
            _ = await poll(timeout: .seconds(1)) { self.sleepers > 0 }
        }
        state.withLock { $0.now = end }
    }
}

// MARK: Waiting

/// Waits until `condition` holds, for `timeout` at the most. Returns whether it did.
func poll(
    timeout: Duration = .seconds(5), isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

/// A door that tasks wait at until the test opens it.
final class Gate: Sendable {
    private let state = Mutex<(open: Bool, waiting: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { continuation in
            let open = state.withLock { state -> Bool in
                if !state.open { state.waiting.append(continuation) }
                return state.open
            }
            if open { continuation.resume() }
        }
    }

    func open() {
        let waiting = state.withLock { state in
            state.open = true
            defer { state.waiting = [] }
            return state.waiting
        }
        for continuation in waiting { continuation.resume() }
    }
}
