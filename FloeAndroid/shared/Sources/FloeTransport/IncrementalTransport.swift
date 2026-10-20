// SPDX-License-Identifier: MPL-2.0
// FloeTransport — narrow shared incremental HTTP transport for platforms
// whose FoundationNetworking lacks `URLSession.bytes(for:)` (Linux build/test
// target and Android product runtime). G02 package P3 (job-ca18980891c043b5).
//
// This is NOT a second networking framework and NOT a mirror of the original
// provider logic: it provides only the missing byte-incremental read
// primitive (bounded `URLSessionDataDelegate` plumbing). All wire parsing
// (SSEParser, WireTranslator, MCP responseSSEData), request building, event
// semantics, redirect/auth policy objects and runtime authority stay in the
// original modules (FloeProviders / FloeTools overlay copies). Apple
// platforms never take this path: the shipped bytes(for:) streaming stays
// byte-identical.
//
// Boundaries enforced here (TRANSPORT_HANDOFF.md + Main draft review):
// - Non-stream collect enforces `maxBytes` by CANCELLING the owned task at
//   the moment the limit is crossed (declared or observed), never by
//   downloading the whole body and checking afterwards.
// - Stream mode keeps a bounded IN-FLIGHT byte queue. A saturated queue
//   cancels the owned task and surfaces an EXPLICIT recoverable
//   `pendingBufferSaturated` error; already-queued bytes drain first. No
//   silent drops, no per-chunk Task fan-out: exactly one producer Task per
//   request sits downstream of the delegate callback.
// - Cancellation, timeout, EOF and network errors terminate exactly ONCE;
//   later delegate callbacks are fenced (dropped).
// - Session ownership is preserved: streaming-capable sessions are created
//   with the caller's own URLSessionConfiguration and the caller's ORIGINAL
//   policy delegate; a plain injected session fails closed
//   (`sessionNotStreamable`) instead of being silently recreated. Reads never
//   invalidate a session.
// - Authentication/trust: every task-level and session-level authentication
//   challenge callback is FORWARDED to the caller's original policy delegate
//   when one exists (custom trust/pinning decisions keep their authority —
//   an original rejection must stay a rejection). The platform default
//   (.performDefaultHandling — certificate/hostname validation, nothing
//   looser) applies only when no original handler exists. No trust decision
//   or bypass is invented here.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - typed recoverable errors

/// Explicit transport outcomes. Every case is recoverable at the call site
/// (the runtime decides retry/report); none of them is a silent truncation.
public enum IncrementalTransportError: Error, Sendable, Equatable {
    /// Body bytes crossed `maxBytes` (declared or observed). The owned task
    /// was cancelled as soon as the limit was crossed.
    case responseTooLarge(maxBytes: Int)
    /// The bounded in-flight queue exceeded its byte ceiling because the
    /// downstream consumer stalled. The owned task was cancelled; committed
    /// bytes are drained before this error surfaces.
    case pendingBufferSaturated(maxBufferedBytes: Int)
    /// The provided session has no transport delegate. The request is NOT
    /// moved onto a recreated session; the caller keeps ownership and must
    /// either use a streaming-capable session (explicit construction seam:
    /// `StreamingTransport.makeSession(configuration:redirectPolicy:)`) or
    /// handle the failure.
    case sessionNotStreamable(reason: String)
    /// The response could not be represented as an HTTPURLResponse.
    case noHTTPResponse
}

// MARK: - bounded async relay (callback -> parser -> consumer chain)

/// FIFO relay with an explicit pending bound.
/// - `trySend` never suspends (safe on a delegate callback thread) and
///   reports saturation/fence as an immediate false so the owner can cancel
///   the owned task with an explicit recoverable error.
/// - `send` suspends while full: true backpressure, never a silent drop.
/// - Committed elements ALWAYS drain ahead of the terminal outcome.
/// Continuation resumptions never happen while the lock is held.
public final class BoundedAsyncRelay<Element: Sendable>: @unchecked Sendable {
    private enum Slot {
        case value(Element)
        case end
        case failure(Error)
    }
    private enum SendAction {
        case fenced, full, buffered
        case handOff(Element, CheckedContinuation<Slot, Never>)
    }

    private let lock = NSLock()
    private let maxCount: Int
    private let maxBytes: Int
    private let byteCount: (@Sendable (Element) -> Int)?
    private var items: [Element] = []
    private var bufferedBytes = 0
    private var terminal: Slot?
    private var nextWaiters: [CheckedContinuation<Slot, Never>] = []
    private var roomWaiters: [CheckedContinuation<Bool, Never>] = []
    /// Idempotent owner hook invoked when the CONSUMER task cancels
    /// (cancels the owned URLSession task and fences the relay).
    public var onConsumerCancel: (@Sendable () -> Void)?

