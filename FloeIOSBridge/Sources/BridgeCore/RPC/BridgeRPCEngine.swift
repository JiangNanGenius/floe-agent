import Foundation

/// One unit of automation work handed to the device-side executor.
///
/// Arguments stay in memory only. Logs, receipts and operation digests must
/// never echo text fields, URLs or secret-looking arguments.
public struct BridgeRPCInvocation: Sendable, Equatable {
    public let operationID: String
    public let clientID: String
    public let method: String
    public let params: BridgeRPCJSONValue
    public let sensitiveInputGranted: Bool
    public let receivedAt: Date

    public init(operationID: String,
                clientID: String,
                method: String,
                params: BridgeRPCJSONValue,
                sensitiveInputGranted: Bool,
                receivedAt: Date) {
        self.operationID = operationID
        self.clientID = clientID
        self.method = method
        self.params = params
        self.sensitiveInputGranted = sensitiveInputGranted
        self.receivedAt = receivedAt
    }
}

public enum BridgeRPCExecutionOutcome: Sendable, Equatable {
    case success(BridgeRPCJSONValue)
    case failure(BridgeRPCError)
    /// The executor started work but cannot prove the effect. Callers must not
    /// retry automatically and must not claim the action was undone.
    case sideEffectUnknown(code: String, message: String)
}

/// Injected device-side executor. Implementations register once with the app's
/// long-lived registry; starting or stopping the Bridge listener never creates
/// or destroys an executor.
public protocol BridgeRPCExecutor: Sendable {
    var readiness: BridgeRPCEngineReadiness { get }
    var supportedMethods: Set<String> { get }

    /// The executor MUST call `permit.authorizeDispatch()` synchronously
    /// immediately before the first real SDK/engine action, and must return
    /// without acting when it is false. Authorizing after a timeout, stop,
    /// revocation or generation change is refused.
    func execute(_ invocation: BridgeRPCInvocation,
                 permit: BridgeRPCDispatchPermit) async -> BridgeRPCExecutionOutcome
}

/// One-shot, checkable permission to touch the real automation engine. The
/// coordinator invalidates it when the request times out before dispatch or
/// when the service stops; authority/generation checks also run at the moment
/// of authorization.
public final class BridgeRPCDispatchPermit: @unchecked Sendable {
    private let lock = BridgeRPCLock()
    private let isCurrent: @Sendable () -> Bool
    private var cancelled = false
    private var authorized = false

    init(isCurrent: @escaping @Sendable () -> Bool) {
        self.isCurrent = isCurrent
    }

    public var didAuthorize: Bool {
        lock.withLock { authorized }
    }

    public var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    /// Check before every subsequent SDK call in a multi-step action. An
    /// entered SDK call may finish, while the remaining steps are fenced.
    public var canContinueExecution: Bool {
        lock.withLock { !cancelled && isCurrent() }
    }

    /// Called by the engine immediately before real SDK work.
    public func authorizeDispatch() -> Bool {
        lock.lock()
        if cancelled {
            lock.unlock()
            return false
        }
        let allowed = isCurrent()
        if allowed {
            authorized = true
        } else {
            cancelled = true
        }
        lock.unlock()
        return allowed
    }

    /// Fence subsequent work without interrupting an entered SDK call. The
    /// return value distinguishes pre-dispatch from uncertain side effects.
    func cancelIfPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasPending = !authorized
        cancelled = true
        return wasPending
    }
}

public enum BridgeRPCRegistrationOutcome: Sendable, Equatable {
    case registered(generation: UInt64)
    case alreadyRegistered(generation: UInt64)
    case rejected(reason: String)

    public var generation: UInt64? {
        switch self {
        case .registered(let generation), .alreadyRegistered(let generation):
            return generation
        case .rejected:
            return nil
        }
    }
}

public final class BridgeRPCEngineRegistry: @unchecked Sendable {
    private let lock = BridgeRPCLock()
    private var owner: String?
    private var generation: UInt64 = 0
    private var executor: (any BridgeRPCExecutor)?
    private var everRegistered = false
    private var registrations: UInt64 = 0
    private var rejectedAttempts: UInt64 = 0

