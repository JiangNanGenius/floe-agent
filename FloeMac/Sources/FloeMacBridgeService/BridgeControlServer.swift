// Floe Mac M00 — authenticated local control server.
//
// SPDX-License-Identifier: MPL-2.0
//
// The socket lives in a 0700 app-owned directory, is created 0600, and only
// accepts a same-UID peer that presents the random token from the discovery
// file. The server never executes a command from the control payload: it
// forwards a validated pairing decision, revoke, status or stop request to the
// existing BridgeService. Control traffic is separate from paired-client RPC.

import Darwin
import Dispatch
import Foundation

final class BridgeControlServer: @unchecked Sendable {
    typealias Handler = @Sendable (BridgeControlMessage, UUID) async -> BridgeControlMessage

    private let socketPath: String
    private let token: String
    private var handler: Handler
    private var onAuthenticated: (@Sendable (UUID) -> Void)?
    private var onDisconnected: (@Sendable (UUID) -> Void)?
    private let lock = NSLock()
    private let lifecycleLock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var connections: [ControlConnection] = []
    #if FLOE_IPC_TESTING
    private var closedBeforeCallbackHook: (@Sendable (UUID) -> Void)?

    func setClosedBeforeCallbackHookForTesting(_ hook: (@Sendable (UUID) -> Void)?) {
        lock.withLock { closedBeforeCallbackHook = hook }
    }

    func closeConnectionForTesting(_ id: UUID) {
        let connection = lock.withLock { connections.first { $0.identity == id } }
        connection?.close()
    }

    fileprivate func didMarkClosedForTesting(_ id: UUID) {
        let hook = lock.withLock { closedBeforeCallbackHook }
        hook?(id)
    }
    #endif

    init(socketPath: String, token: String, handler: @escaping Handler) {
        self.socketPath = socketPath
        self.token = token
        self.handler = handler
    }

    func setAuthenticationHandler(_ handler: @escaping @Sendable (UUID) -> Void) {
        lock.withLock { onAuthenticated = handler }
    }

    func setDisconnectHandler(_ handler: @escaping @Sendable (UUID) -> Void) {
        lock.withLock { onDisconnected = handler }
    }