    public init(maxCount: Int,
                maxBytes: Int = .max,
                byteCount: (@Sendable (Element) -> Int)? = nil) {
        precondition(maxCount > 0 && maxBytes > 0)
        self.maxCount = maxCount
        self.maxBytes = maxBytes
        self.byteCount = byteCount
    }

    public var pendingCount: Int { lock.withLock { items.count } }
    public var pendingBytes: Int { lock.withLock { bufferedBytes } }

    private func bytes(of element: Element) -> Int {
        byteCount?(element) ?? 1
    }

    private func fullLocked(_ incoming: Int) -> Bool {
        items.count + 1 > maxCount || bufferedBytes + incoming > maxBytes
    }

    /// Non-suspending producer for delegate callbacks. Returns false when
    /// fenced OR saturated; the caller must then cancel the owned task and
    /// terminate with an explicit recoverable error. A waiting consumer
    /// receives this element directly (FIFO order: the queue was empty
    /// whenever a consumer is waiting, because `next` pops before parking).
    public func trySend(_ element: Element) -> Bool {
        let action: SendAction = lock.withLock {
            if terminal != nil { return .fenced }
            let incoming = bytes(of: element)
            if fullLocked(incoming) { return .full }
            if let waiter = popHandOffLocked() {
                return .handOff(element, waiter)
            }
            items.append(element)
            bufferedBytes += incoming
            return .buffered
        }
        switch action {
        case .fenced, .full:
            return false
        case .buffered:
            return true
        case .handOff(let value, let waiter):
            waiter.resume(with: .success(.value(value)))
            return true
        }
    }

    /// Awaiting producer: suspends while the relay is full (backpressure).
    /// Returns false if the relay terminated before a slot freed up.
    public func send(_ element: Element) async -> Bool {
        let incoming = bytes(of: element)
        while true {
            let action: SendAction = lock.withLock {
                if terminal != nil { return .fenced }
                if let waiter = popHandOffLocked() {
                    return .handOff(element, waiter)
                }
                if !fullLocked(incoming) {
                    items.append(element)
                    bufferedBytes += incoming
                    return .buffered
                }
                return .full
            }
            switch action {
            case .fenced:
                return false
            case .buffered:
                return true
            case .handOff(let value, let waiter):
                waiter.resume(with: .success(.value(value)))
                return true
            case .full:
                let woke = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    let fencedNow: Bool = lock.withLock {
                        if terminal != nil { return true }
                        roomWaiters.append(cont)
                        return false
                    }
                    if fencedNow { cont.resume(returning: false) }
                }
                // false only from the terminate flush; true means a slot
                // freed — the loop re-checks room (another producer may
                // have taken it) or sees the fence on the next pass.
                if !woke { return false }
            }
        }
    }

    /// When a consumer is already parked the queue is empty, so the incoming
    /// element goes straight to the oldest waiter. Caller holds the lock.
    private func popHandOffLocked() -> CheckedContinuation<Slot, Never>? {
        guard !nextWaiters.isEmpty else { return nil }
        precondition(items.isEmpty, "consumer waiter parked with buffered items")
        return nextWaiters.removeFirst()
    }

    /// Deliver the terminal outcome exactly once. Returns false when a
    /// terminal already exists (late callback fenced).
    @discardableResult
    public func terminate(_ result: Result<Void, Error>) -> Bool {
        let first: Bool = lock.withLock {
            if terminal != nil { return false }
            switch result {
            case .success: terminal = .end
            case .failure(let error): terminal = .failure(error)
            }
            return true
        }
        guard first else { return false }
        let (nexts, rooms) = lock.withLock {
            let n = nextWaiters, r = roomWaiters
            nextWaiters = []
            roomWaiters = []
            return (n, r)
        }
        // Consumers parked only while the queue was empty, so each sees the
        // terminal. Committed items (none in this state) would drain first
        // through the normal `next` pop path.
        for waiter in nexts {
            let slot: Slot = lock.withLock {
                if !items.isEmpty {
                    let value = items.removeFirst()
                    bufferedBytes -= bytes(of: value)
                    return .value(value)
                }
                return terminal ?? .end
            }
            waiter.resume(with: .success(slot))
        }
        for waiter in rooms { waiter.resume(returning: false) }
        return true
    }

    /// Consumer side: committed elements first, then `nil` (EOF) or the
    /// terminal error. Consumer cancellation runs `onConsumerCancel`
    /// (idempotent) so the owned request stops and no further data arrives.
    public func next() async throws -> Element? {
        try await withTaskCancellationHandler {
            try await nextUncancelled()
        } onCancel: {
            onConsumerCancel?()
        }
    }

    private func nextUncancelled() async throws -> Element? {
        if Task.isCancelled { onConsumerCancel?() }
        let slot: Slot = await withCheckedContinuation { (cont: CheckedContinuation<Slot, Never>) in
            let roomWake: CheckedContinuation<Bool, Never>? = lock.withLock {
                if !items.isEmpty {
                    let value = items.removeFirst()
                    bufferedBytes -= bytes(of: value)
                    cont.resume(with: .success(.value(value)))
                    if !roomWaiters.isEmpty { return roomWaiters.removeFirst() }
                    return nil
                }
                if let terminal {
                    cont.resume(with: .success(terminal))
                    return nil
                }
                nextWaiters.append(cont)
                return nil
            }
            if let roomWake { roomWake.resume(returning: true) }
        }
        switch slot {
        case .value(let element): return element
        case .end: return nil
        case .failure(let error): throw error
        }
    }
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

