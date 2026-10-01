import Foundation

/// Keychain and file-provider reads can block indefinitely. Keep them off the
/// main actor and bound the caller's wait without awaiting a blocked child task.
public enum CredentialLoader {
    public static func load(timeout: TimeInterval = 5,
                            read: @escaping @Sendable (String) -> String = { KeyStore.read($0) }) async -> [String: String]? {
        await BoundedBackgroundRead.run(timeout: timeout) { expired in
            var values: [String: String] = [:]
            for account in ["gemini", "openai", "jev"] {
                guard !expired() else { return [:] }
                values[account] = read(account)
            }
            return values
        }
    }
}

public enum BoundedBackgroundRead {
    public static func run<Value: Sendable>(timeout: TimeInterval = 5,
        operation: @escaping @Sendable (@Sendable () -> Bool) -> Value) async -> Value? {
        let pending = PendingRead<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pending.install(continuation)
                let seconds = timeout.isFinite ? max(0, timeout) : 5
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { pending.finish(nil) }
                DispatchQueue.global(qos: .userInitiated).async {
                    guard !pending.isFinished else { return }
                    pending.finish(operation { pending.isFinished })
                }
            }
        } onCancel: { pending.finish(nil) }
    }
}

private final class PendingRead<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<Value?, Never>?
    var isFinished: Bool { lock.withLock { finished } }

    func install(_ continuation: CheckedContinuation<Value?, Never>) {
        let cancelled = lock.withLock {
            if finished { return true }
            self.continuation = continuation
            return false
        }
        if cancelled { continuation.resume(returning: nil) }
    }

    func finish(_ result: Value?) {
        let waiting = lock.withLock { () -> CheckedContinuation<Value?, Never>? in
            guard !finished else { return nil }
            finished = true
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(returning: result)
    }
}
