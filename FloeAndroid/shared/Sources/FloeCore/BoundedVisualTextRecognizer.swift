import Foundation

/// Vision's synchronous work can outlive cancellation. Limit it to one worker
/// and release the caller at the deadline without accumulating queued images.
public final class BoundedVisualTextRecognizer: @unchecked Sendable {
    public struct Result: Sendable {
        public enum Status: String, Sendable { case available, unavailable, timedOut, busy, cancelled }
        public let status: Status
        public let elements: [VisualTextRegion]
    }

    public static let shared = BoundedVisualTextRecognizer()
    private let lock = NSLock()
    private var working = false
    public init() {}

    public func recognize(
        timeout: TimeInterval = 2,
        operation: @escaping @Sendable () throws -> [VisualTextRegion]
    ) async -> Result {
        guard !Task.isCancelled else { return Result(status: .cancelled, elements: []) }
        let admitted = lock.withLock {
            guard !working else { return false }
            working = true
            return true
        }
        guard admitted else { return Result(status: .busy, elements: []) }
        let completion = Completion()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.install(continuation)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) {
                    completion.finish(Result(status: .timedOut, elements: []))
                }
                DispatchQueue.global(qos: .utility).async { [self] in
                    // A cancelled/deadline-expired request need not start Vision.
                    defer { lock.withLock { working = false } }
                    guard !completion.isFinished else { return }
                    let result: Result
                    do { result = Result(status: .available, elements: try operation()) }
                    catch { result = Result(status: .unavailable, elements: []) }
                    completion.finish(result)
                }
            }
        } onCancel: {
            completion.finish(Result(status: .cancelled, elements: []))
        }
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result, Never>?
        private var result: Result?
        var isFinished: Bool { lock.withLock { result != nil } }

        func install(_ value: CheckedContinuation<Result, Never>) {
            let resolved = lock.withLock { () -> Result? in
                if let result { return result }
                continuation = value
                return nil as Result?
            }
            if let resolved { value.resume(returning: resolved) }
        }

        func finish(_ value: Result) {
            let waiting = lock.withLock {
                guard result == nil else { return nil as CheckedContinuation<Result, Never>? }
                result = value
                let waiting = continuation
                continuation = nil
                return waiting
            }
            waiting?.resume(returning: value)
        }
    }
}