// MARK: - transport sink (one per owned request)

/// Per-request delegate state machine. All mutation happens under one lock;
/// every delegate method collects continuation resumptions and performs them
/// AFTER unlocking (NSLock is not recursive and resumption may run inline).
/// The terminal is recorded exactly once and later callbacks are fenced.
/// Cancellation always goes through the SAME owned `URLSessionTask` handle
/// that produced the data — never a session-wide teardown.
final class TransportSink: @unchecked Sendable {
    enum Mode {
        case collect(maxBytes: Int)
        case stream(maxBufferedBytes: Int)
    }

    enum SinkResponse {
        case response(URLResponse)
        case completedWithoutResponse
    }
    private typealias SinkResult = Result<(Data, URLResponse), Error>

    private let lock = NSLock()
    private let mode: Mode
    private var task: URLSessionTask?
    private var response: URLResponse?
    private var responsePending: SinkResponse?
    private var collected = Data()
    private var terminalDelivered = false
    private var fenced = false
    private var pendingResponseWaiter: CheckedContinuation<SinkResponse, Never>?
    private var pendingCollectWaiter: CheckedContinuation<(Data, URLResponse), Error>?
    private var pendingCollectResult: SinkResult?
    let terminalCounter = TerminalCounter()

    /// Stream mode publishes bytes through this relay; collect mode ignores
    /// it (the relay exists but is never sent through).
    let relay: BoundedAsyncRelay<Data>

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .collect(let maxBytes):
            relay = BoundedAsyncRelay<Data>(maxCount: 1, maxBytes: maxBytes,
                                            byteCount: { $0.count })
        case .stream(let maxBuffered):
            relay = BoundedAsyncRelay<Data>(maxCount: 64, maxBytes: maxBuffered,
                                            byteCount: { $0.count })
        }
        relay.onConsumerCancel = { [weak self] in self?.cancelOwned() }
    }

    final class TerminalCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    func attach(task: URLSessionTask) {
        let cancelNow: Bool = lock.withLock {
            self.task = task
            return fenced || terminalDelivered
        }
        if cancelNow { task.cancel() }
    }

    // MARK: delegate entry points

    /// Decision callback (completion-handler variant). The informational sync
    /// variant may fire FIRST on Darwin; capturing the header there never
    /// consumes the decision, so a genuine decision call still proceeds.
    func handleResponse(_ httpResponse: URLResponse,
                        completion: @escaping (URLSession.ResponseDisposition) -> Void) {
        var responseWake: (CheckedContinuation<SinkResponse, Never>, SinkResponse)?
        let decision: URLSession.ResponseDisposition = lock.withLock {
            if terminalDelivered {
                // Already terminated (cap, saturation, cancel, complete):
                // stop reading; the consumer outcome is fixed.
                return .cancel
            }
            if response == nil {
                response = httpResponse
                responsePending = .response(httpResponse)
                if let waiter = pendingResponseWaiter {
                    pendingResponseWaiter = nil
                    responseWake = (waiter, .response(httpResponse))
                    responsePending = nil
                }
            }
            if case .collect(let maxBytes) = mode,
               httpResponse.expectedContentLength > Int64(maxBytes) {
                recordCollectLocked(.failure(IncrementalTransportError.responseTooLarge(maxBytes: maxBytes)))
                return .cancel
            }
            // Stream mode: total volume is unbounded BY DESIGN (exactly like
            // the original bytes(for:) path); the IN-FLIGHT queue is the
            // bound, so the body is allowed through.
            return .allow
        }
        if let responseWake { responseWake.0.resume(with: .success(responseWake.1)) }
        drainCollectWaiter()
        completion(decision)
    }

    /// Read-only notification variant (Darwin may call it before the decision
    /// callback). It only captures the header — it never decides.
    func syncHandleResponse(_ httpResponse: URLResponse) {
        var responseWake: (CheckedContinuation<SinkResponse, Never>, SinkResponse)?
        lock.withLock {
            if terminalDelivered { return }
            if response == nil {
                response = httpResponse
                if let waiter = pendingResponseWaiter {
                    pendingResponseWaiter = nil
                    responseWake = (waiter, .response(httpResponse))
                } else {
                    responsePending = .response(httpResponse)
                }
            }
        }
        if let responseWake { responseWake.0.resume(with: .success(responseWake.1)) }
    }

    func handleData(_ data: Data) {
        if data.isEmpty { return }
        switch mode {
        case .collect(let maxBytes):
            let reject: Bool = lock.withLock {
                if terminalDelivered { return false }  // fenced late callback
                if collected.count + data.count > maxBytes {
                    recordCollectLocked(.failure(IncrementalTransportError.responseTooLarge(maxBytes: maxBytes)))
                    return true
                }
                collected.append(data)
                return false
            }
            if reject {
                drainCollectWaiter()
                cancelTask()
            }
        case .stream(let maxBuffered):
            if relay.trySend(data) { return }
            var streamError: Error?
            let saturated: Bool = lock.withLock {
                if terminalDelivered { return false }  // race: already fenced
                recordStreamTerminalLocked(IncrementalTransportError
                    .pendingBufferSaturated(maxBufferedBytes: maxBuffered))
                streamError = IncrementalTransportError
                    .pendingBufferSaturated(maxBufferedBytes: maxBuffered)
                return true
            }
            if saturated {
                // Fence recorded under the sink lock; the relay keeps
                // committed chunks drainable and surfaces the explicit
                // recoverable error AFTER them.
                relay.terminate(.failure(streamError!))
                wakeResponseWaitersLockedFree()
                cancelTask()
            }
        }
    }

    func handleCompletion(_ error: Error?) {
        var streamTerminal: Result<Void, Error>?
        let recorded: Bool = lock.withLock {
            if terminalDelivered { return false }
            switch mode {
            case .collect:
                if let error {
                    recordCollectLocked(.failure(error))
                } else if let response {
                    recordCollectLocked(.success((collected, response)))
                } else {
                    recordCollectLocked(.failure(IncrementalTransportError.noHTTPResponse))
                }
            case .stream:
                streamTerminal = error.map { Result<Void, Error>.failure($0) } ?? .success(())
                recordStreamTerminalLocked(error)
            }
            return true
        }
        if recorded {
            drainCollectWaiter()
            if let streamTerminal { relay.terminate(streamTerminal) }
            wakeResponseWaitersLockedFree()
        }
    }

    func handleSessionInvalidated() {
        let recorded: Bool = lock.withLock {
            if terminalDelivered { return false }
            switch mode {
            case .collect:
                recordCollectLocked(.failure(URLError(.cancelled)))
            case .stream:
                recordStreamTerminalLocked(URLError(.cancelled))
            }
            return true
        }
        if recorded {
            drainCollectWaiter()
            if case .stream = mode { relay.terminate(.failure(URLError(.cancelled))) }
            wakeResponseWaitersLockedFree()
        }
    }

    /// Consumer-driven cancellation: fence FIRST (late callbacks dropped),
    /// cancel the owned task, terminate with CancellationError. Committed
    /// queue content still drains before the error surfaces. Idempotent.
    func cancelOwned() {
        let recorded: Bool = lock.withLock {
            if terminalDelivered { return false }
            switch mode {
            case .collect:
                recordCollectLocked(.failure(CancellationError()))
            case .stream:
                recordStreamTerminalLocked(CancellationError())
            }
            return true
        }
        if recorded {
            drainCollectWaiter()
            if case .stream = mode { relay.terminate(.failure(CancellationError())) }
            wakeResponseWaitersLockedFree()
        }
        cancelTask()
    }

    // MARK: consumer entry points

    func waitForCollect() async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
                let settled: SinkResult? = lock.withLock {
                    if let result = pendingCollectResult {
                        pendingCollectResult = nil
                        return result
                    }
                    if terminalDelivered {
                        return .failure(URLError(.cancelled))
                    }
                    pendingCollectWaiter = cont
                    return nil
                }
                if let settled { cont.resume(with: settled) }
            }
        } onCancel: {
            cancelOwned()
        }
    }

    func waitForResponse() async throws -> URLResponse {
        let outcome: SinkResponse = await withCheckedContinuation { (cont: CheckedContinuation<SinkResponse, Never>) in
            let settled: SinkResponse? = lock.withLock {
                if let pending = responsePending {
                    responsePending = nil
                    return pending
                }
                if terminalDelivered {
                    if let response { return .response(response) }
                    return .completedWithoutResponse
                }
                pendingResponseWaiter = cont
                return nil
            }
            if let settled { cont.resume(with: .success(settled)) }
        }
        switch outcome {
        case .response(let httpResponse): return httpResponse
        case .completedWithoutResponse: throw IncrementalTransportError.noHTTPResponse
        }
    }

    var terminalCount: Int { terminalCounter.value }

    // MARK: locked helpers (caller must hold `lock`)

    private func recordCollectLocked(_ result: SinkResult) {
        terminalDelivered = true
        fenced = true
        terminalCounter.bump()
        pendingCollectResult = result
    }

    private func recordStreamTerminalLocked(_ error: Error?) {
        terminalDelivered = true
        fenced = true
        terminalCounter.bump()
    }

    // MARK: unlocked drain helpers

    /// Resume a parked consumer with the recorded terminal result. When no
    /// waiter exists yet the result STAYS recorded and `waitForCollect`
    /// takes it directly (single-consumer invariant per request).
    private func drainCollectWaiter() {
        let handoff: (CheckedContinuation<(Data, URLResponse), Error>, SinkResult)? = lock.withLock {
            guard let waiter = pendingCollectWaiter, let result = pendingCollectResult else {
                return nil
            }
            pendingCollectWaiter = nil
            pendingCollectResult = nil
            return (waiter, result)
        }
        if let handoff { handoff.0.resume(with: handoff.1) }
    }

    private func wakeResponseWaitersLockedFree() {
        let wake: (CheckedContinuation<SinkResponse, Never>, SinkResponse)? = lock.withLock {
            guard let waiter = pendingResponseWaiter else { return nil }
            pendingResponseWaiter = nil
            if let response { return (waiter, .response(response)) }
            return (waiter, .completedWithoutResponse)
        }
        if let wake { wake.0.resume(with: .success(wake.1)) }
    }

    private func cancelTask() {
        let taskHandle: URLSessionTask? = lock.withLock { task }
        taskHandle?.cancel()
    }
}