    func replaceHandler(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    // Called by the ownership authority while committing a decision. close()
    // marks the connection closed before its disconnect callback can wait on
    // another lock, so a delayed callback cannot make a dead socket live.
    func isConnectionActive(_ identity: UUID) -> Bool {
        let connection = lock.withLock { connections.first { $0.identity == identity } }
        return connection?.isAuthenticated == true
    }

    func start() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !lock.withLock({ running || listenFD >= 0 }) else {
            throw BridgeControlFailure.remote("The local control service is already running.")
        }
        let parent = URL(fileURLWithPath: socketPath, isDirectory: false).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.removeStaleSocketIfNeeded(socketPath)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BridgeControlFailure.socketUnavailable }
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                       socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            close(descriptor)
            throw BridgeControlFailure.socketPathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(descriptor)
            throw BridgeControlFailure.remote(
                "The local control socket could not be bound: \(String(cString: strerror(errno)))."
            )
        }
        let permissionsOK = socketPath.withCString { chmod($0, 0o600) } == 0
        guard permissionsOK, listen(descriptor, 8) == 0 else {
            close(descriptor)
            Self.unlinkPath(socketPath)
            throw BridgeControlFailure.socketUnavailable
        }
        lock.withLock {
            listenFD = descriptor
            running = true
        }
        // The accept thread exclusively owns the final close. stop() only
        // shuts down the socket, so its numeric fd cannot be reused while an
        // accept syscall or its next iteration still references it.
        Thread.detachNewThread { [self] in acceptLoop(descriptor: descriptor) }
    }

    func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        let current: (Int32, [ControlConnection]) = lock.withLock {
            running = false
            let current = (listenFD, connections)
            connections = []
            listenFD = -1
            if current.0 >= 0 { _ = shutdown(current.0, SHUT_RDWR) }
            return current
        }
        for connection in current.1 { connection.close() }
        if current.0 >= 0 { Self.unlinkPath(socketPath) }
    }

    func broadcast(_ event: BridgeControlEvent) {
        let message = BridgeControlMessage(kind: .event, event: event)
        guard let frame = try? BridgeControlCodec.encode(message) else { return }
        let targets = lock.withLock { connections }
        for connection in targets where connection.isAuthenticated {
            connection.send(frame)
        }
    }

    private func acceptLoop(descriptor: Int32) {
        defer {
            lock.withLock {
                if listenFD == descriptor {
                    listenFD = -1
                    running = false
                }
                Darwin.close(descriptor)
            }
        }
        while true {
            guard lock.withLock({ running && listenFD == descriptor }) else { return }
            var address = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let client = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    accept(descriptor, sockaddrPointer, &length)
                }
            }
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var noSignal: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                           socklen_t(MemoryLayout<Int32>.size))
            var sendTimeout = timeval(tv_sec: 2, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout,
                           socklen_t(MemoryLayout<timeval>.size))
            guard Self.peerIsSameUser(client) else {
                close(client)
                continue
            }
            let connection = ControlConnection(fd: client, server: self)
            let inserted = lock.withLock { () -> Bool in
                guard running, listenFD == descriptor else { return false }
                connections.append(connection)
                return true
            }
            guard inserted else {
                close(client)
                return
            }
            connection.start()
        }
    }

    private func authenticate(_ connection: ControlConnection) {
        let callback = lock.withLock { onAuthenticated }
        callback?(connection.identity)
    }

    private func remove(_ connection: ControlConnection) {
        let callback = lock.withLock { () -> (@Sendable (UUID) -> Void)? in
            connections.removeAll { $0 === connection }
            return onDisconnected
        }
        callback?(connection.identity)
    }

    private func matches(token candidate: String?) -> Bool {
        guard let candidate else { return false }
        let expected = Array(token.utf8)
        let supplied = Array(candidate.utf8)
        guard expected.count == supplied.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<expected.count {
            difference |= expected[index] ^ supplied[index]
        }
        return difference == 0
    }

    private func handle(_ message: BridgeControlMessage, connectionID: UUID) async -> BridgeControlMessage {
        let current = lock.withLock { handler }
        return await current(message, connectionID)
    }

    private static func peerIsSameUser(_ descriptor: Int32) -> Bool {
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &length) == 0 else {
            return false
        }
        return credentials.cr_uid == getuid()
    }

    private static func removeStaleSocketIfNeeded(_ path: String) throws {
        var details = stat()
        let exists = path.withCString { lstat($0, &details) } == 0
        guard exists else { return }
        guard (details.st_mode & S_IFMT) == S_IFSOCK else {
            throw BridgeControlFailure.remote("A non-socket file exists at the control path: \(path)")
        }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw BridgeControlFailure.socketUnavailable }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            close(probe)
            throw BridgeControlFailure.socketPathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(probe, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(probe)
        if result == 0 {
            throw BridgeControlFailure.remote("Another control service is already listening on \(path).")
        }
        unlinkPath(path)
    }

    private static func unlinkPath(_ path: String) {
        _ = path.withCString { unlink($0) }
    }

    fileprivate func connectionDidAuthenticate(_ connection: ControlConnection) {
        authenticate(connection)
    }

    fileprivate func connectionDidClose(_ connection: ControlConnection) {
        remove(connection)
    }

    fileprivate func connectionMatches(token candidate: String?) -> Bool {
        matches(token: candidate)
    }

    fileprivate func connectionHandler() -> Handler { lock.withLock { handler } }
    fileprivate func connectionServer() -> BridgeControlServer { self }
}

private final class ControlConnection: @unchecked Sendable {
    let identity = UUID()
    private let fd: Int32
    private weak var server: BridgeControlServer?
    private let sendLock = NSLock()
    private let stateLock = NSLock()
    // Authentication and disconnect callbacks must be observed in this
    // order, even when an external close races the read thread.
    private let callbackLock = NSLock()
    private var closed = false
    // Accessed only under sendLock. The read thread performs the final close.
    private var descriptorClosed = false
    private var authenticated = false

    init(fd: Int32, server: BridgeControlServer) {
        self.fd = fd
        self.server = server
    }

    var isAuthenticated: Bool {
        stateLock.withLock { authenticated && !closed }
    }

    func start() {
        Thread.detachNewThread { [self] in readLoop() }
    }

