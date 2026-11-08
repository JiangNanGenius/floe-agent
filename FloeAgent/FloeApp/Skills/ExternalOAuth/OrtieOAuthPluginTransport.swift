import Foundation
import CoreFoundation

/// Native-only seam. The concrete bridge delegates to the existing Linux
/// service's owned private worker; no ToolCall or public shell is involved.
protocol ExternalOAuthPrivateWorker: Sendable {
    func exchange(_ request: Data) async throws -> Data
    func stop() async -> Bool
}

struct ExternalOAuthPrivateWorkerRequest: Sendable {
    let environmentID: String
    let ownershipKey: String
    let account: String
    let configurationTOML: String
    let useClientSecret: Bool
    let readToken: @Sendable () async throws -> Data?
    let writeToken: @Sendable (Data) async throws -> Void
    let readClientSecret: @Sendable () async throws -> Data?
    let invalidateAndJoin: @Sendable () async -> Void
}

protocol ExternalOAuthPrivateWorkerOpening: Sendable {
    /// The opener owns a verified component authority/path, rather than
    /// accepting an executable or command from a Skill/model payload.
    func open(_ request: ExternalOAuthPrivateWorkerRequest) async throws -> any ExternalOAuthPrivateWorker
}

actor OrtieOAuthPluginTransport: ExternalOAuthPluginTransport {
    nonisolated let credentialContext: ExternalOAuthCredentialContext
    private let vault: ExternalOAuthVaultAdapter
    private let opener: any ExternalOAuthPrivateWorkerOpening
    private let environmentID: String
    private let ownershipKey: String
    private let expectedInitialize: Data
    private let expectedTools: Data
    private var worker: (any ExternalOAuthPrivateWorker)?
    private var sequence = 0
    private var generation = UUID()
    private var cancelled = false
    private var pendingPolicy: ExternalOAuthAuthorizationPolicy?
    private var didResume = false
    private var requestInFlight = false
    private var requestWaiters: [CheckedContinuation<Void, any Error>] = []

    init(context: ExternalOAuthCredentialContext, vault: ExternalOAuthVaultAdapter,
         opener: any ExternalOAuthPrivateWorkerOpening, ownershipKey: String, handshake: Data) throws {
        guard case .linuxEnvironment(let environmentID) = context.location,
              ownershipKey.utf8.count == 64,
              ownershipKey.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              handshake.count <= 65_536,
              let fixture = try JSONSerialization.jsonObject(with: handshake) as? [String: Any],
              let initialize = fixture["initialize"] as? [String: Any],
              let tools = fixture["toolsList"] as? [String: Any] else {
            throw ExternalOAuthFailure.invalidAuthorization
        }
        self.credentialContext = context; self.vault = vault; self.opener = opener
        self.environmentID = environmentID; self.ownershipKey = ownershipKey
        expectedInitialize = try Self.canonical(initialize)
        expectedTools = try Self.canonical(tools)
    }

    func begin(client: ExternalOAuthClientProfile, redirectURI: URL?) async throws -> ExternalOAuthOffer {
        guard client == credentialContext.client else { throw ExternalOAuthFailure.invalidAuthorization }
        try await open(client: client, redirect: redirectURI)
        let value = try await call("auth_get")
        let offer: ExternalOAuthOffer
        if value["kind"] as? String == "authorization", let redirectURI,
           let text = value["authorizationUri"] as? String, let url = URL(string: text) {
            pendingPolicy = try ExternalOAuthAuthorizationPolicy(authorizationURL: url, client: client, redirect: redirectURI)
            offer = .init(kind: .authorization, url: url, userCode: nil)
        } else if value["kind"] as? String == "device",
                  let text = value["verificationUri"] as? String, let url = URL(string: text),
                  let code = value["userCode"] as? String {
            offer = .init(kind: .device, url: url, userCode: code,
                completeURL: (value["verificationUriComplete"] as? String).flatMap(URL.init(string:)), expiresIn: nil)
            try ExternalOAuthAuthorizationPolicy.validateDeviceOffer(offer, provider: client.provider)
        } else { throw ExternalOAuthFailure.pluginUnavailable }
        return offer
    }

    func resume(callback: URL) async throws {
        guard let pendingPolicy, !didResume else { throw ExternalOAuthFailure.invalidCallback }
        try pendingPolicy.validate(callback: callback)
        didResume = true
        _ = try await call("auth_resume", arguments: ["uri": callback.absoluteString])
    }

    func status() async throws -> ExternalOAuthProgress {
        let result = try await call("auth_status")
        switch result["status"] as? String {
        case "pending": return .pending
        case "failed": return .failed
        case "issued":
            guard await vault.hasPersistedGrant() else { throw ExternalOAuthFailure.storageUnavailable }
            return .issued
        default: throw ExternalOAuthFailure.pluginUnavailable
        }
    }

    func refresh(client: ExternalOAuthClientProfile) async throws {
        guard client == credentialContext.client else { throw ExternalOAuthFailure.invalidAuthorization }
        try await open(client: client, redirect: nil)
        _ = try await call("token_refresh")
        guard await vault.hasPersistedGrant() else { throw ExternalOAuthFailure.storageUnavailable }
    }

    func cancel() async {
        _ = await stopAndConfirm()
    }

    /// Native management retains its environment lease until this confirms
    /// termination. The public transport contract carries no worker details.
    func stopAndConfirm() async -> Bool {
        cancelled = true; generation = UUID(); pendingPolicy = nil
        let waiting = requestWaiters; requestWaiters.removeAll()
        for waiter in waiting { waiter.resume(throwing: ExternalOAuthFailure.cancelled) }
        // This closes admission and joins any existing native write BEFORE
        // the worker and broker are released or a replacement can start.
        await vault.invalidateAndJoin()
        if let worker {
            guard await worker.stop() else { return false }
            self.worker = nil
            // A failed confirmation remains owned by the existing supervisor;
            // that owner key blocks a replacement until stop is established.
        }
        return true
    }

    private func open(client: ExternalOAuthClientProfile, redirect: URL?) async throws {
        try requireActive()
        guard worker == nil else { throw ExternalOAuthFailure.pluginUnavailable }
        try await vault.prepare()
        let useSecret = try await vault.readClientSecret() != nil
        try requireActive()
        let ticket = generation
        let opened = try await opener.open(.init(environmentID: environmentID, ownershipKey: ownershipKey,
            account: "floe", configurationTOML: try Self.configuration(client: client, redirect: redirect),
            useClientSecret: useSecret,
            readToken: { [vault] in try await vault.readToken() },
            writeToken: { [vault] value in try await vault.writeToken(value) },
            readClientSecret: { [vault] in try await vault.readClientSecret() },
            invalidateAndJoin: { [vault] in await vault.invalidateAndJoin() }))
        guard !cancelled, generation == ticket else { _ = await opened.stop(); throw ExternalOAuthFailure.cancelled }
        worker = opened
        let initialize = try await rpc("initialize", parameters: ["protocolVersion": "2025-06-18",
            "capabilities": [:], "clientInfo": ["name": "Floe", "version": "1"]])
        guard try Self.canonical(initialize) == expectedInitialize else { throw ExternalOAuthFailure.pluginUnavailable }
        let tools = try await rpc("tools/list", parameters: [:])
        guard try Self.canonical(tools) == expectedTools else { throw ExternalOAuthFailure.pluginUnavailable }
    }

    private func call(_ name: String, arguments: [String: String] = [:]) async throws -> [String: Any] {
        guard ["token_inspect", "auth_get", "auth_status", "auth_resume", "token_refresh"].contains(name) else {
            throw ExternalOAuthFailure.pluginUnavailable
        }
        let result = try await rpc("tools/call", parameters: ["name": name, "arguments": arguments])
        guard result["isError"] as? Bool != true,
              let value = result["structuredContent"] as? [String: Any] else {
            // Provider and process error details never leave this private lane.
            throw ExternalOAuthFailure.pluginUnavailable
        }
        return value
    }

    private func rpc(_ method: String, parameters: [String: Any]) async throws -> [String: Any] {
        try requireActive()
        try await acquireRequest()
        defer { releaseRequest() }
        guard let worker else { throw ExternalOAuthFailure.pluginUnavailable }
        sequence += 1
        let id = sequence, ticket = generation
        let request = try Self.canonical(["jsonrpc": "2.0", "id": id, "method": method, "params": parameters])
        guard request.count <= 65_536 else { throw ExternalOAuthFailure.pluginUnavailable }
        let response: Data
        do { response = try await worker.exchange(request) }
        catch { throw cancelled ? ExternalOAuthFailure.cancelled : .pluginUnavailable }
        try requireActive()
        guard generation == ticket, response.count <= 65_536,
              let value = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              Set(value.keys) == ["jsonrpc", "id", "result"],
              value["jsonrpc"] as? String == "2.0",
              let identifier = value["id"] as? NSNumber, CFGetTypeID(identifier) != CFBooleanGetTypeID(),
              identifier.intValue == id, identifier.doubleValue == Double(id),
              value["error"] == nil, let result = value["result"] as? [String: Any] else {
            throw ExternalOAuthFailure.pluginUnavailable
        }
        return result
    }

    /// auth_status polling may overlap a real callback. Queue the callback
    /// behind the one active exchange rather than spuriously failing login.
    private func acquireRequest() async throws {
        try requireActive()
        if requestInFlight {
            try await withCheckedThrowingContinuation { requestWaiters.append($0) }
            do { try requireActive() }
            catch { releaseRequest(); throw error }
        } else { requestInFlight = true }
    }

    private func releaseRequest() {
        if !cancelled, !requestWaiters.isEmpty { requestWaiters.removeFirst().resume() }
        else { requestInFlight = false }
    }

    private func requireActive() throws {
        guard !cancelled, !Task.isCancelled else { throw ExternalOAuthFailure.cancelled }
    }

    private static func canonical(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func configuration(client: ExternalOAuthClientProfile, redirect: URL?) throws -> String {
        func quote(_ value: String) throws -> String {
            let array = try canonical([value])
            return String(decoding: array.dropFirst().dropLast(), as: UTF8.self)
        }
        var lines = ["[accounts.floe]", "client-id = \(try quote(client.clientID))", "auto-refresh = true",
            "pkce = \"s256\"", "scopes = [\(try client.scopes.sorted().map(quote).joined(separator: ","))]",
            "resources = [\(try client.resources.sorted().map(quote).joined(separator: ","))]"]
        switch client.provider {
        case .google:
            lines.append("endpoints.token = \"https://oauth2.googleapis.com/token\"")
            if client.grant == .device { lines.append("endpoints.device-authorization = \"https://oauth2.googleapis.com/device/code\"") }
        case .microsoft:
            let root = client.authorizationEndpoint.deletingLastPathComponent()
            lines.append("endpoints.token = \(try quote(root.appendingPathComponent("token").absoluteString))")
            if client.grant == .device { lines.append("endpoints.device-authorization = \(try quote(root.appendingPathComponent("devicecode").absoluteString))") }
        }
        if client.grant == .device { lines.append("grant = \"device\"") }
        else {
            lines.append("endpoints.authorization = \(try quote(client.authorizationEndpoint.absoluteString))")
            if let redirect { lines.append("endpoints.redirection = \(try quote(redirect.absoluteString))") }
        }
        for (key, value) in client.authorizationExtras.sorted(by: { $0.key < $1.key }) { lines.append("extras.\(key) = \(try quote(value))") }
        return lines.joined(separator: "\n") + "\n"
    }
}
