import Foundation
import Network
import BridgeCore

/// Bounded, no-identifier reachability probe for the Apple TSS endpoint.
///
/// It sends one fixed `HEAD` request to `gs.apple.com:80`, reads at most 8 KiB
/// of response headers, keeps only the status code, and cancels its own
/// `NWConnection` on completion, timeout or cancellation. It never sends a
/// body, device identifier, nonce or ticket request and never follows a
/// redirect. A response proves network reachability only; it does not prove
/// the pinned install's TSS POST or raw-TCP client path.
enum BridgeTSSReachabilityProbe {
    static func run(gate: BridgeDDIMutationGate) async -> BridgeTSSReachabilityReport {
        let startedAt = Date()
        if gate.isCancelled {
            return Self.report(
                outcome: .cancelled,
                dns: .unknown,
                tcpConnected: nil,
                httpStatus: nil,
                startedAt: startedAt,
                connectAt: nil,
                headersAt: nil,
                errorCategory: "cancelled"
            )
        }
        let box = BridgeTSSProbeRun(startedAt: startedAt)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.attach(continuation)
                box.start(gate: gate)
            }
        } onCancel: {
            box.cancel()
        }
    }

    static func report(
        outcome: BridgeTSSReachabilityOutcome,
        dns: BridgeTSSDNSState,
        tcpConnected: Bool?,
        httpStatus: Int?,
        startedAt: Date,
        connectAt: Date?,
        headersAt: Date?,
        errorCategory: String?
    ) -> BridgeTSSReachabilityReport {
        let end = headersAt ?? Date()
        return BridgeTSSReachabilityReport(
            outcome: outcome,
            dns: dns,
            tcpConnected: tcpConnected,
            httpStatus: httpStatus,
            durationMilliseconds: milliseconds(from: startedAt, to: end),
            connectMilliseconds: connectAt.map { milliseconds(from: startedAt, to: $0) },
            headersMilliseconds: headersAt.map { milliseconds(from: startedAt, to: $0) },
            errorCategory: errorCategory
        )
    }

    static func milliseconds(from start: Date, to end: Date) -> Int {
        let seconds = end.timeIntervalSince(start)
        guard seconds.isFinite else { return 0 }
        return max(0, Int(min(seconds, 86_400) * 1000))
    }
}