// MARK: - redirect origin policy (closed Main decision, 2026-10-19)

/// The production redirect security boundary for provider/MCP traffic.
///
/// Foundation (and swift-corelibs FoundationNetworking) hands the delegate a
/// `newRequest` for the redirect target. The router must compare the
/// REDIRECTING RESPONSE origin with the ACTUAL target origin per hop:
/// scheme + canonical host (case/trailing-dot normalized) + effective port
/// (explicit or 80/443 default). A same-origin redirect preserves the
/// caller's headers verbatim. An origin change refuses HTTPS -> HTTP and
/// strips every header except a small explicit allowlist of ordinary
/// representation/negotiation/cache headers that cannot carry configured
/// credentials. This is applied to the FINAL accepted request, including a
/// request returned (or re-populated) by the caller's policy delegate. No
/// trust decision, permission or second HTTP stack is introduced here.
enum TransportRedirectPolicy {
    struct Origin: Equatable, Sendable {
        let scheme: String
        let host: String
        let port: Int
    }

    /// Conservative cross-origin allowlist. Credential-bearing headers
    /// (Authorization, Proxy-Authorization, x-api-key/api-key,
    /// x-goog-api-key, Cookie, ...) and every opaque/custom `X-*` header are
    /// deliberately absent; adding a name here is a security decision.
    static let crossOriginAllowedHeaders: Set<String> = [
        "accept", "accept-encoding", "accept-language",
        "cache-control", "content-type", "pragma",
        "range", "if-match", "if-none-match", "if-modified-since",
        "if-unmodified-since", "if-range",
    ]

