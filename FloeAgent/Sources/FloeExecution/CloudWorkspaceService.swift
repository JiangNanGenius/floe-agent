import Foundation
import FloeCore
import FloeSSH

/// Direct client for the loopback-only helper installed on a paired host.
/// The HTTP hop is carried by Citadel direct-tcpip inside the verified SSH
/// session. Its bearer token remains process-local and is never returned to
/// the model or persisted by Floe.
public actor CloudWorkspaceService {
    private struct Connection {
        var session: SSHSessionHandle
        var forwarder: LoopbackSSHForwarder
        var baseURL: URL
        var token: String
        var lastUsedAt: Date
    }

    private let ssh: SSHCommandService
    private let advanced: AdvancedRemoteClient
    private var connections: [UUID: Connection] = [:]

    public init(ssh: SSHCommandService, advanced: AdvancedRemoteClient = AdvancedRemoteClient()) {
        self.ssh = ssh
        self.advanced = advanced
    }

    public func request(
        hostID: UUID?,
        port: Int = RemoteAgentPayload.defaultPort,
        method: String,
        endpoint: String,
        queryPath: String? = nil,
        body: [String: String]? = nil
    ) async throws -> Data {
        // Once a device has an advanced link, routine operations must not
        // silently fall back to port 22. A failed mTLS request is surfaced so
        // the user can explicitly repair/re-enrol through SSH.
        if let hostID, await AdvancedRemoteLinkStore.shared.link(hostID: hostID) != nil {
            return try await advanced.request(
                hostID: hostID, method: method, endpoint: endpoint,
                queryPath: queryPath, body: body
            )
        }
        let (resolvedID, connection) = try await connection(hostID: hostID, port: port)
        var components = URLComponents(url: connection.baseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)
        if let queryPath { components?.queryItems = [URLQueryItem(name: "path", value: queryPath)] }
        guard let url = components?.url else { throw FloeError.validationFailed("Invalid cloud workspace request") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            connections.removeValue(forKey: resolvedID)
            let detail = String(decoding: data.prefix(2_048), as: UTF8.self)
            throw FloeError.validationFailed("Cloud workspace request failed: \(detail)")
        }
        if var updated = connections[resolvedID] {
            updated.lastUsedAt = Date()
            connections[resolvedID] = updated
        }
        return data
    }

    public func closeIdleConnections(olderThan age: TimeInterval = 300) async {
        let cutoff = Date().addingTimeInterval(-max(30, age))
        let ids = connections.compactMap { $0.value.lastUsedAt < cutoff ? $0.key : nil }
        for id in ids {
            guard let item = connections.removeValue(forKey: id) else { continue }
            await item.forwarder.close()
            await item.session.close()
        }
    }

    private func connection(hostID: UUID?, port: Int) async throws -> (UUID, Connection) {
        if let hostID, let existing = connections[hostID], existing.session.isConnected {
            return (hostID, existing)
        }
        let (resolvedID, session) = try await ssh.openTunnelSession(hostID: hostID)
        if let existing = connections.removeValue(forKey: resolvedID) {
            await existing.forwarder.close()
            await existing.session.close()
        }
        let tokenResult = try await session.executeBounded(
            "cat \"$HOME/.config/floe-agent/token\"",
            timeout: 10,
            maxOutputBytes: 1_024
        )
        let token = tokenResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tokenResult.exitCode == 0, token.count >= 32 else {
            await session.close()
            throw FloeError.validationFailed("Floe remote workspace agent is not installed or initialized")
        }
        let forwarder = try await LoopbackSSHForwarder.start(
            session: session,
            targetHost: "127.0.0.1",
            targetPort: port
        )
        guard let endpoint = forwarder.endpoint,
              let baseURL = URL(string: "http://\(endpoint.host):\(endpoint.port)/") else {
            await forwarder.close()
            await session.close()
            throw FloeError.internalError("Cloud workspace SSH tunnel has no local endpoint")
        }
        let value = Connection(
            session: session, forwarder: forwarder, baseURL: baseURL,
            token: token, lastUsedAt: Date()
        )
        connections[resolvedID] = value
        return (resolvedID, value)
    }
}