    func send(_ frame: Data) {
        let sent = sendLock.withLock { () -> Bool in
            guard !stateLock.withLock({ closed }) else { return false }
            var offset = 0
            while offset < frame.count {
                let written = frame.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return 0 }
                    return Darwin.send(fd, base.advanced(by: offset), frame.count - offset, 0)
                }
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
        if !sent { close() }
    }

    func close() {
        let shouldClose = stateLock.withLock { () -> Bool in
            if closed { return false }
            closed = true
            _ = shutdown(fd, SHUT_RDWR)
            return true
        }
        guard shouldClose else { return }
        #if FLOE_IPC_TESTING
        server?.didMarkClosedForTesting(identity)
        #endif
        callbackLock.withLock { server?.connectionDidClose(self) }
    }

    private func readLoop() {
        defer { finishReading() }
        guard let server else { return }
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        guard let hello = try? Self.readFrame(fd: fd, deadline: deadline) else { return }
        guard hello.kind == .hello, server.connectionMatches(token: hello.token) else {
            let error = BridgeControlMessage(kind: .reply, replyTo: hello.id,
                                             error: "Control authentication failed.")
            if let frame = try? BridgeControlCodec.encode(error) { send(frame) }
            return
        }
        let ready = stateLock.withLock { () -> Bool in
            guard !closed else { return false }
            authenticated = true
            return true
        }
        guard ready else { return }
        let ack = BridgeControlMessage(kind: .reply, replyTo: hello.id)
        if let frame = try? BridgeControlCodec.encode(ack) { send(frame) }
        guard isAuthenticated else { return }
        callbackLock.withLock {
            guard isAuthenticated else { return }
            server.connectionDidAuthenticate(self)
        }
        let event = BridgeControlMessage(kind: .event, event: BridgeControlEvent(kind: "authenticated"))
        if let frame = try? BridgeControlCodec.encode(event) { send(frame) }

        while !stateLock.withLock({ closed }) {
            guard let message = try? Self.readFrame(fd: fd) else { break }
            guard !stateLock.withLock({ closed }) else { break }
            if message.kind == .event { continue }
            let handler = server.connectionHandler()
            let messageID = message.id
            let connectionID = identity
            Task { [weak self] in
                guard let self else { return }
                var reply = await handler(message, connectionID)
                reply.replyTo = messageID
                if let frame = try? BridgeControlCodec.encode(reply) {
                    self.send(frame)
                }
            }
        }
    }

    private func finishReading() {
        close()
        sendLock.withLock {
            guard !descriptorClosed else { return }
            descriptorClosed = true
            Darwin.close(fd)
        }
    }

    private static func readFrame(fd: Int32, deadline: UInt64? = nil) throws -> BridgeControlMessage? {
        guard let header = readExactly(fd: fd, count: BridgeControlCodec.headerBytes, deadline: deadline) else {
            return nil
        }
        guard header.count == BridgeControlCodec.headerBytes,
              let length = BridgeControlCodec.bodyLength(fromHeader: header) else {
            throw BridgeControlFailure.invalidFrame
        }
        guard let body = readExactly(fd: fd, count: length, deadline: deadline), body.count == length else {
            throw BridgeControlFailure.invalidFrame
        }
        return try BridgeControlCodec.decodeBody(body)
    }

    private static func readExactly(fd: Int32, count: Int, deadline: UInt64?) -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            if let deadline {
                let now = DispatchTime.now().uptimeNanoseconds
                guard now < deadline else { return nil }
                let milliseconds = min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max))
                var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let result = Darwin.poll(&item, 1, Int32(milliseconds))
                if result < 0 && errno == EINTR { continue }
                guard result > 0, item.revents & Int16(POLLNVAL) == 0 else { return nil }
            }
            let readCount = data.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.recv(fd, base.advanced(by: offset), count - offset,
                                   deadline == nil ? 0 : MSG_DONTWAIT)
            }
            if readCount == 0 { return offset == 0 ? nil : Data(data.prefix(offset)) }
            if readCount < 0 {
                if errno == EINTR || (deadline != nil && (errno == EAGAIN || errno == EWOULDBLOCK)) { continue }
                return offset == 0 ? nil : Data(data.prefix(offset))
            }
            offset += readCount
        }
        return data
    }
}