    /// RFC-style origin identity. Default ports collapse (`https://x:443` ==
    /// `https://x`), host case and a trailing root dot are normalized, and
    /// non-HTTP(S) targets are not redirectable by this transport.
    static func origin(of url: URL?) -> Origin? {
        guard let url,
              let rawScheme = url.scheme?.lowercased(),
              let rawHost = url.host?.lowercased(), !rawHost.isEmpty else {
            return nil
        }
        let defaultPort: Int
        switch rawScheme {
        case "http": defaultPort = 80
        case "https": defaultPort = 443
        default: return nil
        }
        var host = rawHost
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }
        return Origin(scheme: rawScheme, host: host, port: url.port ?? defaultPort)
    }

    /// Returns the request that may actually be sent, or nil to refuse the
    /// redirect (the 3xx then surfaces as the final response). A nil input
    /// stays nil. Unknown previous origins sanitize conservatively; only a
    /// proven same-origin pair keeps the caller's headers untouched.
    static func sanitize(_ request: URLRequest?, previousURL: URL?) -> URLRequest? {
        guard let request else { return nil }
        guard let target = origin(of: request.url) else { return nil }
        guard let previous = origin(of: previousURL) else {
            return strippingCrossOriginHeaders(from: request)
        }
        if previous == target { return request }
        if previous.scheme == "https" && target.scheme == "http" {
            return nil
        }
        return strippingCrossOriginHeaders(from: request)
    }

    private static func strippingCrossOriginHeaders(from request: URLRequest) -> URLRequest {
        var sanitized = request
        // Foundation keeps some headers (notably Authorization) in special
        // fields that the `allHTTPHeaderFields =` setter does not clear on
        // Darwin. Remove every non-allowlisted field explicitly so a
        // credential can never survive the convenience-setter merge.
        for name in (request.allHTTPHeaderFields ?? [:]).keys
            where !crossOriginAllowedHeaders.contains(name.lowercased()) {
            sanitized.setValue(nil, forHTTPHeaderField: name)
        }
        // Defense in depth for special fields that may be absent from the
        // public header dictionary on a given Foundation build.
        for name in ["Authorization", "Proxy-Authorization", "Cookie"] {
            sanitized.setValue(nil, forHTTPHeaderField: name)
        }
        return sanitized
    }
}