    public init() {}

    /// The process allows exactly one actual engine registration. The first
    /// owner wins; a repeated call from that same owner is idempotent, and any
    /// other owner (including after unregister) is rejected. There is no
    /// replacement/upgrade path: a new engine requires a new process.
    @discardableResult
    public func register(owner newOwner: String,
                         executor newExecutor: any BridgeRPCExecutor) -> BridgeRPCRegistrationOutcome {
        lock.lock()
        defer { lock.unlock() }
        if let owner, owner == newOwner, executor != nil {
            return .alreadyRegistered(generation: generation)
        }
        if everRegistered {
            rejectedAttempts &+= 1
            return .rejected(reason: "An engine is already registered for this process.")
        }
        everRegistered = true
        owner = newOwner
        generation &+= 1
        registrations &+= 1
        executor = newExecutor
        return .registered(generation: generation)
    }

    /// Clears the current engine binding. The process remains "already
    /// registered", so a later register call is rejected.
    @discardableResult
    public func unregister(owner expectedOwner: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard owner == expectedOwner, executor != nil else { return false }
        owner = nil
        generation &+= 1
        executor = nil
        return true
    }

    public var registrationCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return registrations
    }

    public var rejectedRegistrationCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return rejectedAttempts
    }

    public func snapshot() -> BridgeRPCEngineSnapshot {
        lock.lock()
        let currentOwner = owner
        let currentGeneration = generation
        let currentExecutor = executor
        lock.unlock()
        guard let currentExecutor else {
            return .unregistered
        }
        let reported = currentExecutor.readiness
        let readiness: BridgeRPCEngineReadiness
        switch reported {
        case .ready:
            // The registry owns the generation used by lifecycle fences; an
            // executor cannot claim an arbitrary generation.
            readiness = .ready(generation: currentGeneration)
        case .notReady, .notRegistered:
            readiness = reported
        }
        return BridgeRPCEngineSnapshot(
            owner: currentOwner,
            generation: currentGeneration,
            readiness: readiness,
            supportedMethods: currentExecutor.supportedMethods
        )
    }

    public func currentExecutor() -> (any BridgeRPCExecutor)? {
        lock.lock()
        defer { lock.unlock() }
        return executor
    }
}

public struct BridgeRPCExecutionFence: Sendable, Equatable {
    public let clientID: String
    public let authEpoch: UInt64
    public let clientRevision: UInt64
    public let engineGeneration: UInt64?
    public let serviceEpoch: UInt64

    public init(clientID: String,
                authEpoch: UInt64,
                clientRevision: UInt64,
                engineGeneration: UInt64?,
                serviceEpoch: UInt64) {
        self.clientID = clientID
        self.authEpoch = authEpoch
        self.clientRevision = clientRevision
        self.engineGeneration = engineGeneration
        self.serviceEpoch = serviceEpoch
    }
}

public struct BridgeRPCExecutionResult: Sendable, Equatable {
    public let outcome: BridgeRPCExecutionOutcome
    public let duplicate: Bool
    public let dispatched: Bool
    public let operationID: String

    public init(outcome: BridgeRPCExecutionOutcome,
                duplicate: Bool,
                dispatched: Bool,
                operationID: String) {
        self.outcome = outcome
        self.duplicate = duplicate
        self.dispatched = dispatched
        self.operationID = operationID
    }
}

/// Serializes SDK work, bounds the waiting queue, deduplicates operation IDs and
/// fences stale engine/auth generations before dispatch and before a result is
/// returned. A timeout, stop or revocation is never retried automatically: once
/// work may have started, the ledger records an unknown outcome and a retry is
/// refused rather than replayed.
fileprivate enum TimeoutKind {
    case notDispatched
    case dispatched
}

