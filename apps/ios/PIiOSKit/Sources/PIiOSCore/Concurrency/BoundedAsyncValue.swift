import Foundation

/// Races a non-throwing asynchronous operation against a wall-clock deadline.
///
/// The operation runs in an unstructured task so this function can return even
/// when the operation itself ignores cancellation. Callers that own a resource
/// such as a network client must still invoke a bounded cleanup after a timeout.
public func boundedAsyncValue<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async -> T
) async -> T? {
    let box = BoundedAsyncRaceBox<T>()
    return await withCheckedContinuation { continuation in
        box.install(continuation)
        let deadline = Task.detached {
            try? await Task.sleep(
                nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)
            )
            _ = box.finish(nil)
        }
        box.setDeadline(deadline)
        Task.detached {
            let value = await operation()
            _ = box.finish(value)
        }
    }
}

private final class BoundedAsyncRaceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var continuation: CheckedContinuation<T?, Never>?
    private var deadline: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<T?, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func setDeadline(_ deadline: Task<Void, Never>) {
        lock.lock()
        let shouldCancel = settled
        if !settled {
            self.deadline = deadline
        }
        lock.unlock()
        if shouldCancel {
            deadline.cancel()
        }
    }

    func finish(_ value: T?) -> Bool {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return false
        }
        settled = true
        let continuation = self.continuation
        self.continuation = nil
        let deadline = self.deadline
        self.deadline = nil
        lock.unlock()
        deadline?.cancel()
        continuation?.resume(returning: value)
        return true
    }
}