/// Exactly-once completion guard for the redirect callback. A policy delegate
/// that misbehaves (calls the handler twice) can never double-resume the
/// URLSession task.
private final class RedirectCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let handler: @Sendable (URLRequest?) -> Void

    init(_ handler: @escaping @Sendable (URLRequest?) -> Void) {
        self.handler = handler
    }

    func complete(_ request: URLRequest?) {
        lock.lock()
        if completed {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        handler(request)
    }
}

// MARK: - router delegate (one per streaming-capable session)

/// Session-level delegate that routes callbacks to the per-request sink and
/// forwards BOTH redirection and authentication/trust decisions to the
/// ORIGINAL caller policy object. Without a policy object the callbacks
/// behave exactly like the stock session (follow redirects;
/// .performDefaultHandling for trust — never a looser custom decision).
/// Registered sinks are held strongly only between resume() and the task's
/// own didComplete; the session is never invalidated by a read.
final class TransportRouter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sinks: [Int: TransportSink] = [:]
    let policyDelegate: (any URLSessionTaskDelegate)?
    let refuseAllRedirects: Bool

    init(policyDelegate: (any URLSessionTaskDelegate)?, refuseAllRedirects: Bool) {
        self.policyDelegate = policyDelegate
        self.refuseAllRedirects = refuseAllRedirects
        super.init()
    }

    func attach(_ sink: TransportSink, to task: URLSessionTask) {
        lock.withLock { sinks[task.taskIdentifier] = sink }
        sink.attach(task: task)
    }

    private func sink(for task: URLSessionTask) -> TransportSink? {
        lock.withLock { sinks[task.taskIdentifier] }
    }

    private func detach(_ task: URLSessionTask) -> TransportSink? {
        lock.withLock { sinks.removeValue(forKey: task.taskIdentifier) }
    }

    // MARK: data flow

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let responseSink = sink(for: dataTask) else {
            completionHandler(.cancel); return
        }
        responseSink.handleResponse(response, completion: completionHandler)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse) {
        sink(for: dataTask)?.syncHandleResponse(response)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        sink(for: dataTask)?.handleData(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        detach(task)?.handleCompletion(error)
    }

    // MARK: original policy forwarding

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // Compare THIS hop's redirecting response origin with the ACTUAL
        // target request origin. The gate sanitizes every accepted request,
        // including one returned/re-populated by the policy delegate, and
        // guarantees the completion fires at most once.
        let previousURL = response.url
        let gate = RedirectCompletionGate(completionHandler)
        if let policy = policyDelegate {
            #if canImport(ObjectiveC)
            // Darwin: @objc optional. Forward through optional chaining; a
            // policy object that genuinely does not implement it must not
            // hang the task, so fall back to the sanitized original request.
            let forwarded = policy.urlSession?(session, task: task,
                                               willPerformHTTPRedirection: response,
                                               newRequest: request) { accepted in
                gate.complete(TransportRedirectPolicy.sanitize(
                    accepted, previousURL: previousURL))
            }
            if forwarded == nil {
                gate.complete(TransportRedirectPolicy.sanitize(
                    request, previousURL: previousURL))
            }
            #else
            // FoundationNetworking: the requirement is always dispatched.
            // MCPNoRedirectSessionDelegate answers completionHandler(nil),
            // which surfaces the 3xx itself as the final response (fail
            // closed, exactly like the original production session).
            policy.urlSession(session, task: task,
                              willPerformHTTPRedirection: response,
                              newRequest: request) { accepted in
                gate.complete(TransportRedirectPolicy.sanitize(
                    accepted, previousURL: previousURL))
            }
            #endif
            return
        }
        if refuseAllRedirects {
            gate.complete(nil)
            return
        }
        // No policy object: stock follow, but never across a credential
        // boundary without stripping, and never HTTPS -> HTTP.
        gate.complete(TransportRedirectPolicy.sanitize(
            request, previousURL: previousURL))
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Task-level challenges follow the ORIGINAL plain-delegate precedence:
        // the policy object's task-level handler, else its SESSION-level
        // handler (the classic server-trust/pinning pattern implements only
        // the session level and still received task challenges), else the
        // platform default. The router must not swallow either tier.
        if let policy = policyDelegate {
            #if canImport(ObjectiveC)
            if policy.urlSession?(session, task: task, didReceive: challenge,
                                  completionHandler: completionHandler) == nil,
               policy.urlSession?(session, didReceive: challenge,
                                  completionHandler: completionHandler) == nil {
                completionHandler(.performDefaultHandling, nil)
            }
            #else
            // FoundationNetworking dispatches through the protocol witness:
            // a policy overriding the task-level requirement is honored here;
            // otherwise the default implementations perform the platform
            // default — the same outcome the original plain
            // `URLSession(configuration:delegate:)` produced.
            policy.urlSession(session, task: task, didReceive: challenge,
                              completionHandler: completionHandler)
            #endif
            return
        }
        // No original handler: the platform's DEFAULT trust decision (full
        // certificate/hostname validation) is what production had without a
        // custom delegate. This transport adds no trust of its own.
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Session-level challenges: forward to the policy object's OWN
        // session-level handler when present. Bypassing it would silently
        // replace an original rejection (e.g. pinning or client-cert policy)
        // with default handling — exactly what the header forbids.
        if let policy = policyDelegate {
            #if canImport(ObjectiveC)
            if policy.urlSession?(session, didReceive: challenge,
                                  completionHandler: completionHandler) == nil {
                completionHandler(.performDefaultHandling, nil)
            }
            #else
            policy.urlSession(session, didReceive: challenge,
                              completionHandler: completionHandler)
            #endif
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        let all: [TransportSink] = lock.withLock {
            let values = Array(sinks.values)
            sinks.removeAll()
            return values
        }
        for value in all { value.handleSessionInvalidated() }
    }
}