public actor BridgeRPCExecutionCoordinator {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private enum LedgerEntry {
        case inFlight(digest: String)
        case success(digest: String, result: BridgeRPCJSONValue, bytes: Int)
        case failure(digest: String, error: BridgeRPCError)
        case unknown(digest: String, error: BridgeRPCError)
        case completedNoResult(digest: String)
    }

    private let maxQueued: Int
    private let maxLedgerEntries: Int
    private let maxLedgerBytes: Int
    private let maxSingleResultBytes: Int
    private let executionTimeout: TimeInterval

    private var active = false
    private var waiters: [Waiter] = []
    private var activePermit: BridgeRPCDispatchPermit?
    private var ledger: [String: LedgerEntry] = [:]
    private var ledgerOrder: [String] = []
    private var ledgerBytes = 0

    public init(limits: BridgeRPCLimits = .default) {
        self.maxQueued = limits.maxQueuedAutomationCalls
        self.maxLedgerEntries = limits.maxCompletedOperations
        self.maxLedgerBytes = limits.maxOperationLedgerBytes
        self.maxSingleResultBytes = limits.maxSingleOperationResultBytes
        self.executionTimeout = limits.executionTimeout
    }

    /// Cancels every call still waiting for the serialization slot and
    /// invalidates an active permit that has not reached real dispatch. A
    /// permit that already authorized keeps its slot until the executor
    /// genuinely returns: queued work can never overlap SDK work that is still
    /// running or still waiting on the main actor.
    public func cancelQueued() {
        let pending = waiters
        waiters.removeAll()
        _ = activePermit?.cancelIfPending()
        for waiter in pending {
            waiter.continuation.resume(returning: false)
        }
    }

    public func queuedCount() -> Int {
        waiters.count
    }

    public func isActive() -> Bool {
        active
    }

    public func submit(invocation: BridgeRPCInvocation,
                       paramsDigest: String,
                       executor: any BridgeRPCExecutor,
                       fence: BridgeRPCExecutionFence,
                       isCurrent: @escaping @Sendable () -> Bool) async -> BridgeRPCExecutionResult {
        let key = Self.ledgerKey(clientID: invocation.clientID,
                                 operationID: invocation.operationID)

        switch await acquire() {
        case .queueFull:
            return BridgeRPCExecutionResult(
                outcome: .failure(.queueFull),
                duplicate: false,
                dispatched: false,
                operationID: invocation.operationID
            )
        case .cancelled:
            return BridgeRPCExecutionResult(
                outcome: .failure(.serviceStopping),
                duplicate: false,
                dispatched: false,
                operationID: invocation.operationID
            )
        case .acquired:
            break
        }

        guard isCurrent() else {
            release()
            return BridgeRPCExecutionResult(
                outcome: .failure(.fenced),
                duplicate: false,
                dispatched: false,
                operationID: invocation.operationID
            )
        }

        if let existing = ledger[key] {
            let duplicate = Self.duplicateResult(existing, digest: paramsDigest, invocation: invocation)
            if let duplicate {
                release()
                return duplicate
            }
        }

        ledger[key] = .inFlight(digest: paramsDigest)
        ledgerOrder.append(key)
        trimLedger()

        let permit = BridgeRPCDispatchPermit(isCurrent: isCurrent)
        activePermit = permit
        let box = OutcomeBox()
        let timeoutState = TimeoutState()

        let timeout = DispatchWorkItem {
            let cancelledBeforeDispatch = permit.cancelIfPending()
            let kind: TimeoutKind = cancelledBeforeDispatch ? .notDispatched : .dispatched
            timeoutState.set(kind)
            let outcome: BridgeRPCExecutionOutcome
            switch kind {
            case .notDispatched:
                outcome = .failure(BridgeRPCError(
                    code: BridgeRPCError.executionTimedOut.code,
                    message: "The operation did not start before the deadline; it was not dispatched."
                ))
            case .dispatched:
                outcome = .sideEffectUnknown(
                    code: "execution_timeout",
                    message: "The operation did not finish in time and may have taken effect."
                )
            }
            _ = box.finish(outcome)
        }
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + executionTimeout, execute: timeout)

        let operation = Task {
            var outcome = await executor.execute(invocation, permit: permit)
            if !permit.didAuthorize {
                switch outcome {
                case .success:
                    outcome = .failure(.fenced)
                case .failure, .sideEffectUnknown:
                    break
                }
            }
            await self.finishOperation(
                key: key,
                digest: paramsDigest,
                permit: permit,
                outcome: outcome,
                box: box,
                timeoutState: timeoutState,
                invocation: invocation
            )
        }
        _ = operation

        let outcome = await withTaskCancellationHandler(operation: {
            await box.wait()
        }, onCancel: {
            let pending = permit.cancelIfPending()
            timeoutState.set(pending ? .notDispatched : .dispatched)
            let outcome: BridgeRPCExecutionOutcome = pending
                ? .failure(.serviceStopping)
                : .sideEffectUnknown(code: "cancelled",
                                     message: "The operation was cancelled and may have taken effect.")
            _ = box.finish(outcome)
        })
        timeout.cancel()

        let dispatched = permit.didAuthorize
        return BridgeRPCExecutionResult(outcome: outcome,
                                        duplicate: false,
                                        dispatched: dispatched,
                                        operationID: invocation.operationID)
    }

    private enum AcquireResult {
        case acquired
        case queueFull
        case cancelled
    }

    private func acquire() async -> AcquireResult {
        if !active {
            active = true
            return .acquired
        }
        guard waiters.count < maxQueued else {
            return .queueFull
        }
        let id = UUID()
        let granted = await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: id, continuation: continuation))
        }
        return granted ? .acquired : .cancelled
    }

    private func release() {
        activePermit = nil
        if waiters.isEmpty {
            active = false
        } else {
            let next = waiters.removeFirst()
            next.continuation.resume(returning: true)
        }
    }

    /// Runs after the executor genuinely returns. The serialization slot is
    /// released here, and only here, so a timed-out request cannot let a second
    /// operation overlap SDK work that is still executing.
    private func finishOperation(key: String,
                                 digest: String,
                                 permit: BridgeRPCDispatchPermit,
                                 outcome: BridgeRPCExecutionOutcome,
                                 box: OutcomeBox,
                                 timeoutState: TimeoutState,
                                 invocation: BridgeRPCInvocation) async {
        let claimedByExecutor = box.finish(outcome)
        if claimedByExecutor {
            storeTerminal(key: key, digest: digest, outcome: outcome)
            release()
            return
        }

        // The timeout won the response. The ledger must stay conservative even
        // if the executor ignores the invalidated permit and eventually returns
        // a success.
        switch timeoutState.kind ?? .dispatched {
        case .notDispatched:
            if case .failure = outcome {
                let error = BridgeRPCError(
                    code: BridgeRPCError.executionTimedOut.code,
                    message: "The operation did not start before the deadline; it was not dispatched."
                )
                ledger[key] = .failure(digest: digest, error: error)
            } else {
                // The executor returned a success/unknown after its dispatch
                // permit was invalidated. That violates the executor contract;
                // stay conservative rather than claiming no effect.
                let error = BridgeRPCError(
                    code: BridgeRPCError.operationOutcomeUnknown.code,
                    message: "The operation was interrupted and may already have taken effect. It was not replayed."
                )
                ledger[key] = .unknown(digest: digest, error: error)
            }
        case .dispatched:
            let error = BridgeRPCError(
                code: BridgeRPCError.operationOutcomeUnknown.code,
                message: "The operation was interrupted and may already have taken effect. It was not replayed."
            )
            ledger[key] = .unknown(digest: digest, error: error)
        }
        trimLedger()
        release()
    }

    private func storeTerminal(key: String,
                               digest: String,
                               outcome: BridgeRPCExecutionOutcome) {
        switch outcome {
        case .success(let value):
            let bytes = value.canonicalData().count
            if bytes > maxSingleResultBytes {
                ledger[key] = .completedNoResult(digest: digest)
            } else {
                ledger[key] = .success(digest: digest, result: value, bytes: bytes)
                ledgerBytes += bytes
            }
        case .failure(let error):
            ledger[key] = .failure(digest: digest, error: error)
        case .sideEffectUnknown(let code, let message):
            let error = BridgeRPCError(code: -32013,
                                       message: message,
                                       data: ["reason": .string(code)])
            ledger[key] = .unknown(digest: digest, error: error)
        }
        trimLedger()
    }

    private static func duplicateResult(_ entry: LedgerEntry,
                                        digest: String,
                                        invocation: BridgeRPCInvocation) -> BridgeRPCExecutionResult? {
        switch entry {
        case .inFlight(let existingDigest):
            if existingDigest != digest {
                return result(.failure(.operationIDConflict), duplicate: false,
                              dispatched: false, invocation)
            }
            return result(.failure(.operationInProgress), duplicate: false,
                          dispatched: false, invocation)
        case .success(let existingDigest, let value, _):
            if existingDigest != digest {
                return result(.failure(.operationIDConflict), duplicate: false,
                              dispatched: false, invocation)
            }
            return result(.success(value), duplicate: true, dispatched: false, invocation)
        case .failure(let existingDigest, let error):
            if existingDigest != digest {
                return result(.failure(.operationIDConflict), duplicate: false,
                              dispatched: false, invocation)
            }
            return result(.failure(error), duplicate: true, dispatched: false, invocation)
        case .unknown(let existingDigest, let error):
            if existingDigest != digest {
                return result(.failure(.operationIDConflict), duplicate: false,
                              dispatched: false, invocation)
            }
            return result(.failure(error), duplicate: true, dispatched: false, invocation)
        case .completedNoResult(let existingDigest):
            if existingDigest != digest {
                return result(.failure(.operationIDConflict), duplicate: false,
                              dispatched: false, invocation)
            }
            return result(.failure(.operationAlreadyCompleted), duplicate: true,
                          dispatched: false, invocation)
        }
    }

    private static func result(_ outcome: BridgeRPCExecutionOutcome,
                               duplicate: Bool,
                               dispatched: Bool,
                               _ invocation: BridgeRPCInvocation) -> BridgeRPCExecutionResult {
        BridgeRPCExecutionResult(outcome: outcome,
                                 duplicate: duplicate,
                                 dispatched: dispatched,
                                 operationID: invocation.operationID)
    }

    private static func ledgerKey(clientID: String, operationID: String) -> String {
        clientID + "\u{0}" + operationID
    }

    private func trimLedger() {
        while ledgerOrder.count > maxLedgerEntries || ledgerBytes > maxLedgerBytes {
            var index: Int?
            for (candidate, key) in ledgerOrder.enumerated() {
                if case .inFlight = ledger[key] { continue }
                index = candidate
                break
            }
            guard let index else { break }
            let key = ledgerOrder.remove(at: index)
            if let entry = ledger.removeValue(forKey: key) {
                if case .success(_, _, let bytes) = entry {
                    ledgerBytes = max(0, ledgerBytes - bytes)
                }
            }
        }
    }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = BridgeRPCLock()
    private var value: TimeoutKind?

    func set(_ kind: TimeoutKind) {
        lock.withLock { if value == nil { value = kind } }
    }

    var kind: TimeoutKind? {
        lock.withLock { value }
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let lock = BridgeRPCLock()
    private var finished = false
    private var outcome: BridgeRPCExecutionOutcome?
    private var continuation: CheckedContinuation<BridgeRPCExecutionOutcome, Never>?

    @discardableResult
    func finish(_ outcome: BridgeRPCExecutionOutcome) -> Bool {
        lock.lock()
        if finished {
            lock.unlock()
            return false
        }
        finished = true
        self.outcome = outcome
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: outcome)
        return true
    }

    func wait() async -> BridgeRPCExecutionOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished, let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
