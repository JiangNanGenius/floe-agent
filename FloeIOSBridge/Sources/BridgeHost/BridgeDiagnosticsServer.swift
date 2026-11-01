import Foundation
import Network
import BridgeCore

/// Opt-in, read-only LAN diagnostics. It has no command endpoint, no file
/// access and no unauthenticated path. The bearer token is a Keychain secret
/// with constant-time comparison. This is a prototype-only surface.
final class BridgeDiagnosticsServer: @unchecked Sendable {
    static let defaultPort: UInt16 = 47654

    enum ServerError: LocalizedError {
        case invalidPort
        case alreadyRunning
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .invalidPort: return "The diagnostics port is invalid."
            case .alreadyRunning: return "The diagnostics endpoint is already running."
            case .failed(let message): return "The diagnostics endpoint failed: \(message)"
            }
        }
    }

    private let queue = DispatchQueue(label: "org.floeagent.iosbridge.diagnostics")
    private let lock = NSLock()
    private var listener: NWListener?
    private var token: String = ""
    private var statusProvider: (@Sendable () -> Data)?
    private var port: UInt16 = BridgeDiagnosticsServer.defaultPort

    private(set) var isListening = false
    var onStateChange: (@Sendable (Bool, String?) -> Void)?

    var isStarted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return listener != nil
    }

    func start(port: UInt16 = BridgeDiagnosticsServer.defaultPort,
               token: String,
               statusProvider: @escaping @Sendable () -> Data) throws {
        guard port > 0 else { throw ServerError.invalidPort }
        lock.lock()
        let already = listener != nil
        lock.unlock()
        guard !already else { throw ServerError.alreadyRunning }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw ServerError.invalidPort }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: endpointPort)
        } catch {
            throw ServerError.failed(error.localizedDescription)
        }
        self.token = token
        self.statusProvider = statusProvider
        self.port = port
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock(); self.isListening = true; self.lock.unlock()
                self.onStateChange?(true, nil)
            case .failed(let error):
                self.lock.lock(); self.isListening = false; self.lock.unlock()
                self.onStateChange?(false, error.localizedDescription)
                listener.cancel()
                self.lock.lock(); self.listener = nil; self.lock.unlock()
            case .cancelled:
                self.lock.lock(); self.isListening = false; self.lock.unlock()
                self.onStateChange?(false, nil)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        lock.lock()
        self.listener = listener
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        isListening = false
        self.statusProvider = nil
        lock.unlock()
        listener?.cancel()
    }

    func listeningURL() -> String? {
        guard let address = BridgeNetworkInfo.primaryIPv4Address() else { return nil }
        lock.lock()
        let currentPort = port
        lock.unlock()
        return "http://\(address):\(currentPort)/v1/status"
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) {
            connection.cancel()
        }
        receive(connection, accumulated: Data())
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if buffer.count > 8_192 {
                self.respond(connection, status: 413, body: ["error": "request too large"])
                return
            }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = buffer.subdata(in: 0..<range.lowerBound)
                self.handleRequest(head, connection: connection)
                return
            }
            if complete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, accumulated: buffer)
        }
    }

    private func handleRequest(_ head: Data, connection: NWConnection) {
        guard let text = String(data: head, encoding: .utf8) else {
            respond(connection, status: 400, body: ["error": "bad request"])
            return
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            respond(connection, status: 400, body: ["error": "bad request"])
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            respond(connection, status: 405, body: ["error": "GET only"])
            return
        }
        let path = String(parts[1])
        guard path == "/v1/status" || path == "/v1/health" else {
            respond(connection, status: 404, body: ["error": "not found"])
            return
        }

        var authorization: String?
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if name == "authorization" { authorization = value }
        }
        guard let authorization,
              authorization.lowercased().hasPrefix("bearer "),
              BridgeInstallToken.constantTimeEquals(String(authorization.dropFirst(7)), token) else {
            respond(connection, status: 401,
                    body: ["error": "unauthorized"],
                    extraHeaders: ["WWW-Authenticate": "Bearer"])
            return
        }

        if path == "/v1/health" {
            respond(connection, status: 200, body: ["ok": true])
            return
        }
        guard let statusProvider else {
            respond(connection, status: 503, body: ["error": "status unavailable"])
            return
        }
        let body = statusProvider()
        respondData(connection, status: 200, body: body)
    }

    private func respond(_ connection: NWConnection,
                         status: Int,
                         body: [String: Any],
                         extraHeaders: [String: String] = [:]) {
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
        respondData(connection, status: status, body: data, extraHeaders: extraHeaders)
    }

    private func respondData(_ connection: NWConnection,
                             status: Int,
                             body: Data,
                             extraHeaders: [String: String] = [:]) {
        let reason = status == 200 ? "OK" : status == 401 ? "Unauthorized" : status == 404 ? "Not Found" : "Error"
        var headers = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Connection: close",
        ]
        for (name, value) in extraHeaders { headers.append("\(name): \(value)") }
        var response = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