// MARK: - session registry

/// Streaming-capable sessions are exactly those created through
/// `StreamingTransport.makeSession` (Foundation installs the data delegate
/// at session creation on every platform). The registry keeps WEAK session
/// references and the strong router; a caller-provided plain session is
/// never silently wrapped or recreated.
private enum RouterTable {
    static let lock = NSLock()
    // Guarded exclusively by `lock` (lock-protected global shared state).
    nonisolated(unsafe) static var entries: [ObjectIdentifier: (session: URLSession?, router: TransportRouter)] = [:]

    static func register(_ session: URLSession, _ router: TransportRouter) {
        lock.withLock {
            entries = entries.filter { $0.value.session != nil }
            entries[ObjectIdentifier(session)] = (session, router)
        }
    }

    static func router(for session: URLSession) -> TransportRouter? {
        lock.withLock { entries[ObjectIdentifier(session)]?.router }
    }
}

// MARK: - public entry points

public enum StreamingTransport {
    /// Create a session that hosts the incremental transport. `configuration`
    /// is used AS GIVEN (caller owns timeouts/ephemerality/storage);
    /// `policyDelegate` is the caller's ORIGINAL delegate object, consulted
    /// for every redirection AND authentication/trust callback. The returned
    /// session is owned by the caller; reads never invalidate it, and the
    /// caller's own teardown (invalidateAndCancel etc.) still works — the
    /// router fences every pending sink on invalidation.
    public static func makeSession(configuration: URLSessionConfiguration,
                                   policyDelegate: (any URLSessionTaskDelegate)? = nil,
                                   refuseAllRedirects: Bool = false) -> URLSession {
        let router = TransportRouter(policyDelegate: policyDelegate,
                                     refuseAllRedirects: refuseAllRedirects)
        let session = URLSession(configuration: configuration, delegate: router, delegateQueue: nil)
        RouterTable.register(session, router)
        return session
    }