/// Owns one probe connection and the exactly-once continuation. All network
/// callbacks run on `queue`; only `attach`, `finish` and `cancel` are lock
/// protected so Task cancellation can race a callback safely.
private final class BridgeTSSProbeRun: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "org.floeagent.iosbridge.tss-probe")
    private let startedAt: Date
    private var continuation: CheckedContinuation<BridgeTSSReachabilityReport, Never>?
    private var pending: BridgeTSSReachabilityReport?
    private var finished = false
    private var connection: NWConnection?
    private var connectedAt: Date?
    private var waitingCategory: String?

    // Queue-confined state.
    private var buffer = Data()
    private var sentRequest = false

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    func attach(_ continuation: CheckedContinuation<BridgeTSSReachabilityReport, Never>) {
        var resumeNow: BridgeTSSReachabilityReport?
        lock.lock()
        if let pending {
            resumeNow = pending
            self.pending = nil
        } else {
            self.continuation = continuation
        }
        lock.unlock()
        if let resumeNow { continuation.resume(returning: resumeNow) }
    }

    func start(gate: BridgeDDIMutationGate) {
        if gate.isCancelled {
            finish(.cancelled, category: "cancelled")
            return
        }
        guard let port = NWEndpoint.Port(rawValue: BridgeTSSProbePolicy.port) else {
            finish(.failed, category: "invalid-target")
            return
        }
        let connection = NWConnection(
            host: NWEndpoint.Host(BridgeTSSProbePolicy.host),
            port: port,
            using: .tcp
        )
        lock.lock()
        if finished {
            lock.unlock()
            connection.cancel()
            return
        }
        self.connection = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else {
                connection.cancel()
                return
            }
            switch state {
            case .ready:
                self.markConnected()
                self.sendRequest(on: connection)
            case .waiting(let error):
                // A wait may still recover before the deadline. Remember the
                // category for the timeout report without failing early.
                self.setWaitingCategory(Self.category(error))
            case .failed(let error):
                self.finishAfterFailure(error)
                connection.cancel()
            case .cancelled:
                self.finish(.cancelled, category: "cancelled")
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + BridgeTSSProbePolicy.totalDeadlineSeconds) {
            [weak self] in
            guard let self else { return }
            let category = self.waitingCategoryValue() ?? "deadline"
            self.finish(
                .timedOut,
                category: category,
                dns: category == "dns" ? .failed : nil
            )
            self.currentConnection()?.cancel()
        }
    }

    /// Safe from any thread. Cancels only this probe's own connection; the
    /// checked continuation is resumed at most once.
    func cancel() {
        finish(.cancelled, category: "cancelled")
        currentConnection()?.cancel()
    }

    private func sendRequest(on connection: NWConnection) {
        guard !sentRequest else { return }
        sentRequest = true
        let request = "\(BridgeTSSProbePolicy.requestLine)\r\n" +
            "Host: \(BridgeTSSProbePolicy.host)\r\n" +
            "Connection: close\r\n\r\n"
        connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else {
                connection.cancel()
                return
            }
            if let error {
                self.finishAfterFailure(error)
                connection.cancel()
                return
            }
            self.receiveHeaders(on: connection)
        })
    }

    private func receiveHeaders(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2_048) {
            [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let error {
                self.finishAfterFailure(error)
                connection.cancel()
                return
            }
            if let data { self.buffer.append(data) }
            if let head = BridgeTSSResponseHeadParser.parse(self.buffer) {
                self.finish(
                    .httpResponse,
                    category: nil,
                    httpStatus: head.httpStatus,
                    headersAt: Date()
                )
                connection.cancel()
                return
            }
            if self.buffer.count > BridgeTSSProbePolicy.maximumHeaderBytes {
                self.finish(.failed, category: "headers-over-bound")
                connection.cancel()
                return
            }
            if complete {
                self.finish(.failed, category: "closed-before-headers")
                connection.cancel()
                return
            }
            self.receiveHeaders(on: connection)
        }
    }

    private func markConnected() {
        lock.lock()
        if connectedAt == nil { connectedAt = Date() }
        lock.unlock()
    }

    private func setWaitingCategory(_ value: String) {
        lock.lock()
        waitingCategory = value
        lock.unlock()
    }

    private func waitingCategoryValue() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return waitingCategory
    }

    private func finishAfterFailure(_ error: NWError) {
        let category = Self.category(error)
        let dns: BridgeTSSDNSState
        switch error {
        case .dns:
            dns = .failed
        default:
            dns = nil == connectedTime() ? .unknown : .resolved
        }
        finish(
            .failed,
            category: category,
            dns: dns,
            tcpConnected: connectedTime() != nil
        )
    }

    private func connectedTime() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return connectedAt
    }

    private func finish(
        _ outcome: BridgeTSSReachabilityOutcome,
        category: String?,
        dns: BridgeTSSDNSState? = nil,
        tcpConnected: Bool? = nil,
        httpStatus: Int? = nil,
        headersAt: Date? = nil
    ) {
        var resume: CheckedContinuation<BridgeTSSReachabilityReport, Never>?
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let connected = connectedAt
        let report = BridgeTSSReachabilityProbe.report(
            outcome: outcome,
            dns: dns ?? (connected == nil ? .unknown : .resolved),
            tcpConnected: tcpConnected ?? (connected != nil),
            httpStatus: httpStatus,
            startedAt: startedAt,
            connectAt: connected,
            headersAt: headersAt,
            errorCategory: category
        )
        if let continuation {
            resume = continuation
            self.continuation = nil
        } else {
            pending = report
        }
        lock.unlock()
        resume?.resume(returning: report)
    }

    private func currentConnection() -> NWConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connection
    }

    private static func category(_ error: NWError) -> String {
        switch error {
        case .dns:
            return "dns"
        case .posix(let code):
            return BridgeTSSProbeErrorCategory.posix(code)
        case .tls:
            return "tls"
        case .wifiAware(_):
            return "wifi-aware"
        @unknown default:
            return "other"
        }
    }
}
