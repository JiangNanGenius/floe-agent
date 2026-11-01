import Foundation
import Network

/// Bounded async LAN control server.
///
/// This is an independent listener on its own port. It never shares the
/// read-only diagnostics bearer token or its listener contract. Every control
/// or result request must arrive as a v1 encrypted envelope under a separate
/// control key. Requests are submitted to the existing authenticated file lane
/// and results are retrieved asynchronously; the HTTP connection itself has a
/// short fixed timeout, so a client disconnect cannot replay or falsely finish
/// an SDK call that already started.
public final class BridgeLANControlServer: @unchecked Sendable {
    public static let defaultPort: UInt16 = 47_655

    public struct Runtime: Sendable {
        public var port: UInt16
        public var key: Data
        public var limits: BridgeLANLimits
        public var state: @Sendable () -> BridgeLANCurrentState
        public var submit: @Sendable (BridgeLANControlRequest) -> BridgeLANSubmitOutcome
        public var result: @Sendable (BridgeLANResultRequest) -> BridgeLANCommandResultOutcome
        /// Called after an authenticated shutdown command has been accepted and
        /// new admission has been closed. It must synchronously fence queued
        /// work and schedule cleanup; it must not cancel the current socket
        /// before the sealed acknowledgement can be written.
        public var shutdown: @Sendable (String) -> Void
        public var log: @Sendable (String) -> Void
        /// Narrow deterministic host-test seam. It is called on the server
        /// queue after a sealed response body has been fully built and before
        /// the final lifecycle commit. Production leaves it nil; it is not
        /// remotely settable and cannot change any request/response decision.
        public var beforeResponseCommit: (@Sendable () -> Void)?

        public init(
            port: UInt16 = BridgeLANControlServer.defaultPort,
            key: Data,
            limits: BridgeLANLimits = .default,
            state: @escaping @Sendable () -> BridgeLANCurrentState,
            submit: @escaping @Sendable (BridgeLANControlRequest) -> BridgeLANSubmitOutcome,
            result: @escaping @Sendable (BridgeLANResultRequest) -> BridgeLANCommandResultOutcome,
            shutdown: @escaping @Sendable (String) -> Void = { _ in },
            log: @escaping @Sendable (String) -> Void = { _ in },
            beforeResponseCommit: (@Sendable () -> Void)? = nil
        ) {
            self.port = port
            self.key = key
            self.limits = limits
            self.state = state
            self.submit = submit
            self.result = result
            self.shutdown = shutdown
            self.log = log
            self.beforeResponseCommit = beforeResponseCommit
        }
    }

