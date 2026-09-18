// SPDX-License-Identifier: MPL-2.0
#if canImport(Network)
import Foundation
import Network
import FloeCore

final class LocalPreviewServer: @unchecked Sendable {
    struct Session: Sendable {
        let root: URL
        let entry: String
        let url: URL
    }

    /// Strict ceiling on the request header block. The preview endpoints only
    /// serve GET/HEAD and never read a body, so a request that needs more than
    /// this before `\r\n\r\n` is rejected without being parsed.
    private static let maximumHeaderBytes = 64 * 1024
    private static let receiveChunkBytes = 16 * 1024
    private static let headerTerminator = Data("\r\n\r\n".utf8)
    /// A peer that opens a connection and never finishes its headers must not
    /// be able to hold the socket (and its partial buffer) indefinitely.
    private static let headerTimeout: TimeInterval = 5

    private let listener: NWListener
    private let root: URL
    private let token: String
    private let queue = DispatchQueue(label: "org.floeagent.preview")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    /// Connections still waiting for a complete header block. `ObjectIdentifier`
    /// lets the timeout notice that a connection has already been answered and
    /// become a no-op instead of cancelling a slow response mid-send.
    private var receiving: Set<ObjectIdentifier> = []

    private init(listener: NWListener, root: URL, token: String) {
        self.listener = listener
        self.root = root
        self.token = token
    }

    static func start(root: URL, entry: String?) async throws -> (LocalPreviewServer, Session) {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw FloeError.notFound("Preview root is not a directory")
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let server = LocalPreviewServer(listener: listener, root: canonicalRoot, token: token)
        listener.newConnectionHandler = { [weak server] connection in server?.accept(connection) }
        // Resolve the entry before starting the listener: a missing entry must
        // not leak a running listener/port.
        let selectedEntry = try server.resolveEntry(entry)
        do {
            try await server.begin()
        } catch {
            server.stop()
            throw error
        }
        guard let port = listener.port?.rawValue else {
            server.stop()
            throw FloeError.internalError("Preview listener did not receive a port")
        }
        let url = URL(string: "http://127.0.0.1:\(port)/\(token)/\(selectedEntry)")!
        BrowserURLPolicy.authorizePreview(url)
        return (server, Session(root: canonicalRoot, entry: selectedEntry, url: url))
    }

    func stop() {
        listener.cancel()
        let snapshot = lock.withLock { () -> [NWConnection] in
            defer {
                connections.removeAll()
                receiving.removeAll()
            }
            return connections
        }
        snapshot.forEach { $0.cancel() }
        if let port = listener.port?.rawValue,
           let url = URL(string: "http://127.0.0.1:\(port)/\(token)/") {
            BrowserURLPolicy.revokePreview(url)
        }
    }

    private func begin() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = PreviewContinuationGate()
            listener.stateUpdateHandler = { state in
                let claim = gate.claim(for: state)
                guard claim else { return }
                switch state {
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: error)
                default: continuation.resume(throwing: CancellationError())
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock {
            connections.append(connection)
            receiving.insert(ObjectIdentifier(connection))
        }
        connection.start(queue: queue)
        // Bound the wait for a complete header block. A stalled peer is
        // cancelled (and its partial buffer released) instead of holding a
        // connection slot forever. The same serial queue owns both the receive
        // callbacks and this deadline, so they cannot run concurrently.
        queue.asyncAfter(deadline: DispatchTime.now() + Self.headerTimeout) { [weak self, weak connection] in
            guard let self, let connection else { return }
            let stillReceiving = self.lock.withLock {
                self.receiving.remove(ObjectIdentifier(connection)) != nil
            }
            guard stillReceiving else { return }
            self.respond(connection, response: self.http(status: "408 Request Timeout", body: Data()))
        }
        receiveRequest(connection, buffer: Data())
    }

