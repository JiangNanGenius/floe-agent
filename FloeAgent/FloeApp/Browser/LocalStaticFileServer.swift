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

    private let listener: NWListener
    private let root: URL
    private let token: String
    private let queue = DispatchQueue(label: "org.floeagent.preview")
    private let lock = NSLock()
    private var connections: [NWConnection] = []

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
            defer { connections.removeAll() }
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
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self, weak connection] data, _, _, _ in
            guard let self, let connection else { return }
            let response = self.response(for: data ?? Data())
            connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                connection.cancel()
                self?.lock.withLock { self?.connections.removeAll { $0 === connection } }
            })
        }
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
