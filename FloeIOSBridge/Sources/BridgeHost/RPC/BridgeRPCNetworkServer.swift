import Darwin
import Foundation

import BridgeCore

public enum BridgeRPCNetworkError: Error, Equatable, Sendable {
    case invalidPort
    case alreadyRunning
    case notRunning
    case bind(String)
    case listen(String)
    case lanUnavailable(String)

    public var message: String {
        switch self {
        case .invalidPort: return "The Bridge port is invalid."
        case .alreadyRunning: return "The Bridge server is already running."
        case .notRunning: return "The Bridge server is not running."
        case .bind(let detail): return "The Bridge listener could not bind: \(detail)"
        case .listen(let detail): return "The Bridge listener could not listen: \(detail)"
        case .lanUnavailable(let detail): return "The optional LAN listener is unavailable: \(detail)"
        }
    }
}

public struct BridgeRPCNetworkState: Sendable, Equatable {
    public var running: Bool
    public var loopbackIPv4Ready: Bool
    public var loopbackIPv6Ready: Bool
    public var lanIPv4Ready: Bool
    public var lanIPv6Ready: Bool
    public var lanEnabled: Bool
    public var bonjourState: String
    public var port: UInt16?
    public var lastError: String?

    public init(running: Bool = false,
                loopbackIPv4Ready: Bool = false,
                loopbackIPv6Ready: Bool = false,
                lanIPv4Ready: Bool = false,
                lanIPv6Ready: Bool = false,
                lanEnabled: Bool = false,
                bonjourState: String = "off",
                port: UInt16? = nil,
                lastError: String? = nil) {
        self.running = running
        self.loopbackIPv4Ready = loopbackIPv4Ready
        self.loopbackIPv6Ready = loopbackIPv6Ready
        self.lanIPv4Ready = lanIPv4Ready
        self.lanIPv6Ready = lanIPv6Ready
        self.lanEnabled = lanEnabled
        self.bonjourState = bonjourState
        self.port = port
        self.lastError = lastError
    }

    public var loopbackReady: Bool {
        running && loopbackIPv4Ready && loopbackIPv6Ready
    }
}

/// Localhost-first HTTP server for the Bridge RPC service.
///
/// Two loopback listeners are mandatory: 127.0.0.1 and ::1 on the same port.
/// The optional LAN mode adds normal-interface listeners on that same port and
/// Bonjour advertisement; it never includes AWDL/peer-to-peer or cellular.
/// Every listener shares one `BridgeRPCService` and therefore one authority,
/// engine registry, execution queue and stream registry.
public final class BridgeRPCNetworkServer: @unchecked Sendable {
    private enum ListenerKind: String {
        case loopbackIPv4
        case loopbackIPv6
        case lanIPv4
        case lanIPv6

        var isLAN: Bool { self == .lanIPv4 || self == .lanIPv6 }
    }

    private final class Listener: @unchecked Sendable {
        let fd: Int32
        let kind: ListenerKind
        var source: DispatchSourceRead?
        var closed = false

        init(fd: Int32, kind: ListenerKind) {
            self.fd = fd
            self.kind = kind
        }
    }

    private final class Connection: @unchecked Sendable {
        let id = UUID()
        private var fd: Int32
        let kind: ListenerKind
        let peer: BridgeRPCPeerInfo
        let queue: DispatchQueue
        let server: BridgeRPCNetworkServer
        private let lock = BridgeRPCLock()
        private var source: DispatchSourceRead?
        private var closed = false
        private var handled = false
        private var buffer = Data()
        private var timeout: DispatchWorkItem?
        private var clientID: String?
        private var streamCancel: (@Sendable () -> Void)?

        init(fd: Int32,
             kind: ListenerKind,
             peer: BridgeRPCPeerInfo,
             server: BridgeRPCNetworkServer) {
            self.fd = fd
            self.kind = kind
            self.peer = peer
            self.server = server
            self.queue = DispatchQueue(label: "org.floeagent.iosbridge.rpc.connection.\(id.uuidString)")
        }