    public enum ServerError: LocalizedError, Equatable {
        case invalidPort
        case invalidKey
        case alreadyRunning
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidPort:
                return "The control port is invalid."
            case .invalidKey:
                return "The control key is invalid."
            case .alreadyRunning:
                return "LAN control is already running."
            case .failed(let message):
                return "LAN control failed: \(message)"
            }
        }
    }

    private let queue = DispatchQueue(label: "org.floeagent.iosbridge.lan-control")
    private let lock = NSLock()
    private var listener: NWListener?
    private var runtime: Runtime?
    private var auth: BridgeLANAuthState?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var contexts: [ObjectIdentifier: ConnectionContext] = [:]
    private var listening = false
    private var stateHandler: (@Sendable (Bool, String?) -> Void)?
    private var port: UInt16 = BridgeLANControlServer.defaultPort
    private var listenerEpoch: UInt64 = 0
    private var requestEpoch: UInt64 = 0
    /// Set synchronously when an authenticated shutdown is accepted. New
    /// commands are refused while the acknowledgement is still being written;
    /// only final socket cancellation/key deletion is delayed.
    private var admissionClosed = false

    private struct ConnectionContext: Sendable {
        let listenerEpoch: UInt64
        let requestEpoch: UInt64
        let authEpoch: UInt64?
    }

    /// LAN-only listener parameters. Cellular is explicitly prohibited; the
    /// listener remains family- and interface-agnostic for Wi-Fi, Ethernet and
    /// the loopback used by host qualification.
    public static func makeListenerParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }

    public init() {}

    public var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener != nil
    }

    public var isListening: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listening
    }

    public var listeningPort: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return listener == nil ? nil : port
    }

    public func setStateChangeHandler(_ handler: (@Sendable (Bool, String?) -> Void)?) {
        lock.lock()
        stateHandler = handler
        lock.unlock()
    }

    public func start(_ runtime: Runtime) throws {
        guard runtime.port > 0, let endpointPort = NWEndpoint.Port(rawValue: runtime.port) else {
            throw ServerError.invalidPort
        }
        guard runtime.key.count == BridgeLANCrypto.keyByteCount else {
            throw ServerError.invalidKey
        }
        lock.lock()
        let already = listener != nil
        lock.unlock()
        guard !already else { throw ServerError.alreadyRunning }

        let parameters = Self.makeListenerParameters()
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: endpointPort)
        } catch {
            throw ServerError.failed(error.localizedDescription)
        }

        let auth = BridgeLANAuthState(key: runtime.key, limits: runtime.limits)
        guard !auth.currentSession.isEmpty else {
            throw ServerError.failed("A fresh control session identifier could not be generated.")
        }
        lock.lock()
        // A new listener/auth instance is a new security epoch. Any callback
        // or envelope captured from an older instance is invalid even when the
        // retained key, PID and generation happen to be identical.
        listenerEpoch &+= 1
        requestEpoch &+= 1
        self.runtime = runtime
        self.auth = auth
        self.port = runtime.port
        self.listener = listener
        self.admissionClosed = false
        lock.unlock()

        let myEpoch = listenerEpoch
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                guard self.listenerEpoch == myEpoch else {
                    self.lock.unlock()
                    return
                }
                self.listening = true
                let handler = self.stateHandler
                self.lock.unlock()
                runtime.log("lan_control_listening port=\(runtime.port)")
                handler?(true, nil)
            case .failed(let error):
                self.lock.lock()
                guard self.listenerEpoch == myEpoch else {
                    self.lock.unlock()
                    return
                }
                self.listening = false
                self.listener = nil
                self.runtime = nil
                self.admissionClosed = true
                let oldAuth = self.auth
                self.auth = nil
                self.listenerEpoch &+= 1
                self.requestEpoch &+= 1
                let current = Array(self.connections.values)
                self.connections.removeAll()
                self.contexts.removeAll()
                let handler = self.stateHandler
                self.lock.unlock()
                oldAuth?.clear()
                for connection in current { connection.cancel() }
                runtime.log("lan_control_failed error=\(error.localizedDescription)")
                handler?(false, error.localizedDescription)
                listener.cancel()
            case .cancelled:
                self.lock.lock()
                guard self.listenerEpoch == myEpoch else {
                    self.lock.unlock()
                    return
                }
                self.listening = false
                self.listener = nil
                self.runtime = nil
                self.admissionClosed = true
                let oldAuth = self.auth
                self.auth = nil
                self.listenerEpoch &+= 1
                self.requestEpoch &+= 1
                let current = Array(self.connections.values)
                self.connections.removeAll()
                self.contexts.removeAll()
                let handler = self.stateHandler
                self.lock.unlock()
                oldAuth?.clear()
                for connection in current { connection.cancel() }
                handler?(false, nil)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, listenerEpoch: myEpoch)
        }
        listener.start(queue: queue)
        runtime.log("lan_control_start_requested port=\(runtime.port)")
    }

    public func stop() {
        lock.lock()
        let listener = self.listener
        let current = Array(connections.values)
        let oldAuth = self.auth
        self.listener = nil
        self.runtime = nil
        self.auth = nil
        self.listening = false
        self.admissionClosed = true
        self.connections.removeAll()
        self.contexts.removeAll()
        // Invalidate every listener/request/auth callback before cancellation.
        listenerEpoch &+= 1
        requestEpoch &+= 1
        let handler = self.stateHandler
        lock.unlock()
        oldAuth?.clear()
        listener?.cancel()
        for connection in current { connection.cancel() }
        handler?(false, nil)
    }

    /// Fences in-flight HTTP work and every request authenticated before this
    /// instant without deleting the retained control key. The listener stays
    /// open for a new request after the fence. The new request epoch is the
    /// linearization point: a submit already inside `runtime.submit` completes
    /// before this method can take the lock, so the caller can remove its
    /// queued file afterwards. A response body sealed before the fence but not
    /// yet enqueued is dropped at its final commit; a commit already inside the
    /// lock finishes (enqueues) before the fence can invalidate the epoch.
    public func fence() {
        lock.lock()
        requestEpoch &+= 1
        self.auth?.arm()
        let current = Array(connections.values)
        self.connections.removeAll()
        self.contexts.removeAll()
        lock.unlock()
        for connection in current { connection.cancel() }
    }

    /// Replaces the accepted key in place. The auth epoch advances, so a
    /// request whose MAC was checked under the old key cannot commit a nonce
    /// or receive a sealed result afterwards. A response already sealed under
    /// the old key is dropped by the final commit revalidation rather than
    /// enqueued. The caller fences queued broker work immediately after this
    /// returns.
    public func replaceKey(_ key: Data) throws {
        guard key.count == BridgeLANCrypto.keyByteCount else { throw ServerError.invalidKey }
        lock.lock()
        guard let auth = self.auth else {
            lock.unlock()
            throw ServerError.failed("LAN control is not running.")
        }
        auth.replaceKey(key)
        lock.unlock()
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection, listenerEpoch expectedEpoch: UInt64) {
        lock.lock()
        let limits = runtime?.limits ?? .default
        guard listenerEpoch == expectedEpoch,
              listener != nil,
              connections.count < limits.maxConnections,
              let authEpoch = auth?.currentEpoch else {
            lock.unlock()
            connection.cancel()
            return
        }
        let context = ConnectionContext(listenerEpoch: listenerEpoch,
                                        requestEpoch: requestEpoch,
                                        authEpoch: authEpoch)
        connections[ObjectIdentifier(connection)] = connection
        contexts[ObjectIdentifier(connection)] = context
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                // Deferred so a synchronously delivered cancellation can never
                // take the server lock inline with the final response commit.
                self?.removeAsync(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + limits.requestTimeout) { [weak self] in
            guard let self else { connection.cancel(); return }
            self.lock.lock()
            let active = self.connections[ObjectIdentifier(connection)] != nil
            self.lock.unlock()
            if active { connection.cancel() }
        }
        receive(connection, context: context, buffer: Data())
    }

    private func remove(_ connection: NWConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        contexts.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    /// Queue an idempotent dictionary cleanup instead of running it inline from
    /// a send completion or connection state callback. Those callbacks can be
    /// delivered while the final response commit holds `lock`; `queue.async`
    /// defers the lock acquisition until after that critical section, avoiding
    /// recursive-lock reentrancy/deadlock without holding an external callback
    /// inside the commit.
    private func removeAsync(_ connection: NWConnection) {
        queue.async { [weak self] in
            self?.remove(connection)
        }
    }

    private func receive(_ connection: NWConnection,
                         context: ConnectionContext,
                         buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            self.lock.lock()
            let limits = self.runtime?.limits ?? .default
            self.lock.unlock()

            var accumulated = buffer
            if let data, !data.isEmpty { accumulated.append(data) }
            let maxBuffer = limits.maxRequestHeadBytes + limits.maxRequestBodyBytes + 1
            if accumulated.count > maxBuffer {
                self.sendPlain(connection, status: 413, code: "request_too_large")
                return
            }
            switch BridgeHTTPParser.inspect(accumulated, limits: limits) {
            case .incomplete:
                if complete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(connection, context: context, buffer: accumulated)
                }
            case .invalid(let status, let code):
                self.sendPlain(connection, status: status, code: code)
            case .ready(let head, let body):
                self.route(head, body: body, context: context, connection: connection)
            }
        }
    }

    private func route(_ head: BridgeHTTPRequestHead,
                       body: Data,
                       context: ConnectionContext,
                       connection: NWConnection) {
        guard head.method == "POST" else {
            sendPlain(connection, status: 405, code: "method_not_allowed",
                      extraHeaders: ["Allow": "POST"])
            return
        }
        switch head.path {
        case "/v1/control":
            handleSealed(body: body, kind: .control, context: context, connection: connection)
        case "/v1/result":
            handleSealed(body: body, kind: .result, context: context, connection: connection)
        case "/v1/session":
            handleSealed(body: body, kind: .session, context: context, connection: connection)
        default:
            sendPlain(connection, status: 404, code: "not_found")
        }
    }

    private enum SealedKind {
        case control
        case result
        case session
    }

    private func isCurrentContextLocked(_ context: ConnectionContext) -> Bool {
        listener != nil &&
            listenerEpoch == context.listenerEpoch &&
            requestEpoch == context.requestEpoch
    }

    private func handleSealed(body: Data,
                              kind: SealedKind,
                              context: ConnectionContext,
                              connection: NWConnection) {
        lock.lock()
        if admissionClosed {
            lock.unlock()
            sendPlain(connection, status: 401, code: "admission_closed",
                      message: "LAN control admission is closed.")
            return
        }
        guard isCurrentContextLocked(context),
              let runtime = self.runtime,
              let auth = self.auth,
              auth.currentEpoch == context.authEpoch else {
            lock.unlock()
            // This connection belongs to an older listener/request/auth
            // instance. Drop it before it can read a key, submit or seal a
            // result. The plain error contains no key material or result.
            sendPlain(connection, status: 401, code: "auth_stale",
                      message: "The control request belongs to an older arm.")
            return
        }
        let limits = runtime.limits
        lock.unlock()

        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            sendPlain(connection, status: 400, code: "bad_envelope")
            return
        }
        guard BridgeLANCrypto.looksLikeEnvelope(object) else {
            sendPlain(connection, status: 401, code: "auth_required")
            return
        }

        let opened: BridgeLANAuthState.Opened
        do {
            opened = try auth.open(body: body)
        } catch let failure as BridgeLANCrypto.Failure {
            let status = failure.code == "bad_envelope" ? 400 : 401
            sendPlain(connection, status: status, code: failure.code, message: failure.message)
            return
        } catch {
            sendPlain(connection, status: 401, code: "auth_failed")
            return
        }
        let state = runtime.state()
        let current: [String: Any] = [
            "currentPid": Int(state.pid),
            "currentGeneration": state.generation,
        ]

        switch kind {
        case .control:
            handleControl(body: opened.plaintext, opened: opened, state: state,
                          current: current, limits: limits, auth: auth,
                          context: context, connection: connection)
        case .result:
            handleResult(body: opened.plaintext, opened: opened, state: state,
                         current: current, limits: limits, auth: auth,
                         context: context, connection: connection)
        case .session:
            handleSession(body: opened.plaintext, opened: opened, state: state,
                          current: current, limits: limits, auth: auth,
                          context: context, connection: connection)
        }
    }

    private func handleSession(body: Data,
                               opened: BridgeLANAuthState.Opened,
                               state: BridgeLANCurrentState,
                               current: [String: Any],
                               limits: BridgeLANLimits,
                               auth: BridgeLANAuthState,
                               context: ConnectionContext,
                               connection: NWConnection) {
        do {
            _ = try BridgeLANRequestDecoder.discovery(body, limits: limits)
        } catch let error as BridgeLANRequestError {
            sendSealed(opened, current: current, errorCode: error.code,
                       message: error.message, context: context, connection: connection)
            return
        } catch {
            sendSealed(opened, current: current, errorCode: "bad_request",
                       message: "The session request is malformed.",
                       context: context, connection: connection)
            return
        }

        lock.lock()
        guard isCurrentContextLocked(context),
              self.auth === auth,
              auth.currentEpoch == opened.revision.epoch,
              opened.isCurrent() else {
            lock.unlock()
            connection.cancel()
            return
        }
        let session = auth.currentSession
        lock.unlock()
        guard !session.isEmpty else {
            sendSealed(opened, current: current, errorCode: "session_unavailable",
                       message: "No current control session is available.",
                       context: context, connection: connection)
            return
        }
        var response = current
        response["ok"] = true
        response["state"] = "session"
        response["protocol"] = 1
        response["sessionId"] = session
        sendSealedJSON(opened, object: response, context: context, connection: connection)
    }

    private func handleControl(body: Data,
                               opened: BridgeLANAuthState.Opened,
                               state: BridgeLANCurrentState,
                               current: [String: Any],
                               limits: BridgeLANLimits,
                               auth: BridgeLANAuthState,
                               context: ConnectionContext,
                               connection: NWConnection) {
        let request: BridgeLANControlRequest
        do {
            request = try BridgeLANRequestDecoder.control(body, limits: limits)
        } catch let error as BridgeLANRequestError {
            sendSealed(opened, current: current, errorCode: error.code,
                       message: error.message, context: context, connection: connection)
            return
        } catch {
            sendSealed(opened, current: current, errorCode: "bad_request",
                       message: "The control request is malformed.", context: context, connection: connection)
            return
        }
        if let error = BridgeLANControlPolicy.validate(request) {
            sendSealed(opened, current: current, errorCode: error.code,
                       message: error.message, context: context, connection: connection)
            return
        }
        guard auth.isCurrentSession(request.session) else {
            sendSealed(opened, current: current, errorCode: "session_mismatch",
                       message: "The control session is no longer current.",
                       context: context, connection: connection)
            return
        }
        guard request.pid == state.pid else {
            sendSealed(opened, current: current, errorCode: "stale_pid",
                       message: "The request PID is not the current host process.",
                       context: context, connection: connection)
            return
        }
        guard request.generation == state.generation else {
            sendSealed(opened, current: current, errorCode: "stale_generation",
                       message: "The request generation is no longer current.",
                       context: context, connection: connection)
            return
        }

        // Linearization boundary: hold the server lock across the freshness
        // recheck and the submit. A rotation/stop/fence therefore either
        // completes entirely before this command is issued (and the caller's
        // broker fence can remove it) or waits until after the submit.
        lock.lock()
        guard !admissionClosed,
              isCurrentContextLocked(context),
              let authNow = self.auth,
              authNow.currentEpoch == opened.revision.epoch,
              authNow.isCurrentSession(request.session),
              opened.isCurrent(),
              let currentRuntime = self.runtime else {
            lock.unlock()
            connection.cancel()
            return
        }
        let outcome = currentRuntime.submit(request)
        var shutdownAccepted = false
        if request.action == "shutdown",
           case .accepted(_, _, _, _, let duplicate) = outcome,
           !duplicate {
            // Close new command admission synchronously, while the server lock
            // still serializes submits. The shutdown callback fences queued
            // work immediately; only socket cancellation/key deletion waits
            // for the sealed acknowledgement to flush.
            admissionClosed = true
            shutdownAccepted = true
        }
        lock.unlock()

        if shutdownAccepted {
            currentRuntime.shutdown(request.id)
        }

        switch outcome {
        case .accepted(let id, let lane, let action, let generation, let duplicate):
            var response = current
            response["ok"] = true
            response["state"] = "accepted"
            response["id"] = id
            response["lane"] = lane.rawValue
            response["action"] = action
            response["generation"] = generation
            response["duplicate"] = duplicate
            if BridgeControlAction.all.contains(request.action) {
                // Non-secret binding of the normalized arguments. Text is
                // represented only by its byte count; the text itself is never
                // echoed.
                response["parametersDigest"] = BridgeControlArguments.resultDigest(
                    action: request.action,
                    parameters: request.parameters
                )
                if let summary = request.parameters?.summaryJSON() {
                    response["parameters"] = summary
                }
            }
            if request.action == "shutdown" {
                response["final"] = true
                response["closes"] = ["control", "readonly"]
                response["revokesControlKey"] = true
            }
            // Only the accepted shutdown acknowledgement may commit after
            // admission was closed; every other response is dropped at the
            // final boundary instead of becoming a late post-shutdown reply.
            sendSealedJSON(opened, object: response, context: context, connection: connection,
                           allowsClosedAdmission: request.action == "shutdown")
        case .rejected(let code, let message):
            sendSealed(opened, current: current, errorCode: code,
                       message: message, context: context, connection: connection)
        }
    }

    private func handleResult(body: Data,
                              opened: BridgeLANAuthState.Opened,
                              state: BridgeLANCurrentState,
                              current: [String: Any],
                              limits: BridgeLANLimits,
                              auth: BridgeLANAuthState,
                              context: ConnectionContext,
                              connection: NWConnection) {
        let request: BridgeLANResultRequest
        do {
            request = try BridgeLANRequestDecoder.result(body, limits: limits)
        } catch let error as BridgeLANRequestError {
            sendSealed(opened, current: current, errorCode: error.code,
                       message: error.message, context: context, connection: connection)
            return
        } catch {
            sendSealed(opened, current: current, errorCode: "bad_request",
                       message: "The result request is malformed.", context: context, connection: connection)
            return
        }
        if let error = BridgeLANControlPolicy.validate(request) {
            sendSealed(opened, current: current, errorCode: error.code,
                       message: error.message, context: context, connection: connection)
            return
        }
        guard auth.isCurrentSession(request.session) else {
            sendSealed(opened, current: current, errorCode: "session_mismatch",
                       message: "The result session is no longer current.",
                       context: context, connection: connection)
            return
        }
        guard request.pid == state.pid else {
            sendSealed(opened, current: current, errorCode: "stale_pid",
                       message: "The request PID is not the current host process.",
                       context: context, connection: connection)
            return
        }

        var response = current
        lock.lock()
        guard !admissionClosed,
              isCurrentContextLocked(context),
              let authNow = self.auth,
              authNow.currentEpoch == opened.revision.epoch,
              authNow.isCurrentSession(request.session),
              opened.isCurrent(),
              let currentRuntime = self.runtime else {
            lock.unlock()
            connection.cancel()
            return
        }
        let outcome = currentRuntime.result(request)
        lock.unlock()

        switch outcome {
        case .unknown:
            response["ok"] = true
            response["state"] = "unknown"
        case .pending:
            response["ok"] = true
            response["state"] = "pending"
        case .expired:
            response["ok"] = true
            response["state"] = "expired"
        case .fenced:
            response["ok"] = true
            response["state"] = "fenced"
        case .ready(let payload):
            response["ok"] = true
            response["state"] = "ready"
            response["result"] = resultDictionary(payload)
        case .late(let late):
            response["ok"] = true
            response["state"] = "late"
            var lateResult: [String: Any] = [
                "status": late.status,
                "action": late.action,
                "processIdentifier": Int(late.processIdentifier),
                "generation": late.generation,
                "processedAt": late.processedAt,
            ]
            if let resulting = late.resultingGeneration {
                lateResult["resultingGeneration"] = resulting
            }
            if let error = late.error { lateResult["error"] = error }
            response["result"] = lateResult
        case .rejected(let code, let message):
            response["ok"] = false
            response["state"] = "rejected"
            response["error"] = ["code": code, "message": message]
        }
        sendSealedJSON(opened, object: response, context: context, connection: connection)
    }

    private func resultDictionary(_ payload: BridgeLANCommandResultPayload) -> [String: Any] {
        var result: [String: Any] = [
            "status": payload.status,
            "action": payload.action,
            "processIdentifier": Int(payload.processIdentifier),
            "generation": payload.generation,
            "processedAt": payload.processedAt,
            "details": payload.details,
        ]
        if let resulting = payload.resultingGeneration {
            result["resultingGeneration"] = resulting
        }
        if let error = payload.error { result["error"] = error }
        if let argument = payload.artifact {
            result["artifact"] = [
                "name": argument.name,
                "mediaType": argument.mediaType,
                "byteCount": argument.byteCount,
                "sha256": argument.sha256,
                "base64": argument.base64,
            ]
        }
        if let artifactError = payload.artifactError {
            result["artifactError"] = artifactError
        }
        return result
    }

    private func sendSealed(_ opened: BridgeLANAuthState.Opened,
                            current: [String: Any],
                            errorCode: String,
                            message: String,
                            context: ConnectionContext,
                            connection: NWConnection) {
        var response = current
        response["ok"] = false
        response["error"] = ["code": errorCode, "message": message]
        sendSealedJSON(opened, object: response, context: context, connection: connection)
    }

    /// Seals a response outside the lifecycle lock, then commits the final
    /// socket enqueue atomically with Stop, `fence` and `replaceKey`.
    ///
    /// Linearization boundary: JSON encoding and encryption deliberately stay
    /// outside the server lock. The final guard below runs under the same lock
    /// those lifecycle operations take before invalidating the listener/
    /// request/auth epochs, and `connection.send` is enqueued before that lock
    /// is released. So either the response commits while this exact listener/
    /// request/auth/session revision is still current, or a lifecycle change
    /// has already won and no sealed bytes are enqueued. A body sealed just
    /// before a key rotation is dropped rather than delivered with the revoked
    /// key/context; known stale data is never returned as current.
    ///
    /// `allowsClosedAdmission` is true only for the accepted shutdown
    /// acknowledgement, whose sealed reply must flush after admission closes.
    private func sendSealedJSON(_ opened: BridgeLANAuthState.Opened,
                                object: [String: Any],
                                context: ConnectionContext,
                                connection: NWConnection,
                                allowsClosedAdmission: Bool = false) {
        lock.lock()
        guard isCurrentContextLocked(context),
              let runtime = self.runtime,
              let authNow = self.auth,
              authNow.currentEpoch == opened.revision.epoch,
              opened.isCurrent() else {
            lock.unlock()
            connection.cancel()
            return
        }
        let maxResponse = runtime.limits.maxResponseBytes
        lock.unlock()

        // Build and seal the body without holding the lifecycle lock. The seal
        // closure repeats the auth-epoch/session check inside the authentication
        // lock, so a rotation/fence that wins this window refuses to produce an
        // old-key body at all.
        guard opened.isCurrent(),
              let plaintext = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              var sealed = opened.seal(plaintext) else {
            connection.cancel()
            return
        }
        if sealed.count > maxResponse {
            let fallback: [String: Any] = [
                "ok": false,
                "error": ["code": "response_too_large",
                          "message": "The sealed response exceeded the bounded size."],
            ]
            guard let fallbackData = try? JSONSerialization.data(
                withJSONObject: fallback,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ), let fallbackSealed = opened.seal(fallbackData) else {
                connection.cancel()
                return
            }
            sealed = fallbackSealed
        }

        // Deterministic test pause after sealing and before the commit. Nil in
        // production.
        runtime.beforeResponseCommit?()

        // Final commit. The freshness check and the enqueue are one lifecycle-
        // atomic operation: every invalidation path (stop/fence/replaceKey/
        // listener transition) takes `lock` before changing its epoch, so it
        // either completes before this guard or waits until the header is
        // already enqueued. Nothing that could make this an old-key/context
        // response can interleave between the check and `connection.send`.
        var dropReason: String?
        lock.lock()
        if admissionClosed && !allowsClosedAdmission {
            dropReason = "admission_closed"
        } else if !isCurrentContextLocked(context) {
            dropReason = "stale_context"
        } else if let authCommit = self.auth,
                  ObjectIdentifier(authCommit) == opened.authIdentity,
                  opened.isCurrent() {
            sendData(connection, status: 200, body: sealed)
        } else {
            dropReason = "stale_auth"
        }
        lock.unlock()

        if let dropReason {
            runtime.log("lan_control_response_commit_dropped reason=\(dropReason)")
            connection.cancel()
        }
    }

    private func sendPlain(_ connection: NWConnection,
                           status: Int,
                           code: String,
                           message: String? = nil,
                           extraHeaders: [String: String] = [:]) {
        var error: [String: Any] = ["code": code]
        if let message { error["message"] = message }
        let object: [String: Any] = ["ok": false, "error": error]
        let body = (try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
        sendData(connection, status: status, body: body, extraHeaders: extraHeaders)
    }

    private func sendData(_ connection: NWConnection,
                          status: Int,
                          body: Data,
                          extraHeaders: [String: String] = [:]) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        case 431: reason = "Request Header Fields Too Large"
        case 500: reason = "Internal Server Error"
        case 503: reason = "Service Unavailable"
        default: reason = "Error"
        }
        var headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "X-Content-Type-Options: nosniff",
            "Connection: close",
        ]
        for (name, value) in extraHeaders { headers.append("\(name): \(value)") }
        var response = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            // Never take `lock` inline here: this completion may run while the
            // final sealed-response commit still holds it.
            self?.removeAsync(connection)
        })
    }
}

