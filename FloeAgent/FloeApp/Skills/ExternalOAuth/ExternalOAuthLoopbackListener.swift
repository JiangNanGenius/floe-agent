#if canImport(Network)
import Foundation
@preconcurrency import Network

/// A short-lived, IPv4-loopback-only callback receiver owned by one native
/// sign-in. It is never a guest port forward or an externally reachable server.
@MainActor
final class ExternalOAuthLoopbackListener {
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var ready: CheckedContinuation<URL, any Error>?
    private var startTimeout: Task<Void, Never>?
    private var redirect: URL?
    var policy: ExternalOAuthAuthorizationPolicy?
    var onCallback: ((Result<URL, ExternalOAuthFailure>) -> Void)?
    private var delivered = false
    private var generation: UUID?

    func start() async throws -> URL {
        guard listener == nil else { throw ExternalOAuthFailure.pluginUnavailable }
        delivered = false
        let generation = UUID()
        self.generation = generation
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.generation == generation else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == generation, self.listener != nil else { return }
                switch state {
                case .ready:
                    guard let port = self.listener?.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/") else {
                        self.failStart(); return
                    }
                    self.redirect = url
                    self.startTimeout?.cancel(); self.startTimeout = nil
                    let continuation = self.ready; self.ready = nil
                    continuation?.resume(returning: url)
                case .failed: self.failStart()
                default: break
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                startTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(10))
                    if !Task.isCancelled { self?.failStart() }
                }
                listener.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.generation == generation { self?.stop() }
            }
        }
    }

    func stop() {
        generation = nil
        startTimeout?.cancel(); startTimeout = nil
        let continuation = ready; ready = nil
        continuation?.resume(throwing: ExternalOAuthFailure.cancelled)
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        policy = nil; onCallback = nil
    }

    private func failStart() {
        let callback = ready == nil ? onCallback : nil
        let continuation = ready; ready = nil
        continuation?.resume(throwing: ExternalOAuthFailure.pluginUnavailable)
        stop()
        callback?(.failure(.pluginUnavailable))
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        read(connection, id: id, bytes: Data())
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if let connection = self?.connections.removeValue(forKey: id) { connection.cancel() }
        }
    }

    private func read(_ connection: NWConnection, id: UUID, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384 - bytes.count) {
            [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var received = bytes
                if let data { received.append(data) }
                if received.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.answer(connection, id: id, bytes: received)
                } else if complete || error != nil || received.count >= 16_384 {
                    self.connections.removeValue(forKey: id)?.cancel()
                } else { self.read(connection, id: id, bytes: received) }
            }
        }
    }

    private func answer(_ connection: NWConnection, id: UUID, bytes: Data) {
        var result: Result<URL, ExternalOAuthFailure>?
        if !delivered, let redirect, let policy,
           let text = String(data: bytes, encoding: .utf8),
           let line = text.components(separatedBy: "\r\n").first {
            let fields = line.split(separator: " ", omittingEmptySubsequences: false)
            let hosts = text.components(separatedBy: "\r\n").dropFirst().compactMap { header -> String? in
                guard let colon = header.firstIndex(of: ":"), header[..<colon].lowercased() == "host" else { return nil }
                return header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            if fields.count == 3, fields[0] == "GET", fields[2] == "HTTP/1.1",
               hosts == ["127.0.0.1:\(redirect.port ?? 0)"],
               fields[1].hasPrefix("/?"), let url = URL(string: String(fields[1]), relativeTo: redirect)?.absoluteURL {
                do { try policy.validate(callback: url); result = .success(url) }
                catch ExternalOAuthFailure.denied { result = .failure(.denied) }
                catch { /* An unrelated request must not consume the real callback. */ }
            }
        }
        let success = result != nil
        let body = success ? "Authorization received. You can return to Floe." : "Invalid authorization callback."
        let status = success ? "200 OK" : "400 Bad Request"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        if let result { delivered = true; onCallback?(result) }
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor in self?.connections.removeValue(forKey: id) }
        })
    }
}
#endif