        func start() {
            queue.async { [self] in
                lock.lock()
                if closed {
                    // close() already released the descriptor.
                    lock.unlock()
                    return
                }
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler { [weak self] in self?.readAvailable() }
                self.source = source
                let timeout = DispatchWorkItem { [weak self] in
                    self?.close()
                }
                self.timeout = timeout
                lock.unlock()
                source.resume()
                DispatchQueue.global(qos: .userInitiated)
                    .asyncAfter(deadline: .now() + server.readTimeout, execute: timeout)
            }
        }

        private func readAvailable() {
            lock.lock()
            if closed || handled {
                lock.unlock()
                return
            }
            lock.unlock()

            var peerClosed = false
            var readError = false
            while true {
                var bytes = [UInt8](repeating: 0, count: 16_384)
                lock.lock()
                guard !closed, fd >= 0 else {
                    lock.unlock()
                    return
                }
                let count = recv(fd, &bytes, bytes.count, 0)
                lock.unlock()
                if count > 0 {
                    lock.lock()
                    buffer.append(contentsOf: bytes[0..<count])
                    let size = buffer.count
                    lock.unlock()
                    if size > server.maximumRequestBytes {
                        sendRPCError(status: 413, code: "request_body_too_large",
                                     message: "The request exceeds the bounded size.")
                        return
                    }
                    continue
                }
                if count == 0 { peerClosed = true; break }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                readError = true
                break
            }
            if readError {
                close()
                return
            }

            lock.lock()
            let snapshot = buffer
            lock.unlock()
            switch BridgeRPCHTTPParser.inspect(snapshot, limits: server.limits) {
            case .incomplete:
                if peerClosed { close() }
                return
            case .invalid(let status, let code, let message):
                server.log("rpc_parse_invalid status=\(status) code=\(code)")
                sendRPCError(status: status, code: code, message: message)
            case .complete(let parsed):
                lock.lock()
                guard !handled else { lock.unlock(); return }
                handled = true
                source?.cancel()
                timeout?.cancel()
                lock.unlock()
                let request = parsed.serviceRequest
                Task { [weak self] in
                    guard let self else { return }
                    let result = await self.server.service.handle(request, peer: self.peer)
                    if case .response(let response) = result {
                        self.server.log("rpc_response status=\(response.status) path=\(request.pathOnly)")
                    } else {
                        self.server.log("rpc_stream_open")
                    }
                    self.write(result)
                }
            }
        }

        private func sendRPCError(status: Int, code: String, message: String) {
            let response = BridgeRPCHTTPResponse.error(status, code: code, message: message)
            write(.response(response))
        }

        func write(_ result: BridgeRPCHTTPResult) {
            lock.lock()
            let alreadyClosed = closed
            lock.unlock()
            if alreadyClosed { return }
            switch result {
            case .response(let response):
                let body = response.body
                var headers = response.headers
                headers["Content-Length"] = String(body.count)
                headers["Connection"] = "close"
                headers["X-Content-Type-Options"] = "nosniff"
                guard let head = Self.responseHead(status: response.status, headers: headers) else {
                    close()
                    return
                }
                if let token = response.commitToken {
                    setClientID(token.clientID)
                    server.beforeCommitHandler()?()
                    guard commitFirstByte(of: head, token: token) else {
                        close()
                        return
                    }
                    server.afterFirstByteHandler()?()
                    let rest = Data(head.dropFirst())
                    if writeAll(rest) && writeAll(body) {
                        close()
                    } else {
                        close()
                    }
                } else if writeAll(head) && writeAll(body) {
                    close()
                } else {
                    close()
                }
            case .stream(let grant):
                var headers: [String: String] = [
                    "Content-Type": grant.contentType,
                    "Transfer-Encoding": "chunked",
                    "Cache-Control": "no-store",
                    "Connection": "close",
                    "X-Content-Type-Options": "nosniff",
                ]
                headers["X-Bridge-Stream"] = "1"
                guard let head = Self.responseHead(status: 200, headers: headers) else {
                    grant.cancel()
                    close()
                    return
                }
                setClientID(grant.clientID)
                lock.lock()
                streamCancel = grant.cancel
                lock.unlock()
                server.beforeCommitHandler()?()
                guard commitFirstByte(of: head, token: grant.commitToken) else {
                    grant.cancel()
                    close()
                    return
                }
                server.afterFirstByteHandler()?()
                guard writeAll(Data(head.dropFirst())) else {
                    grant.cancel()
                    close()
                    return
                }
                Task { [weak self] in
                    guard let self else { return }
                    for await chunk in grant.sequence {
                        if Task.isCancelled { break }
                        if !self.writeChunk(chunk) { break }
                    }
                    _ = self.writeAll(Data("0\r\n\r\n".utf8))
                    grant.cancel()
                    self.close()
                }
            }
        }