/// Single-key envelope authentication for the provisioned control credential.
///
/// The key is retained across a device-side disable/rearm unless it is revoked.
/// Each auth instance (and each explicit fence) therefore carries an epoch and
/// an armed-at watermark. A request authenticated under an older epoch, or one
/// whose timestamp predates the current arm, is refused even if its key and the
/// PID/generation are unchanged. The nonce cache remains authoritative for
/// exact replays; the epoch/watermark closes the rearm gap for a packet that
/// was captured before it was ever dispatched.
public final class BridgeLANAuthState: @unchecked Sendable {
    public struct Revision: Equatable, Sendable {
        public let epoch: UInt64
        public let keyID: String
        public let sessionID: String
        public let eventCount: Int
        public let headNonce: String

        public init(epoch: UInt64, keyID: String, sessionID: String,
                    eventCount: Int, headNonce: String) {
            self.epoch = epoch
            self.keyID = keyID
            self.sessionID = sessionID
            self.eventCount = eventCount
            self.headNonce = headNonce
        }
    }

    public struct Opened: Sendable {
        public let tokenID: String
        public let plaintext: Data
        public let revision: Revision
        private let auth: BridgeLANAuthState
        public let seal: @Sendable (Data) -> Data?

        init(tokenID: String,
             plaintext: Data,
             revision: Revision,
             auth: BridgeLANAuthState,
             seal: @escaping @Sendable (Data) -> Data?) {
            self.tokenID = tokenID
            self.plaintext = plaintext
            self.revision = revision
            self.auth = auth
            self.seal = seal
        }