    /// Reads until the request headers are complete instead of acting on the
    /// first TCP segment. A fragmented request line used to be parsed as a bogus
    /// path (and answered 405/404), which on a cold WebKit load could drop a
    /// module script and leave the page without its bridge function.
    ///
    /// The accumulated buffer is bounded on every pass and the header block is
    /// only parsed once `\r\n\r\n` has actually arrived; EOF or a socket error
    /// before that terminator is rejected rather than parsed as a partial line.
    private func receiveRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.receiveChunkBytes) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            // A connection already answered (or cancelled by the deadline or by
            // `stop()`) must not produce a second response.
            guard self.lock.withLock({ self.receiving.contains(ObjectIdentifier(connection)) }) else { return }
            var request = buffer
            if let data { request.append(data) }

            if let terminator = request.range(of: Self.headerTerminator) {
                guard terminator.upperBound <= Self.maximumHeaderBytes else {
                    self.respond(connection, response: self.http(status: "431 Request Header Fields Too Large", body: Data()))
                    return
                }
                // Parse only the header block. GET/HEAD carry no body, so any
                // trailing bytes are discarded.
                self.respond(connection, response: self.response(for: Data(request[..<terminator.lowerBound])))
                return
            }

            // No terminator yet: enforce the strict ceiling before recursing so
            // an oversized partial request is never parsed as if complete.
            guard request.count <= Self.maximumHeaderBytes else {
                self.respond(connection, response: self.http(status: "431 Request Header Fields Too Large", body: Data()))
                return
            }
            // EOF or a socket error before the header block completed is an
            // invalid request; never parse the partial bytes.
            guard !isComplete, error == nil else {
                self.respond(connection, response: self.http(status: "400 Bad Request", body: Data()))
                return
            }
            self.receiveRequest(connection, buffer: request)
        }
    }

    /// Sends one response and retires the connection. Removing it from the
    /// header-deadline monitor first keeps a slow client from being cancelled
    /// mid-response; the send completion then drops it from `connections`.
    private func respond(_ connection: NWConnection, response: Data) {
        lock.withLock { _ = receiving.remove(ObjectIdentifier(connection)) }
        connection.send(content: response, completion: .contentProcessed { [weak self, weak connection] _ in
            guard let self, let connection else { return }
            connection.cancel()
            self.lock.withLock { self.connections.removeAll { $0 === connection } }
        })
    }

    private func response(for request: Data) -> Data {
        guard let text = String(data: request, encoding: .utf8),
              let firstLine = text.split(separator: "\r\n", maxSplits: 1).first else {
            return http(status: "400 Bad Request", body: Data())
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET" || parts[0] == "HEAD" else {
            return http(status: "405 Method Not Allowed", body: Data())
        }
        let rawPath = String(parts[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        guard let decoded = rawPath.removingPercentEncoding else {
            return http(status: "400 Bad Request", body: Data())
        }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.first == token else {
            return http(status: "404 Not Found", body: Data())
        }
        let relative = components.dropFirst().joined(separator: "/")
        guard !relative.isEmpty,
              !relative.split(separator: "/").contains(".."),
              !relative.contains("\\") else {
            return http(status: "404 Not Found", body: Data())
        }
        let candidate = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPrefix),
              let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue <= 20 * 1024 * 1024,
              let data = try? Data(floeContentsOf: candidate, options: [.mappedIfSafe]) else {
            return http(status: "404 Not Found", body: Data())
        }
        return http(
            status: "200 OK",
            mime: Self.mimeType(for: candidate.pathExtension),
            body: parts[0] == "HEAD" ? Data() : data,
            declaredLength: data.count
        )
    }

    private func http(
        status: String,
        mime: String = "text/plain; charset=utf-8",
        body: Data,
        declaredLength: Int? = nil
    ) -> Data {
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(declaredLength ?? body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        return response
    }

    private func resolveEntry(_ requested: String?) throws -> String {
        let candidates = [requested, "index.html", "index.htm", "public/index.html", "dist/index.html", "build/index.html"]
            .compactMap { $0 }
        for candidate in candidates {
            guard !candidate.isEmpty,
                  !candidate.split(separator: "/").contains(".."),
                  !candidate.hasPrefix("/") else { continue }
            let url = root.appendingPathComponent(candidate).standardizedFileURL.resolvingSymlinksInPath()
            let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            var isDirectory: ObjCBool = false
            if url.path.hasPrefix(rootPrefix),
               FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return candidate
            }
        }
        // Convenience for the common flat-site case: serve the only HTML file
        // instead of failing with an opaque error.
        if let listing = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            let htmls = listing
                .filter { ["html", "htm"].contains(($0 as NSString).pathExtension.lowercased()) }
                .sorted()
            if htmls.count == 1, let only = htmls.first {
                return only
            }
            if !htmls.isEmpty {
                throw FloeError.notFound(
                    "No preview entry file was found in '\(root.lastPathComponent)' (served root: \(root.path)); pass entry explicitly. HTML candidates: \(htmls.prefix(12).joined(separator: ", "))"
                )
            }
        }
        throw FloeError.notFound(
            "No preview entry file was found in '\(root.lastPathComponent)' (served root: \(root.path)); create an index.html or pass entry. The entry is relative to the served directory."
        )
    }

    private static func mimeType(for extensionName: String) -> String {
        switch extensionName.lowercased() {
        case "html", "htm": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "json", "map": "application/json; charset=utf-8"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        case "ttf": "font/ttf"
        case "wasm": "application/wasm"
        default: "application/octet-stream"
        }
    }
}

private final class PreviewContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func claim(for state: NWListener.State) -> Bool {
        lock.withLock {
            guard !resumed else { return false }
            switch state {
            case .ready, .failed, .cancelled:
                resumed = true
                return true
            default:
                return false
            }
        }
    }
}

#endif