    /// True when `session` was created through `makeSession` and can host
    /// incremental reads WITHOUT recreating anything.
    public static func isStreamable(_ session: URLSession) -> Bool {
        RouterTable.router(for: session) != nil
    }

    /// Bounded non-stream collect with EARLY cancellation at the cap — from
    /// the declared `expectedContentLength` or from observed body bytes.
    /// Returns the body plus the FINAL URLResponse (redirects follow per the
    /// session's own policy). Throws `IncrementalTransportError`,
    /// `CancellationError` or the platform `URLError` for transport failures.
    public static func collect(_ request: URLRequest,
                               via session: URLSession,
                               maxBytes: Int) async throws -> (Data, URLResponse) {
        guard let router = RouterTable.router(for: session) else {
            throw IncrementalTransportError.sessionNotStreamable(
                reason: "session has no incremental transport delegate")
        }
        let sink = TransportSink(mode: .collect(maxBytes: maxBytes))
        let task = session.dataTask(with: request)
        router.attach(sink, to: task)
        task.resume()
        return try await sink.waitForCollect()
    }

    /// Start an incremental byte stream. Chunks publish through the bounded
    /// relay without blocking the delegate callback; saturation cancels the
    /// owned task and surfaces `pendingBufferSaturated` AFTER committed
    /// chunks drain. Abandoning iteration without consuming saturates within
    /// the byte ceiling and closes the request instead of buffering forever.
    public static func stream(_ request: URLRequest,
                              via session: URLSession,
                              maxBufferedBytes: Int) throws -> IncrementalByteStream {
        guard let router = RouterTable.router(for: session) else {
            throw IncrementalTransportError.sessionNotStreamable(
                reason: "session has no incremental transport delegate")
        }
        let sink = TransportSink(mode: .stream(maxBufferedBytes: maxBufferedBytes))
        let task = session.dataTask(with: request)
        let stream = IncrementalByteStream(sink: sink)
        router.attach(sink, to: task)
        task.resume()
        return stream
    }
}

/// The consumer-facing incremental byte stream. Exactly one producer Task
/// per request sits downstream of this (the SSE pipeline); the delegate
/// callback itself never blocks and never spawns work per chunk.
public struct IncrementalByteStream: AsyncSequence, Sendable {
    public typealias Element = Data
    let sink: TransportSink

    /// Await the head-line response (headers) before inspecting status;
    /// throws the terminal error when the task failed before headers.
    public func response() async throws -> URLResponse {
        try await sink.waitForResponse()
    }

    /// HTTP view of `response()` when the caller requires an HTTPURLResponse.
    public func httpResponse() async throws -> HTTPURLResponse {
        let response = try await sink.waitForResponse()
        guard let http = response as? HTTPURLResponse else {
            throw IncrementalTransportError.noHTTPResponse
        }
        return http
    }

    /// Idempotent owned-task cancellation with late-callback fencing.
    /// Committed chunks still drain; CancellationError then surfaces.
    public func cancelOwned() {
        sink.cancelOwned()
    }

    /// Observed terminal deliveries (must be exactly 1 per request; the
    /// qualification seam reports this so a race regression is visible).
    public var terminalDeliveries: Int { sink.terminalCount }

    public struct Iterator: AsyncIteratorProtocol {
        private let relay: BoundedAsyncRelay<Data>
        init(relay: BoundedAsyncRelay<Data>) { self.relay = relay }
        public mutating func next() async throws -> Data? {
            try await relay.next()
        }
    }

    public func makeAsyncIterator() -> Iterator { Iterator(relay: sink.relay) }
}