        /// True only while the same auth instance and key revision that
        /// authenticated this request are still current. A key rotation, a
        /// fence or a stop increments the epoch and makes this false.
        public func isCurrent() -> Bool {
            auth.isCurrent(revision)
        }

        /// The exact auth instance that opened this request. The server's final
        /// commit compares it with the live instance so a response opened under
        /// a replaced instance can never be enqueued. `Opened` retains that
        /// instance, so its address cannot be reused while this value exists.
        var authIdentity: ObjectIdentifier {
            ObjectIdentifier(auth)
        }
    }

    private let lock = NSLock()
    private var key: Data
    private var keyID: String
    private var epoch: UInt64 = 1
    private var seenNonces: [String: Int]
    private var eventCount = 0
    private var headNonce = ""
    private var sessionID: String
    private let limits: BridgeLANLimits

    public init(key: Data,
                limits: BridgeLANLimits = .default) {
        self.key = key
        self.keyID = BridgeLANCrypto.tokenId(for: key)
        self.seenNonces = [:]
        self.limits = limits
        self.sessionID = Self.generateSessionID()
    }

    public var fingerprint: String {
        lock.lock()
        defer { lock.unlock() }
        return keyID
    }

    public var currentEpoch: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return epoch
    }

    /// Fresh unpredictable identifier for this arm. It is returned only in an
    /// authenticated/encrypted discovery response and must be carried inside
    /// every control/result payload. It is not the encryption key.
    public var currentSession: String {
        lock.lock()
        defer { lock.unlock() }
        return sessionID
    }

    public func isCurrentSession(_ value: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !sessionID.isEmpty &&
            BridgeInstallToken.constantTimeEquals(value, sessionID)
    }

    private static func generateSessionID() -> String {
        guard let bytes = BridgeLANCrypto.randomBytes(16) else { return "" }
        return BridgeLANCrypto.hexLowercase(bytes)
    }

    public var revision: Revision {
        lock.lock()
        defer { lock.unlock() }
        return Revision(epoch: epoch, keyID: keyID, sessionID: sessionID,
                        eventCount: eventCount, headNonce: headNonce)
    }

    public func replaceKey(_ newKey: Data) {
        lock.lock()
        key = newKey
        keyID = BridgeLANCrypto.tokenId(for: newKey)
        epoch &+= 1
        sessionID = Self.generateSessionID()
        seenNonces.removeAll()
        eventCount = 0
        headNonce = ""
        lock.unlock()
    }

    /// Fence all requests authenticated before this instant without changing
    /// the retained key. The session identifier and auth epoch both rotate, so
    /// a captured packet from the previous arm cannot submit or fetch, even on
    /// the same clock second or with a future timestamp inside the window.
    public func arm() {
        lock.lock()
        epoch &+= 1
        sessionID = Self.generateSessionID()
        eventCount = 0
        headNonce = ""
        lock.unlock()
    }

    public func clear() {
        lock.lock()
        key = Data()
        keyID = ""
        epoch &+= 1
        sessionID = Self.generateSessionID()
        seenNonces.removeAll()
        eventCount = 0
        headNonce = ""
        lock.unlock()
    }

    public func isCurrent(_ revision: Revision) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return key.count == BridgeLANCrypto.keyByteCount &&
            epoch == revision.epoch &&
            BridgeInstallToken.constantTimeEquals(keyID, revision.keyID) &&
            !sessionID.isEmpty &&
            BridgeInstallToken.constantTimeEquals(sessionID, revision.sessionID)
    }

    /// Verifies, decrypts and commits one request nonce.
    ///
    /// `betweenVerifyAndCommit` is a deterministic test seam for the window
    /// between a successful MAC check and the nonce/epoch commit. Production
    /// callers omit it. The epoch/key/arm checks are repeated inside the commit
    /// lock, so a rotation or fence during that window is refused rather than
    /// sealed with the old key.
    public func open(body: Data,
                     now: Date = Date(),
                     betweenVerifyAndCommit: (() -> Void)? = nil) throws -> Opened {
        guard body.count <= limits.maxEnvelopeBytes,
              let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              BridgeLANCrypto.looksLikeEnvelope(object) else {
            throw BridgeLANCrypto.Failure(code: "bad_envelope",
                                          message: "Body must be a v1 encrypted envelope.")
        }
        let parsed = try BridgeLANCrypto.parse(object, limits: limits)

        lock.lock()
        let currentKey = key
        let currentKeyID = keyID
        let currentEpoch = epoch
        lock.unlock()

        guard currentKey.count == BridgeLANCrypto.keyByteCount,
              BridgeInstallToken.constantTimeEquals(parsed.tokId, currentKeyID) else {
            throw BridgeLANCrypto.Failure(code: "auth_failed", message: "Authentication failed.")
        }
        let nowSeconds = Int(now.timeIntervalSince1970)
        let delta = nowSeconds - parsed.timestamp
        guard abs(delta) <= Int(limits.timestampWindow) else {
            throw BridgeLANCrypto.Failure(code: "ts_skew",
                                          message: "Timestamp outside the accepted window.")
        }

        let plaintext: Data
        do {
            plaintext = try BridgeLANCrypto.open(parsed, key: currentKey)
        } catch let failure as BridgeLANCrypto.Failure {
            throw failure
        }

        betweenVerifyAndCommit?()

        lock.lock()
        guard epoch == currentEpoch,
              key.count == BridgeLANCrypto.keyByteCount,
              BridgeInstallToken.constantTimeEquals(keyID, currentKeyID) else {
            lock.unlock()
            throw BridgeLANCrypto.Failure(
                code: "auth_stale",
                message: "The control key changed before this request was committed."
            )
        }
        // Keep only nonces that could still pass the timestamp check.
        let cutoff = nowSeconds - Int(limits.timestampWindow)
        if seenNonces.count > 64 {
            seenNonces = seenNonces.filter { $0.value >= cutoff }
        }
        if seenNonces[parsed.nonceHex] != nil {
            lock.unlock()
            throw BridgeLANCrypto.Failure(code: "nonce_replayed", message: "Duplicate nonce.")
        }
        guard seenNonces.count < limits.nonceCapacity else {
            lock.unlock()
            throw BridgeLANCrypto.Failure(code: "nonce_flood", message: "Too many nonces.")
        }
        seenNonces[parsed.nonceHex] = parsed.timestamp
        eventCount += 1
        headNonce = parsed.nonceHex
        let revision = Revision(epoch: epoch, keyID: keyID, sessionID: sessionID,
                                eventCount: eventCount, headNonce: headNonce)
        lock.unlock()

        let seal: @Sendable (Data) -> Data? = { [weak self] data in
            guard let self, self.isCurrent(revision) else { return nil }
            return BridgeLANCrypto.sealResponse(
                data, key: currentKey, nonce: parsed.nonce, nonceHex: parsed.nonceHex
            )
        }
        return Opened(tokenID: parsed.tokId, plaintext: plaintext,
                      revision: revision, auth: self, seal: seal)
    }
}