        private func setClientID(_ value: String?) {
            guard let value else { return }
            lock.lock()
            clientID = value
            lock.unlock()
        }

        private func commitFirstByte(of head: Data, token: BridgeRPCCommitToken) -> Bool {
            guard let first = head.first else { return false }
            return server.service.commitResponse(token) { [self] in
                lock.lock()
                defer { lock.unlock() }
                guard !closed, fd >= 0 else { return false }
                var byte = first
                let sent = send(fd, &byte, 1, 0)
                return sent == 1
            }
        }

        func closeIfClient(_ value: String) {
            lock.lock()
            let matches = clientID == value
            lock.unlock()
            if matches { close() }
        }

        private func writeChunk(_ data: Data) -> Bool {
            guard !data.isEmpty else { return true }
            var framed = Data()
            framed.append(Data(String(data.count, radix: 16).utf8))
            framed.append(Data("\r\n".utf8))
            framed.append(data)
            framed.append(Data("\r\n".utf8))
            return writeAll(framed)
        }

        private func writeAll(_ data: Data) -> Bool {
            var offset = 0
            let deadline = Date().addingTimeInterval(server.writeTimeout)
            return data.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return true }
                while offset < raw.count {
                    if Date() > deadline { return false }
                    lock.lock()
                    guard !closed, fd >= 0 else {
                        lock.unlock()
                        return false
                    }
                    let pollFD = fd
                    let sent = send(fd, base.advanced(by: offset), raw.count - offset, 0)
                    lock.unlock()
                    if sent > 0 {
                        offset += sent
                        continue
                    }
                    if sent < 0 && errno == EINTR { continue }
                    if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                        var descriptor = pollfd(fd: pollFD, events: Int16(POLLOUT), revents: 0)
                        let ready = poll(&descriptor, 1, 100)
                        if ready < 0 && errno != EINTR { return false }
                        continue
                    }
                    return false
                }
                return true
            }
        }

        func close() {
            lock.lock()
            if closed {
                lock.unlock()
                return
            }
            closed = true
            let currentFD = fd
            fd = -1
            let source = self.source
            let timeout = self.timeout
            let streamCancel = self.streamCancel
            self.source = nil
            self.timeout = nil
            self.streamCancel = nil
            lock.unlock()
            timeout?.cancel()
            source?.cancel()
            streamCancel?()
            if currentFD >= 0 {
                shutdown(currentFD, SHUT_RDWR)
                Darwin.close(currentFD)
            }
            server.remove(connection: self)
        }

        private static func responseHead(status: Int, headers: [String: String]) -> Data? {
            var text = "HTTP/1.1 \(status) \(reason(status))\r\n"
            for key in headers.keys.sorted() {
                guard let value = headers[key] else { continue }
                guard !key.contains("\r"), !key.contains("\n"),
                      !value.contains("\r"), !value.contains("\n") else {
                    return nil
                }
                text += "\(key): \(value)\r\n"
            }
            text += "\r\n"
            return Data(text.utf8)
        }

        private static func reason(_ status: Int) -> String {
            switch status {
            case 200: return "OK"
            case 204: return "No Content"
            case 400: return "Bad Request"
            case 401: return "Unauthorized"
            case 403: return "Forbidden"
            case 404: return "Not Found"
            case 405: return "Method Not Allowed"
            case 413: return "Payload Too Large"
            case 429: return "Too Many Requests"
            case 431: return "Request Header Fields Too Large"
            case 500: return "Internal Server Error"
            case 503: return "Service Unavailable"
            default: return "Response"
            }
        }
    }

    private let service: BridgeRPCService
    private let limits: BridgeRPCLimits
    private let stateQueue = DispatchQueue(label: "org.floeagent.iosbridge.rpc.accept")
    private let lock = BridgeRPCLock()

    private var listeners: [Listener] = []
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var running = false
    private var port: UInt16?
    private var lanEnabled = false
    private var lanIPv4Ready = false
    private var lanIPv6Ready = false
    private var lastError: String?
    private var bonjour: BridgeRPCBonjourPublisher?
    private var bonjourState = "off"
    private var stateHandler: (@Sendable (BridgeRPCNetworkState) -> Void)?
    private var logHandler: (@Sendable (String) -> Void)?
    private var beforeResponseCommit: (@Sendable () -> Void)?
    private var afterFirstByteCommit: (@Sendable () -> Void)?

    private var readTimeout: TimeInterval { limits.requestReadTimeout }
    private var writeTimeout: TimeInterval { limits.responseWriteTimeout }
    private var maximumRequestBytes: Int { limits.maxRequestHeadBytes + limits.maxRequestBodyBytes + 4 }

    public init(service: BridgeRPCService, limits: BridgeRPCLimits = .default) {
        self.service = service
        self.limits = limits
        service.setClientRevocationHandler { [weak self] clientID in
            self?.closeConnections(for: clientID)
        }
        service.setAllConnectionsRevokedHandler { [weak self] in
            self?.closeConnectionsForRevocation()
        }
    }

    public func setStateHandler(_ handler: (@Sendable (BridgeRPCNetworkState) -> Void)?) {
        lock.lock()
        stateHandler = handler
        lock.unlock()
    }

    /// Redacted transport events only: peer class, listener kind, parser code
    /// and HTTP status. Request bodies, headers and arguments never enter this
    /// sink.
    public func setLogHandler(_ handler: (@Sendable (String) -> Void)?) {
        lock.lock()
        logHandler = handler
        lock.unlock()
    }

    func log(_ message: String) {
        lock.lock()
        let handler = logHandler
        lock.unlock()
        handler?(message)
    }

    /// Narrow deterministic test seams. Production leaves them nil; they are
    /// not remotely settable and cannot change authorization decisions.
    public func setBeforeResponseCommitHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        beforeResponseCommit = handler
        lock.unlock()
    }

    public func setAfterFirstByteCommitHandler(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        afterFirstByteCommit = handler
        lock.unlock()
    }

    func beforeCommitHandler() -> (@Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return beforeResponseCommit
    }

    func afterFirstByteHandler() -> (@Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return afterFirstByteCommit
    }

    public var snapshot: BridgeRPCNetworkState {
        lock.lock()
        defer { lock.unlock() }
        return BridgeRPCNetworkState(
            running: running,
            loopbackIPv4Ready: listeners.contains { $0.kind == .loopbackIPv4 },
            loopbackIPv6Ready: listeners.contains { $0.kind == .loopbackIPv6 },
            lanIPv4Ready: lanIPv4Ready,
            lanIPv6Ready: lanIPv6Ready,
            lanEnabled: lanEnabled,
            bonjourState: bonjourState,
            port: port,
            lastError: lastError
        )
    }

    public func start(requestedPort: UInt16 = 8200) throws {
        // Port 0 is accepted for isolated tests and resolves to an ephemeral
        // port; the product always passes its configured 8200.
        lock.lock()
        guard !running else {
            lock.unlock()
            throw BridgeRPCNetworkError.alreadyRunning
        }
        lock.unlock()

        var created: [Listener] = []
        do {
            let first = try Self.makeListenerIPv4(loopback: true, port: requestedPort)
            created.append(first)
            let actualPort = Self.boundPort(first.fd) ?? requestedPort
            let second = try Self.makeListenerIPv6(loopback: true, port: actualPort)
            created.append(second)

            lock.lock()
            listeners = created
            running = true
            port = actualPort
            lastError = nil
            lanEnabled = false
            lanIPv4Ready = false
            lanIPv6Ready = false
            lock.unlock()

            service.setActualPort(actualPort)
            service.beginServing()
            service.setNetworkState(lanEnabled: false, lanReady: false, bonjourState: "off")
            for listener in created { startAcceptSource(listener) }
            notify()
        } catch {
            for listener in created { closeListener(listener) }
            let message = (error as? BridgeRPCNetworkError)?.message ?? String(describing: error)
            lock.lock()
            running = false
            lastError = message
            lock.unlock()
            notify()
            throw error
        }
    }

    /// Enables the optional normal-LAN listeners (IPv4 and IPv6 wildcard) on
    /// the same port and starts Bonjour. Failure leaves loopback running and
    /// reports a concrete LAN error rather than pretending LAN is ready.
    public func setLANEnabled(_ enabled: Bool, bonjour: Bool) throws {
        lock.lock()
        guard running, let port else {
            lock.unlock()
            throw BridgeRPCNetworkError.notRunning
        }
        let already = lanEnabled
        lock.unlock()
        if !enabled {
            stopLAN()
            return
        }
        if already {
            if bonjour {
                startBonjour(port: port)
            } else {
                lock.lock()
                let publisher = self.bonjour
                self.bonjour = nil
                bonjourState = "off"
                lock.unlock()
                publisher?.stop()
                service.setBonjourState("off")
                notify()
            }
            return
        }

        var created: [Listener] = []
        var errors: [String] = []
        do {
            let v4 = try Self.makeListenerIPv4(loopback: false, port: port)
            created.append(v4)
        } catch {
            errors.append((error as? BridgeRPCNetworkError)?.message ?? String(describing: error))
        }
        do {
            let v6 = try Self.makeListenerIPv6(loopback: false, port: port)
            created.append(v6)
        } catch {
            errors.append((error as? BridgeRPCNetworkError)?.message ?? String(describing: error))
        }

        guard !created.isEmpty else {
            for listener in created { closeListener(listener) }
            let message = errors.joined(separator: " ")
            lock.lock()
            lastError = message
            lanEnabled = false
            lanIPv4Ready = false
            lanIPv6Ready = false
            lock.unlock()
            notify()
            throw BridgeRPCNetworkError.lanUnavailable(message)
        }

        lock.lock()
        listeners.append(contentsOf: created)
        lanEnabled = true
        lanIPv4Ready = created.contains { $0.kind == .lanIPv4 }
        lanIPv6Ready = created.contains { $0.kind == .lanIPv6 }
        lastError = errors.isEmpty ? nil : errors.joined(separator: " ")
        lock.unlock()
        for listener in created { startAcceptSource(listener) }
        service.setNetworkState(lanEnabled: true,
                                lanReady: !created.isEmpty,
                                bonjourState: bonjour ? "starting" : "off")
        if bonjour { startBonjour(port: port) }
        notify()
    }

    public func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        let currentListeners = listeners
        let currentConnections = Array(connections.values)
        listeners.removeAll()
        connections.removeAll()
        lanEnabled = false
        lanIPv4Ready = false
        lanIPv6Ready = false
        port = nil
        let bonjour = self.bonjour
        self.bonjour = nil
        bonjourState = "off"
        lock.unlock()

        bonjour?.stop()
        for listener in currentListeners { closeListener(listener) }
        for connection in currentConnections { connection.close() }
        service.endServing()
        service.setNetworkState(lanEnabled: false, lanReady: false, bonjourState: "off")
        notify()
    }

    private func stopLAN() {
        lock.lock()
        let lanListeners = listeners.filter { $0.kind.isLAN }
        listeners.removeAll { $0.kind.isLAN }
        let lanConnections = connections.values.filter { $0.kind.isLAN }
        for connection in lanConnections {
            connections.removeValue(forKey: ObjectIdentifier(connection))
        }
        lanEnabled = false
        lanIPv4Ready = false
        lanIPv6Ready = false
        let publisher = bonjour
        bonjour = nil
        bonjourState = "off"
        lock.unlock()
        publisher?.stop()
        for listener in lanListeners { closeListener(listener) }
        for connection in lanConnections { connection.close() }
        service.setNetworkState(lanEnabled: false, lanReady: false, bonjourState: "off")
        notify()
    }

    private func startBonjour(port: UInt16) {
        lock.lock()
        let existing = bonjour
        lock.unlock()
        existing?.stop()
        let publisher = BridgeRPCBonjourPublisher { [weak self] state in
            guard let self else { return }
            self.lock.lock()
            self.bonjourState = state
            self.lock.unlock()
            self.service.setBonjourState(state)
            self.notify()
        }
        publisher.start(name: "Floe iOS Bridge", port: Int32(port))
        lock.lock()
        bonjour = publisher
        bonjourState = "starting"
        lock.unlock()
        service.setBonjourState("starting")
        notify()
    }

    private func startAcceptSource(_ listener: Listener) {
        lock.lock()
        guard !listener.closed else {
            lock.unlock()
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: listener.fd, queue: stateQueue)
        source.setEventHandler { [weak self] in
            self?.accept(on: listener)
        }
        listener.source = source
        lock.unlock()
        source.resume()
    }

    private func accept(on listener: Listener) {
        while true {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            lock.lock()
            guard running, !listener.closed else {
                lock.unlock()
                return
            }
            let acceptedFD = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    Darwin.accept(listener.fd, address, &length)
                }
            }
            lock.unlock()
            let fd = acceptedFD
            if fd < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                log("rpc_accept_error kind=\(listener.kind.rawValue) errno=\(errno)")
                return
            }

            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                       socklen_t(MemoryLayout<Int32>.size))
            var noDelay: Int32 = 1
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay,
                       socklen_t(MemoryLayout<Int32>.size))
            var flags = fcntl(fd, F_GETFL, 0)
            if flags >= 0 {
                flags |= O_NONBLOCK
                _ = fcntl(fd, F_SETFL, flags)
            }

            let peer = BridgeRPCNetworkPeer.classify(storage)
            guard peer.isAcceptedTransport else {
                log("rpc_accept_rejected via=\(peer.via.rawValue) loopback=\(peer.isLoopback)")
                shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
                continue
            }
            log("rpc_accept kind=\(listener.kind.rawValue) via=\(peer.via.rawValue) loopback=\(peer.isLoopback)")
            if listener.kind.isLAN && peer.via == .local && !peer.isLoopback {
                // A mapped/ambiguous address is not normal LAN. Refuse rather
                // than guess.
                shutdown(fd, SHUT_RDWR)
                close(fd)
                continue
            }

            lock.lock()
            let stillOpen = running && !listener.closed
                && (!listener.kind.isLAN || lanEnabled)
            let atCapacity = connections.count >= limits.maxConnections || !stillOpen
            if !atCapacity {
                let connection = Connection(fd: fd, kind: listener.kind, peer: peer, server: self)
                connections[ObjectIdentifier(connection)] = connection
                lock.unlock()
                connection.start()
            } else {
                lock.unlock()
                shutdown(fd, SHUT_RDWR)
                close(fd)
            }
        }
    }

    private func remove(connection: Connection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    private func closeConnections(for clientID: String) {
        lock.lock()
        let targets = Array(connections.values)
        lock.unlock()
        for connection in targets { connection.closeIfClient(clientID) }
    }

    private func closeConnectionsForRevocation() {
        lock.lock()
        let targets = Array(connections.values)
        lock.unlock()
        for connection in targets { connection.close() }
    }

    private func closeListener(_ listener: Listener) {
        lock.lock()
        if listener.closed {
            lock.unlock()
            return
        }
        listener.closed = true
        lock.unlock()
        listener.source?.cancel()
        // Close synchronously so a stopped ephemeral port is released before a
        // subsequent test/server start can bind the same number. The cancel
        // handler is intentionally empty; double-close is worse than an extra
        // EBADF from a queued accept event.
        Darwin.close(listener.fd)
    }

    private func notify() {
        lock.lock()
        let handler = stateHandler
        let state = BridgeRPCNetworkState(
            running: running,
            loopbackIPv4Ready: listeners.contains { $0.kind == .loopbackIPv4 },
            loopbackIPv6Ready: listeners.contains { $0.kind == .loopbackIPv6 },
            lanIPv4Ready: lanIPv4Ready,
            lanIPv6Ready: lanIPv6Ready,
            lanEnabled: lanEnabled,
            bonjourState: bonjourState,
            port: port,
            lastError: lastError
        )
        lock.unlock()
        handler?(state)
    }

    // MARK: - Socket construction

    private static func makeListenerIPv4(loopback: Bool, port: UInt16) throws -> Listener {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw BridgeRPCNetworkError.bind(errnoText())
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        let host = loopback ? "127.0.0.1" : "0.0.0.0"
        withUnsafeMutablePointer(to: &address.sin_addr) { pointer in
            _ = inet_pton(AF_INET, host, pointer)
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let detail = errnoText()
            close(fd)
            throw BridgeRPCNetworkError.bind(detail)
        }
        guard listen(fd, 16) == 0 else {
            let detail = errnoText()
            close(fd)
            throw BridgeRPCNetworkError.listen(detail)
        }
        setNonBlocking(fd)
        return Listener(fd: fd, kind: loopback ? .loopbackIPv4 : .lanIPv4)
    }

    private static func makeListenerIPv6(loopback: Bool, port: UInt16) throws -> Listener {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw BridgeRPCNetworkError.bind(errnoText())
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var v6Only: Int32 = 1
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6Only, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        if loopback {
            address.sin6_addr = in6addr_loopback
        } else {
            address.sin6_addr = in6_addr()
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bindResult == 0 else {
            let detail = errnoText()
            close(fd)
            throw BridgeRPCNetworkError.bind(detail)
        }
        guard listen(fd, 16) == 0 else {
            let detail = errnoText()
            close(fd)
            throw BridgeRPCNetworkError.listen(detail)
        }
        setNonBlocking(fd)
        return Listener(fd: fd, kind: loopback ? .loopbackIPv6 : .lanIPv6)
    }

    private static func setNonBlocking(_ fd: Int32) {
        var flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            flags |= O_NONBLOCK
            _ = fcntl(fd, F_SETFL, flags)
        }
    }

    private static func boundPort(_ fd: Int32) -> UInt16? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard result == 0 else { return nil }
        if storage.ss_family == sa_family_t(AF_INET) {
            return withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt16(bigEndian: $0.pointee.sin_port)
                }
            }
        }
        if storage.ss_family == sa_family_t(AF_INET6) {
            return withUnsafePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    UInt16(bigEndian: $0.pointee.sin6_port)
                }
            }
        }
        return nil
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}

