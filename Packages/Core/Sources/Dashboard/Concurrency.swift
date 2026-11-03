import Foundation
import Synchronization

/// Lets at most `limit` pieces of work run at once; the others wait for their turn, first come, first served.
///
/// One is shared by everything the store does, for git and for the network each, so that the limit of four holds
/// however many refreshes, watcher events and rechecks run at the same time. A turn is taken for one request and given
/// back right after: never wait for a turn while holding one, or four holders that wait would wait forever.
actor Limiter {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    nonisolated func run<T: Sendable, E: Error>(_ work: @Sendable () async throws(E) -> T) async throws(E) -> T {
        await acquire()
        do {
            let result = try await work()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }

    private func acquire() async {
        guard running == limit else {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }  // `release` hands its turn over
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// Runs `work` for each of `items`, `limit` at a time, in a task group, and hands each result to `take` on the main
/// actor as soon as it is there. The work itself runs off the main actor.
///
/// On the main actor, not on an `isolated` parameter: with one, Swift 6.4 runs the body of the task group, and `take`
/// in it, off the caller's actor (measured).
@MainActor
func boundedForEach<Item: Sendable, Result: Sendable>(
    _ items: [Item], limit: Int = 4,
    _ work: @escaping @Sendable (Item) async -> Result, take: (Result) -> Void = { _ in }
) async {
    await withTaskGroup(of: Result.self) { group in
        var next = items.makeIterator()
        for _ in 0..<limit {
            guard let item = next.next() else { break }
            group.addTask { await work(item) }
        }
        while let result = await group.next() {
            take(result)
            if let item = next.next() { group.addTask { await work(item) } }
        }
    }
}

/// Runs `work` in a task of its own at `priority`, and waits for it without lending it the caller's priority.
///
/// Awaiting a task's value raises the task to the priority of whoever waits, and a walk of the whole disk that the main
/// actor waits for would run at user-initiated priority. A continuation is not a task, and passes nothing on.
/// Cancelling the caller cancels the work.
func withoutEscalation<T: Sendable>(priority: TaskPriority, _ work: @escaping @Sendable () async -> T) async -> T {
    let handle = TaskHandle()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            handle.set(Task(priority: priority) { continuation.resume(returning: await work()) })
        }
    } onCancel: {
        handle.cancel()
    }
}

/// A task that may be cancelled before it has been made.
private final class TaskHandle: Sendable {
    private let state = Mutex<(task: Task<Void, Never>?, cancelled: Bool)>((nil, false))

    func set(_ task: Task<Void, Never>) {
        let cancelled = state.withLock { state in
            state.task = task
            return state.cancelled
        }
        if cancelled { task.cancel() }
    }

    func cancel() {
        let task = state.withLock { state in
            state.cancelled = true
            return state.task
        }
        task?.cancel()
    }
}

/// Counts what has arrived from a thread of the file watcher, for the main actor to tell whether it has been handled.
final class Counter: Sendable {
    private let value = Atomic<Int>(0)

    var count: Int { value.load(ordering: .acquiring) }
    func increment() { value.add(1, ordering: .releasing) }
}
