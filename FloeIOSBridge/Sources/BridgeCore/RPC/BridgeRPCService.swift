import Foundation

/// Transport-independent Bridge 1.0 HTTP surface. The host transport parses
/// bounded HTTP bytes, supplies the verified peer identity and calls this
/// service. All listeners share one authority, executor registry, coordinator
/// and stream registry through this object.
public final class BridgeRPCService: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        public var requestedPort: UInt16
        public var lanEnabled: Bool
        public var bonjourEnabled: Bool
        public var limits: BridgeRPCLimits

        public init(requestedPort: UInt16 = 8200,
                    lanEnabled: Bool = false,
                    bonjourEnabled: Bool = false,
                    limits: BridgeRPCLimits = .default) {
            self.requestedPort = requestedPort
            self.lanEnabled = lanEnabled
            self.bonjourEnabled = bonjourEnabled
            self.limits = limits
        }
    }

    private struct ActiveStream {
        let clientID: String
        let channel: BridgeRPCStreamChannel
    }

    private let lock = BridgeRPCLock()
    private let authority: BridgeRPCAuthority
    private let registry: BridgeRPCEngineRegistry
    private let coordinator: BridgeRPCExecutionCoordinator
    private let resources: any BridgeRPCResourceProvider
    private let logs: (any BridgeRPCLogSource)?
    private let streamSource: (any BridgeRPCStreamSource)?
    private let limits: BridgeRPCLimits

    private var configuration: Configuration
    private var actualPort: UInt16
    private var actualLANReady = false
    private var bonjourState = "off"
    private var serverEpoch: UInt64 = 0
    private var serving = false
    private var stopping = false
    private var streams: [UUID: ActiveStream] = [:]
    private var stopHandler: (@Sendable () -> Void)?
    private var clientConnectionRevokedHandler: (@Sendable (String) -> Void)?
    private var allConnectionsRevokedHandler: (@Sendable () -> Void)?
    private var clientStateHandler: (@Sendable () -> Void)?

    public init(configuration: Configuration,
                authority: BridgeRPCAuthority,
                registry: BridgeRPCEngineRegistry,
                coordinator: BridgeRPCExecutionCoordinator,
                resources: any BridgeRPCResourceProvider = BridgeRPCEmptyResources(),
                logs: (any BridgeRPCLogSource)? = nil,
                streamSource: (any BridgeRPCStreamSource)? = nil) {
        self.configuration = configuration
        self.limits = configuration.limits
        self.authority = authority
        self.registry = registry
        self.coordinator = coordinator
        self.resources = resources
        self.logs = logs
        self.streamSource = streamSource
        self.actualPort = configuration.requestedPort
        self.actualLANReady = configuration.lanEnabled
        self.bonjourState = configuration.bonjourEnabled ? "starting" : "off"

        authority.setClientRevokedObserver { [weak self] clientID in
            guard let self else { return }
            self.closeStreams(for: clientID)
            self.lock.lock()
            let handler = self.clientConnectionRevokedHandler
            self.lock.unlock()
            handler?(clientID)
        }
        authority.setAllRevokedObserver { [weak self] in
            guard let self else { return }
            self.closeAllStreams()
            self.lock.lock()
            let handler = self.allConnectionsRevokedHandler
            self.lock.unlock()
            handler?()
        }
        authority.setClientStateObserver { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let handler = self.clientStateHandler
            self.lock.unlock()
            handler?()
        }
    }

    public var authAuthority: BridgeRPCAuthority { authority }
    public var engineRegistry: BridgeRPCEngineRegistry { registry }
    public var executionCoordinator: BridgeRPCExecutionCoordinator { coordinator }

    public func setStopHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        stopHandler = handler
        lock.unlock()
    }

    /// Host transport hooks for closing sockets already associated with a
    /// client. Streams are closed by the service itself; HTTP connections are
    /// tagged by the host before the first committed byte.
    public func setClientRevocationHandler(_ handler: (@Sendable (String) -> Void)?) {
        lock.lock()
        clientConnectionRevokedHandler = handler
        lock.unlock()
    }

    public func setAllConnectionsRevokedHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        allConnectionsRevokedHandler = handler
        lock.unlock()
    }

    public func setClientStateHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        clientStateHandler = handler
        lock.unlock()
    }

    public func beginServing() {
        lock.lock()
        serving = true
        stopping = false
        serverEpoch &+= 1
        lock.unlock()
    }

    /// Stops admission, clears one-use tickets, refuses queued automation and
    /// closes every media stream. Paired client keys survive; the engine
    /// registry is never touched.
    public func endServing() {
        lock.lock()
        serving = false
        stopping = true
        serverEpoch &+= 1
        let active = Array(streams.values)
        streams.removeAll()
        lock.unlock()
        authority.clearStreamTickets()
        Task { await coordinator.cancelQueued() }
        for stream in active { stream.channel.cancel() }
        lock.lock()
        let allHandler = allConnectionsRevokedHandler
        lock.unlock()
        allHandler?()
    }

    public func setActualPort(_ port: UInt16) {
        lock.lock()
        actualPort = port
        lock.unlock()
    }

    public func setNetworkState(lanEnabled: Bool, lanReady: Bool, bonjourState: String) {
        lock.lock()
        configuration.lanEnabled = lanEnabled
        configuration.bonjourEnabled = bonjourState == "starting" || bonjourState == "published"
        actualLANReady = lanReady
        self.bonjourState = bonjourState
        lock.unlock()
    }

    public func setBonjourState(_ state: String) {
        lock.lock()
        bonjourState = state
        configuration.bonjourEnabled = state == "starting" || state == "published"
        lock.unlock()
    }

    public var currentPort: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return actualPort
    }

    /// Final commit point with the first byte of the response. The service
    /// epoch, serving state and client authorization are checked while holding
    /// the service lock and, for a bound client, the authority lock. Revoke/Stop
    /// therefore either happens before this call (and no byte is sent) or
    /// waits until the first byte was accepted by the kernel.
    public func commitResponse(_ token: BridgeRPCCommitToken,
                               firstByteSend: () -> Bool) -> Bool {
        lock.lock()
        guard serving,
              !stopping || token.allowsStopping,
              serverEpoch == token.serviceEpoch else {
            lock.unlock()
            return false
        }
        if let clientID = token.clientID,
           let authEpoch = token.authEpoch,
           let revision = token.clientRevision {
            let sent = authority.withCurrentClientCommit(
                clientID: clientID,
                revision: revision,
                authEpoch: authEpoch,
                firstByteSend
            )
            lock.unlock()
            return sent ?? false
        }
        let sent = firstByteSend()
        lock.unlock()
        return sent
    }

    private func commitToken(clientID: String? = nil,
                             authEpoch: UInt64? = nil,
                             clientRevision: UInt64? = nil,
                             allowsStopping: Bool = false) -> BridgeRPCCommitToken {
        lock.lock()
        let epoch = serverEpoch
        lock.unlock()
        return BridgeRPCCommitToken(
            serviceEpoch: epoch,
            clientID: clientID,
            authEpoch: authEpoch,
            clientRevision: clientRevision,
            allowsStopping: allowsStopping
        )
    }

    private func token(for opened: BridgeRPCAuthority.OpenedRequest,
                       allowsStopping: Bool = false) -> BridgeRPCCommitToken {
        commitToken(clientID: opened.clientID,
                    authEpoch: opened.authEpoch,
                    clientRevision: opened.clientRevision,
                    allowsStopping: allowsStopping)
    }

    public func snapshot() -> BridgeRPCServiceSnapshot {
        lock.lock()
        let configuration = self.configuration
        let port = self.actualPort
        let lanReady = self.actualLANReady
        let stopping = self.stopping
        lock.unlock()
        let engine = registry.snapshot()
        let logsAvailable = logs != nil
        let streamAvailable = streamSource != nil
        let capabilities = BridgeRPCMethodRegistry.capabilities(
            supportedEngineMethods: engine.supportedMethods,
            logsAvailable: logsAvailable,
            streamAvailable: streamAvailable,
            lanAvailable: configuration.lanEnabled && lanReady
        )
        return BridgeRPCServiceSnapshot(
            port: port,
            lanEnabled: configuration.lanEnabled,
            bonjourEnabled: configuration.bonjourEnabled,
            engine: engine,
            clientCount: authority.clientMetadata().count,
            capabilities: capabilities,
            stopping: stopping,
            skillAvailable: resources.skillMarkdown() != nil,
            remoteUIAvailable: resources.remotePageHTML() != nil,
            streamAvailable: streamAvailable,
            logsAvailable: logsAvailable
        )
    }

    // MARK: - HTTP routing

    public func handle(_ request: BridgeRPCHTTPRequest,
                       peer: BridgeRPCPeerInfo) async -> BridgeRPCHTTPResult {
        guard peer.isAcceptedTransport else {
            return .response(.error(403, code: "transport_denied",
                                    message: "This connection type is not accepted by Bridge."))
        }
        lock.lock()
        let accepting = serving && !stopping
        lock.unlock()
        guard accepting else {
            return .response(.error(503, code: "service_stopping",
                                    message: "The Bridge service is not accepting requests."))
        }

        switch request.pathOnly {
        case "/":
            guard request.method == "GET" else { return methodNotAllowed("GET") }
            return .response(infoResponse())
        case "/schema":
            guard request.method == "GET" else { return methodNotAllowed("GET") }
            return .response(schemaResponse())
        case "/skill", "/skill.md":
            guard request.method == "GET" else { return methodNotAllowed("GET") }
            return .response(skillResponse())
        case "/remote":
            guard request.method == "GET" else { return methodNotAllowed("GET") }
            return .response(remoteResponse())
        case "/pair":
            guard request.method == "POST" else { return methodNotAllowed("POST") }
            return .response(await pairResponse(body: request.body, peer: peer))
        case "/rpc":
            guard request.method == "POST" else { return methodNotAllowed("POST") }
            return .response(await rpcResponse(body: request.body, peer: peer))
        case "/stream", "/stream.ts":
            guard request.method == "GET" else { return methodNotAllowed("GET") }
            return await streamResponse(query: request.query, peer: peer)
        case "/logs", "/logs/files", "/logs/history":
            guard request.method == "GET" else { return methodNotAllowed("GET") }
            return .response(logsResponse(path: request.pathOnly, query: request.query, peer: peer))
        case "/whoami":
            guard request.method == "GET" else { return methodNotAllowed("GET") }
            return .response(.error(404, code: "not_found", message: "Not Found"))
        default:
            return .response(.error(404, code: "not_found", message: "Not Found"))
        }
    }

    private func methodNotAllowed(_ allow: String) -> BridgeRPCHTTPResult {
        .response(BridgeRPCHTTPResponse(
            status: 405,
            headers: ["Allow": allow, "Content-Type": "application/json; charset=utf-8"],
            body: BridgeRPCHTTPResponse.error(405, code: "method_not_allowed",
                                               message: "Method not allowed").body
        ))
    }

    // MARK: - Static / info endpoints

    private func infoResponse() -> BridgeRPCHTTPResponse {
        let snapshot = snapshot()
        let engineState: String
        switch snapshot.engine.readiness {
        case .notRegistered: engineState = "not_registered"
        case .notReady: engineState = "not_ready"
        case .ready: engineState = "ready"
        }
        return .json(200, .object([
            "product": .string(BridgeRPCVersion.productName),
            "server_version": .string(BridgeRPCVersion.serverVersion),
            "protocol_version": .int(BridgeRPCVersion.protocolVersion),
            "transport": .string("localhost-first; 127.0.0.1 and ::1; optional normal-LAN listener"),
            "lan_enabled": .bool(snapshot.lanEnabled),
            "engine": .string(engineState),
            "capabilities": .array(snapshot.capabilities.map { .string($0) }),
            "endpoints": .array([
                .string("GET /schema"),
                .string("GET /skill"),
                .string("POST /pair"),
                .string("POST /rpc"),
                .string("GET /logs?ticket=<t>"),
                .string("GET /stream?ticket=<t>"),
            ]),
            "note": .string("Set up pairing and inspection before the automation engine is ready."),
        ]))
    }

    private func schemaResponse() -> BridgeRPCHTTPResponse {
        let snapshot = snapshot()
        let availableServices: Set<String>
        lock.lock()
        let logsAvailable = logs != nil
        let streamAvailable = streamSource != nil
        lock.unlock()
        var services: Set<String> = ["config"]
        if logsAvailable { services.insert("logs") }
        if streamAvailable { services.insert("stream_ticket") }
        availableServices = services
        let schema = BridgeRPCMethodRegistry.generateJSONSchema(
            supportedEngineMethods: snapshot.engine.supportedMethods,
            availableServiceMethods: availableServices,
            capabilities: snapshot.capabilities
        )
        return .json(200, .object(schema))
    }

    private func skillResponse() -> BridgeRPCHTTPResponse {
        guard let markdown = resources.skillMarkdown() else {
            return .error(503, code: "skill_unavailable",
                          message: "The Bridge skill manual is not bundled in this build.")
        }
        var headers = ["Content-Type": "text/markdown; charset=utf-8",
                       "Cache-Control": "no-cache"]
        headers["X-Bridge-Skill-Version"] = BridgeRPCVersion.skillVersion
        return BridgeRPCHTTPResponse(status: 200, headers: headers, body: Data(markdown.utf8))
    }

    private func remoteResponse() -> BridgeRPCHTTPResponse {
        guard let page = resources.remotePageHTML() else {
            return .error(503, code: "remote_ui_unavailable",
                          message: "The remote control page is not included in this package.")
        }
        var headers = resources.remotePageHeaders
        headers["Content-Type"] = "text/html; charset=utf-8"
        headers["Cache-Control"] = "no-store"
        headers["X-Content-Type-Options"] = "nosniff"
        headers["X-Frame-Options"] = "DENY"
        headers["Referrer-Policy"] = "no-referrer"
        headers["Cross-Origin-Resource-Policy"] = "same-origin"
        return BridgeRPCHTTPResponse(
            status: 200,
            headers: headers,
            body: Data(page.utf8)
        )
    }

    // MARK: - Pairing

    private func pairResponse(body: Data, peer: BridgeRPCPeerInfo) async -> BridgeRPCHTTPResponse {
        lock.lock()
        let blocked = stopping
        lock.unlock()
        guard !blocked else {
            return .error(503, code: "service_stopping", message: "The Bridge service is stopping.")
        }
        guard !body.isEmpty, body.count <= limits.maxRequestBodyBytes,
              let value = try? BridgeRPCJSON.decode(body),
              let object = value.objectValue else {
            return .error(400, code: "bad_request", message: "A JSON object body is required.")
        }
        guard let clientName = object["client_name"]?.stringValue, !clientName.isEmpty else {
            return .error(400, code: "bad_request", message: "client_name is required.")
        }
        let plain = object["plain"]?.boolValue ?? false
        var clientPublicKey: Data?
        if !plain {
            guard let encoded = object["pub"]?.stringValue,
                  let data = Data(base64Encoded: encoded, options: []),
                  data.count == 32,
                  data.base64EncodedString() == encoded else {
                return .error(400, code: "bad_request",
                              message: "Provide plain:true (loopback only) or pub (base64 raw 32B X25519).")
            }
            clientPublicKey = data
        }
        // The transport supplies the kernel peer address. Headers are never
        // consulted, so `X-Forwarded-For` or a spoofed Host cannot turn a LAN
        // request into a plaintext grant.
        if plain && !peer.allowsPlainPairing {
            return .error(403, code: "plain_forbidden",
                          message: "Plain grant is localhost-only; use X25519 mode.")
        }

        let fingerprint = clientPublicKey.map(BridgeRPCEnvelope.fingerprint)
        let outcome = await authority.requestPairing(
            clientName: clientName,
            peer: peer,
            fingerprint: fingerprint
        )

        switch outcome {
        case .busy(let retryAfter):
            return .error(429, code: "pair_busy",
                          message: "Another pairing request is waiting for owner approval.",
                          extra: ["retry_after": .int(retryAfter)])
        case .coolingDown(let retryAfter):
            return .error(429, code: "pair_cooldown",
                          message: "A pairing request was just refused; try again shortly.",
                          extra: ["retry_after": .int(retryAfter)])
        case .denied:
            return .error(403, code: "pair_denied",
                          message: "The device owner rejected or did not answer the request.")
        case .unavailable(let code, let message):
            let status = code == "bad_request" ? 400 : (code == "transport_denied" ? 403 : 500)
            return .error(status, code: code, message: message)
        case .approved(let grant):
            let expires = Int(grant.expiresAt.timeIntervalSince1970)
            var payload: [String: BridgeRPCJSONValue] = [
                "tok": .string(grant.clientID),
                "client_name": .string(grant.clientName),
                "expires": .int(expires),
            ]
            if let clientPublicKey {
                do {
                    let wrapped = try BridgeRPCEnvelope.wrapKey(grant.key,
                                                               clientPublicKey: clientPublicKey)
                    payload["pub"] = .string(wrapped.devicePublicKey.base64EncodedString())
                    payload["token_ct"] = .string(BridgeRPCEnvelope.hexLowercase(wrapped.tokenCiphertext))
                } catch {
                    authority.revoke(clientID: grant.clientID)
                    return .error(400, code: "bad_request", message: "X25519 key agreement failed.")
                }
            } else {
                payload["token"] = .string(BridgeRPCEnvelope.hexLowercase(grant.key))
            }
            var response = BridgeRPCHTTPResponse.json(200, .object(payload))
            response.commitToken = commitToken(
                clientID: grant.clientID,
                authEpoch: authority.currentAuthEpoch,
                clientRevision: grant.revision
            )
            return response
        }
    }

    // MARK: - JSON-RPC

    private func rpcResponse(body: Data, peer: BridgeRPCPeerInfo) async -> BridgeRPCHTTPResponse {
        guard !body.isEmpty else {
            return .error(400, code: "bad_envelope", message: "Body must be a v1 encrypted envelope.")
        }
        guard body.count <= limits.maxRequestBodyBytes else {
            return .error(413, code: "request_body_too_large",
                          message: "The encrypted request body exceeds the bounded size.")
        }
        guard let value = try? BridgeRPCJSON.decode(body), value.objectValue != nil else {
            return .error(400, code: "bad_envelope", message: "Body must be a v1 encrypted envelope.")
        }
        guard BridgeRPCEnvelope.looksLikeEnvelope(value) else {
            return .error(401, code: "auth_required",
                          message: "Encrypted envelope required. Pair first, then seal each JSON-RPC body.")
        }

        let opened: BridgeRPCAuthority.OpenedRequest
        do {
            opened = try authority.openEnvelope(value, peer: peer)
        } catch let failure as BridgeRPCEnvelope.Failure {
            let status = failure.code == "bad_envelope" ? 400 : 401
            return .error(status, code: failure.code, message: failure.message)
        } catch {
            return .error(401, code: "auth_failed", message: BridgeRPCEnvelope.authFailureMessage)
        }

        let request: BridgeRPCRequest
        do {
            request = try BridgeRPCRequest.decode(opened.plaintext)
        } catch let error as BridgeRPCRequestError {
            switch error {
            case .invalidParams:
                return sealed(opened: opened, id: nil, error: .invalidParams)
            case .malformed, .invalidID, .invalidOperationID:
                return sealed(opened: opened, id: nil, error: .invalidRequest)
            }
        } catch {
            return sealed(opened: opened, id: nil, error: .parseError)
        }
        guard request.jsonrpc == "2.0" else {
            return sealed(opened: opened, id: request.id, error: .invalidRequest)
        }

        switch request.method {
        case "stream_ticket":
            lock.lock()
            let streamAvailable = streamSource != nil
            lock.unlock()
            guard streamAvailable else {
                return sealed(opened: opened, id: request.id, error: .methodNotAvailable)
            }
            guard let ticket = authority.issueStreamTicket(clientID: opened.clientID) else {
                return sealed(opened: opened, id: request.id, error: .internalError)
            }
            return sealed(opened: opened, id: request.id, result: .object([
                "ticket": .string(ticket.ticket),
                "expires_in": .int(ticket.expiresIn),
                "hint": .string("Append ?ticket=<ticket> to GET /stream or /logs. Single use."),
            ]))
        case "config":
            return configResponse(opened: opened, request: request)
        case "logs":
            return logsRPCResponse(opened: opened, request: request)
        default:
            return await engineResponse(opened: opened, request: request)
        }
    }

    private func configResponse(opened: BridgeRPCAuthority.OpenedRequest,
                                request: BridgeRPCRequest) -> BridgeRPCHTTPResponse {
        let params = request.params?.objectValue ?? [:]
        if params["stop_server"]?.boolValue == true {
            lock.lock()
            stopping = true
            let handler = stopHandler
            lock.unlock()
            let payload = configPayload(stopping: true)
            let response = sealed(opened: opened, id: request.id, result: payload,
                                  allowsStopping: true)
            if let handler {
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) {
                    handler()
                }
            }
            return response
        }
        let escalatingKeys = [
            "allow_remote_access", "listen_port", "revoke_session_id", "clear_sessions",
            "nearby_discovery", "device_name",
        ]
        if escalatingKeys.contains(where: { params[$0] != nil }) {
            return sealed(opened: opened, id: request.id, error: .permissionDenied)
        }
        return sealed(opened: opened, id: request.id, result: configPayload(stopping: false))
    }

    private func configPayload(stopping: Bool) -> BridgeRPCJSONValue {
        let snapshot = snapshot()
        let clients = authority.clientMetadata().map { client in
            BridgeRPCJSONValue.object([
                "client_id": .string(client.clientID),
                "client_name": .string(client.clientName),
                "granted_at": .int(Int(client.grantedAt.timeIntervalSince1970)),
                "last_active_at": .int(Int(client.lastActiveAt.timeIntervalSince1970)),
                "expires_at": .int(Int(client.lastActiveAt
                    .addingTimeInterval(limits.inactivityWindow).timeIntervalSince1970)),
                "last_address": client.lastAddress.map { .string($0) } ?? .null,
                "last_via": client.lastVia.map { .string($0.rawValue) } ?? .null,
                "sensitive_input_granted": .bool(client.sensitiveInputGranted),
            ])
        }
        let engineState: String
        let engineReason: BridgeRPCJSONValue
        switch snapshot.engine.readiness {
        case .notRegistered:
            engineState = "not_registered"
            engineReason = .null
        case .notReady(let reason):
            engineState = "not_ready"
            engineReason = .string(reason)
        case .ready:
            engineState = "ready"
            engineReason = .null
        }
        return .object([
            "port": .int(Int(snapshot.port)),
            "lan_enabled": .bool(snapshot.lanEnabled),
            "bonjour_enabled": .bool(snapshot.bonjourEnabled),
            "engine": .object([
                "state": .string(engineState),
                "reason": engineReason,
                "supported_methods": .array(snapshot.engine.supportedMethods.sorted().map { .string($0) }),
            ]),
            "capabilities": .array(snapshot.capabilities.map { .string($0) }),
            "clients": .array(clients),
            "stopping": .bool(stopping),
        ])
    }

    private func logsRPCResponse(opened: BridgeRPCAuthority.OpenedRequest,
                                 request: BridgeRPCRequest) -> BridgeRPCHTTPResponse {
        guard let logs else {
            return sealed(opened: opened, id: request.id, error: .methodNotAvailable)
        }
        let params = request.params?.objectValue ?? [:]
        let filter = params["text"]?.stringValue
        let requested = params["max_elements"]?.intValue ?? 80
        let limit = min(max(requested, 1), 500)
        let lines = logs.recentLog(limit: limit, matching: filter)
        return sealed(opened: opened, id: request.id, result: .object([
            "lines": .array(lines.map { .string($0) }),
            "count": .int(lines.count),
            "total": .int(lines.count),
            "hint": .string("Redacted server log lines. Input text and key material are never included."),
        ]))
    }

    private func engineResponse(opened: BridgeRPCAuthority.OpenedRequest,
                                request: BridgeRPCRequest) async -> BridgeRPCHTTPResponse {
        guard BridgeRPCMethodRegistry.methodNames.contains(request.method) else {
            return sealed(opened: opened, id: request.id, error: .methodNotFound)
        }
        let snapshot = registry.snapshot()
        guard let executor = registry.currentExecutor(), case .ready = snapshot.readiness else {
            let reason: String
            switch snapshot.readiness {
            case .notReady(let value): reason = value
            case .notRegistered: reason = "No automation engine is registered."
            case .ready: reason = ""
            }
            return sealed(opened: opened, id: request.id, error: BridgeRPCError(
                code: BridgeRPCError.engineNotReady.code,
                message: BridgeRPCError.engineNotReady.message,
                data: ["reason": .string(reason)]
            ))
        }
        guard snapshot.supportedMethods.contains(request.method) else {
            return sealed(opened: opened, id: request.id, error: .methodNotAvailable)
        }
        if let params = request.params, params.objectValue == nil {
            return sealed(opened: opened, id: request.id, error: .invalidParams)
        }

        var dispatchParams = (request.params ?? .object([:])).objectValue ?? [:]
        // These are never part of a method's wire parameters and must not be
        // able to influence authorization. The only source of truth is the
        // durable per-client owner grant carried by the envelope session.
        dispatchParams.removeValue(forKey: "sensitive_input")
        dispatchParams.removeValue(forKey: "sensitive_input_granted")
        dispatchParams.removeValue(forKey: "sensitive_input_allowed")
        let params = BridgeRPCJSONValue.object(dispatchParams)
        let operationID = request.operationID
            ?? BridgeRPCOperationID.makeFallback(nonceHex: opened.nonceHex)
        let invocation = BridgeRPCInvocation(
            operationID: operationID,
            clientID: opened.clientID,
            method: request.method,
            params: params,
            sensitiveInputGranted: opened.sensitiveInputGranted,
            receivedAt: Date()
        )
        let digest = BridgeRPCJSON.digest(params)
        lock.lock()
        let epoch = serverEpoch
        lock.unlock()
        guard let engineGeneration = snapshot.generation else {
            return sealed(opened: opened, id: request.id, error: .engineNotReady)
        }
        let fence = BridgeRPCExecutionFence(
            clientID: opened.clientID,
            authEpoch: opened.authEpoch,
            clientRevision: opened.clientRevision,
            engineGeneration: engineGeneration,
            serviceEpoch: epoch
        )
        let authority = self.authority
        let registry = self.registry
        let isCurrent: @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            guard authority.isCurrent(clientID: fence.clientID,
                                      revision: fence.clientRevision,
                                      authEpoch: fence.authEpoch) else {
                return false
            }
            guard registry.snapshot().generation == fence.engineGeneration else {
                return false
            }
            self.lock.lock()
            let currentEpoch = self.serverEpoch
            let serving = self.serving
            let stopping = self.stopping
            self.lock.unlock()
            return serving && !stopping && currentEpoch == fence.serviceEpoch
        }

        let execution = await coordinator.submit(
            invocation: invocation,
            paramsDigest: digest,
            executor: executor,
            fence: fence,
            isCurrent: isCurrent
        )

        guard opened.isCurrent() else {
            return .error(401, code: "auth_failed", message: BridgeRPCEnvelope.authFailureMessage)
        }
        lock.lock()
        let stillServing = serving && !stopping && serverEpoch == epoch
        let stoppingNow = stopping
        lock.unlock()
        guard stillServing else {
            return .error(503, code: stoppingNow ? "service_stopping" : "engine_not_ready",
                          message: stoppingNow
                            ? "The Bridge service is stopping; the response was not committed."
                            : "The Bridge service generation changed; the response was not committed.")
        }

        switch execution.outcome {
        case .success(let value):
            return sealed(opened: opened, id: request.id, result: value)
        case .failure(let error):
            return sealed(opened: opened, id: request.id, error: error)
        case .sideEffectUnknown(_, let message):
            return sealed(opened: opened, id: request.id, error: BridgeRPCError(
                code: BridgeRPCError.operationOutcomeUnknown.code,
                message: message
            ))
        }
    }

    private func sealed(opened: BridgeRPCAuthority.OpenedRequest,
                        id: BridgeRPCJSONValue?,
                        result: BridgeRPCJSONValue,
                        allowsStopping: Bool = false) -> BridgeRPCHTTPResponse {
        sealResponse(opened: opened,
                     plaintext: BridgeRPCResponse(result: result, id: id).encodedData(),
                     allowsStopping: allowsStopping)
    }

    private func sealed(opened: BridgeRPCAuthority.OpenedRequest,
                        id: BridgeRPCJSONValue?,
                        error: BridgeRPCError) -> BridgeRPCHTTPResponse {
        sealResponse(opened: opened,
                     plaintext: BridgeRPCResponse(error: error, id: id).encodedData())
    }

    private func sealResponse(opened: BridgeRPCAuthority.OpenedRequest,
                              plaintext: Data,
                              allowsStopping: Bool = false) -> BridgeRPCHTTPResponse {
        let token = token(for: opened, allowsStopping: allowsStopping)
        guard let sealed = opened.sealResponse(plaintext) else {
            return .error(401, code: "auth_failed", message: BridgeRPCEnvelope.authFailureMessage)
        }
        if sealed.count <= limits.maxJSONResponseBytes {
            return BridgeRPCHTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/json; charset=utf-8",
                          "Cache-Control": "no-store"],
                body: sealed,
                commitToken: token
            )
        }
        // A bounded error reply is sealed instead of shipping a huge body.
        let fallback = BridgeRPCResponse(error: .responseTooLarge, id: nil).encodedData()
        if let sealedFallback = opened.sealResponse(fallback),
           sealedFallback.count <= limits.maxJSONResponseBytes {
            return BridgeRPCHTTPResponse(
                status: 200,
                headers: ["Content-Type": "application/json; charset=utf-8",
                          "Cache-Control": "no-store"],
                body: sealedFallback,
                commitToken: token
            )
        }
        return .error(500, code: "response_too_large",
                      message: "The response exceeded the bounded size.")
    }

    // MARK: - Tickets / logs

    private func streamResponse(query: String, peer: BridgeRPCPeerInfo) async -> BridgeRPCHTTPResult {
        guard let source = streamSource else {
            return .response(.error(503, code: "stream_unavailable",
                                    message: "No media stream source is installed in this build."))
        }
        guard let ticket = queryValue(query, name: "ticket"),
              let consumed = authority.consumeStreamTicket(ticket) else {
            return .response(.error(401, code: "unauthorized",
                                    message: "GET /stream needs a valid single-use ?ticket=<t>."))
        }
        lock.lock()
        let atCapacity = streams.count >= limits.maxStreamConsumers
        lock.unlock()
        guard !atCapacity else {
            return .response(.error(503, code: "stream_capacity",
                                    message: "The bounded stream consumer limit is already in use."))
        }
        let channel = BridgeRPCStreamChannel(bufferBytes: limits.streamConsumerBufferBytes)
        let id = UUID()
        lock.lock()
        streams[id] = ActiveStream(clientID: consumed.clientID, channel: channel)
        lock.unlock()
        let opened = await source.openStream(clientID: consumed.clientID, channel: channel)
        guard opened,
              authority.isCurrent(clientID: consumed.clientID,
                                  revision: consumed.clientRevision,
                                  authEpoch: consumed.authEpoch) else {
            unregisterStream(id)
            channel.cancel()
            return .response(.error(opened ? 401 : 503,
                                    code: opened ? "auth_failed" : "stream_unavailable",
                                    message: opened
                                      ? "The client authorization changed before the stream opened."
                                      : "The media stream source is not ready."))
        }
        let grant = BridgeRPCStreamGrant(
            clientID: consumed.clientID,
            contentType: source.contentType,
            sequence: channel.sequence,
            commitToken: commitToken(clientID: consumed.clientID,
                                     authEpoch: consumed.authEpoch,
                                     clientRevision: consumed.clientRevision),
            cancel: { [weak self, weak channel] in
                channel?.cancel()
                self?.unregisterStream(id)
            }
        )
        return .stream(grant)
    }

    private func unregisterStream(_ id: UUID) {
        lock.lock()
        streams.removeValue(forKey: id)
        lock.unlock()
    }

    private func closeStreams(for clientID: String) {
        lock.lock()
        let closing = streams.filter { $0.value.clientID == clientID }
        for key in closing.keys { streams.removeValue(forKey: key) }
        lock.unlock()
        for stream in closing.values { stream.channel.cancel() }
    }

    private func closeAllStreams() {
        lock.lock()
        let closing = Array(streams.values)
        streams.removeAll()
        lock.unlock()
        for stream in closing { stream.channel.cancel() }
    }

    private func logsResponse(path: String, query: String, peer: BridgeRPCPeerInfo) -> BridgeRPCHTTPResponse {
        guard let logs else {
            return .error(503, code: "logs_unavailable", message: "No log source is installed.")
        }
        guard let ticket = queryValue(query, name: "ticket"),
              let consumed = authority.consumeStreamTicket(ticket) else {
            return .error(401, code: "unauthorized",
                          message: "This endpoint needs a valid single-use ?ticket=<t>.")
        }
        let token = commitToken(clientID: consumed.clientID,
                                authEpoch: consumed.authEpoch,
                                clientRevision: consumed.clientRevision)
        func attached(_ response: BridgeRPCHTTPResponse) -> BridgeRPCHTTPResponse {
            var response = response
            response.commitToken = token
            return response
        }
        switch path {
        case "/logs":
            let filter = queryValue(query, name: "text")
            let lines = logs.recentLog(limit: 500, matching: filter)
            let body = lines.joined(separator: "\n")
            let bounded = String(decoding: Data(body.utf8).prefix(1_048_576), as: UTF8.self)
            return attached(.text(200, bounded + (bounded.isEmpty ? "" : "\n")))
        case "/logs/files":
            guard let listing = logs.logFiles() else {
                return .error(503, code: "logs_unavailable", message: "Persisted log files are unavailable.")
            }
            return attached(.text(200, listing.joined(separator: "\n")))
        case "/logs/history":
            let date = queryValue(query, name: "date")
            if let date, !isCanonicalDate(date) {
                return .error(400, code: "bad_request", message: "date must be YYYY-MM-DD.")
            }
            guard let history = logs.logHistory(date: date) else {
                return .error(503, code: "logs_unavailable", message: "Persisted log history is unavailable.")
            }
            return attached(.text(200, history))
        default:
            return .error(404, code: "not_found", message: "Not Found")
        }
    }

    private func queryValue(_ query: String, name: String) -> String? {
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == Substring(name) else { continue }
            guard let value = String(parts[1]).removingPercentEncoding,
                  value.utf8.count <= 1_024,
                  !value.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F }) else {
                return nil
            }
            return value
        }
        return nil
    }

    private func isCanonicalDate(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 0x2D, bytes[7] == 0x2D else { return false }
        for (index, byte) in bytes.enumerated() where index != 4 && index != 7 {
            guard (0x30...0x39).contains(byte) else { return false }
        }
        return true
    }
}