/// Bonjour advertisement for the optional normal-LAN listener. It deliberately
/// does not advertise over AWDL/peer-to-peer; `includesPeerToPeer = false`.
final class BridgeRPCBonjourPublisher: NSObject, NetServiceDelegate, @unchecked Sendable {
    private let lock = BridgeRPCLock()
    private var service: NetService?
    private var state: String = "off"
    private let onChange: @Sendable (String) -> Void

    init(onChange: @escaping @Sendable (String) -> Void) {
        self.onChange = onChange
        super.init()
    }

    func start(name: String, port: Int32) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let service = NetService(domain: "local.", type: "_floe-ios-bridge._tcp.", name: name, port: port)
            service.delegate = self
            service.includesPeerToPeer = false
            let txt: [String: Data] = [
                "proto": Data("1".utf8),
                "version": Data(BridgeRPCVersion.serverVersion.utf8),
                "path": Data("/rpc".utf8),
            ]
            service.setTXTRecord(NetService.data(fromTXTRecord: txt))
            self.lock.lock()
            self.service = service
            self.state = "starting"
            self.lock.unlock()
            self.onChange("starting")
            service.publish()
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let service = self.service
            self.service = nil
            self.state = "off"
            self.lock.unlock()
            service?.stop()
            self.onChange("off")
        }
    }

    func netServiceDidPublish(_ sender: NetService) {
        update("published")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        update("failed:\(code)")
    }

    func netServiceDidStop(_ sender: NetService) {
        update("off")
    }

    private func update(_ value: String) {
        lock.lock()
        state = value
        lock.unlock()
        onChange(value)
    }
}
