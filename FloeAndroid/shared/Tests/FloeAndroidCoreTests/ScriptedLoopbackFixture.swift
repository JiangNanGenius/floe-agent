// SPDX-License-Identifier: MPL-2.0
#if canImport(Darwin)
import Foundation
import Darwin

/// Minimal scripted HTTP/1.1 loopback fixture for the G02-P3 transport tests
/// (host-side only; test binary scope — never production). Binds
/// 127.0.0.1:0 (ephemeral port), serves exactly the registered paths, and
/// records what a real server can observe: request order per path, the exact
/// headers the client sent (redirect auth forwarding!), whether the CLIENT
/// aborted BEFORE the scripted body finished (early-cancel/early-cap proof),
/// and the completion state of every response. Teardown is bounded: accept
/// thread exits on listen-socket close, connection threads die on their own
/// send/recv timeouts (5 s) after the test ends. No TLS, no external
/// network, no production cleartext anywhere.
final class ScriptedLoopbackFixture: @unchecked Sendable {
    struct RecordedRequest: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
        let receivedAtMillis: Int64
    }


    struct Connection {
        let fd: Int32
        let request: RecordedRequest
        let fixture: ScriptedLoopbackFixture

        /// Send a head. `chunked` bodies are hex-framed by `sendChunk`.
        func sendHead(status: Int, headers: [String: String]) {
            var text = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
            for (name, value) in headers { text += "\(name): \(value)\r\n" }
            text += "\r\n"
            fixture.write(fd: fd, Data(text.utf8), path: request.path)
        }

        func sendRaw(_ data: Data) { fixture.write(fd: fd, data, path: request.path) }

        func sendChunk(_ data: Data) {
            var framed = Data(String(format: "%x\r\n", data.count).utf8)
            framed.append(data)
            framed.append(Data("\r\n".utf8))
            fixture.write(fd: fd, framed, path: request.path)
        }

        func finishChunked() {
            fixture.write(fd: fd, Data("0\r\n\r\n".utf8), path: request.path)
        }

        static func reason(_ status: Int) -> String {
            switch status {
            case 200: "OK"
            case 202: "Accepted"
            case 302: "Found"
            case 400: "Bad Request"
            case 401: "Unauthorized"
            case 404: "Not Found"
            case 500: "Internal Server Error"
            default: "Status"
            }
        }
    }

    private let listenFD: Int32
    private(set) var port: UInt16 = 0
    private let stateLock = NSLock()
    private var handlers: [String: @Sendable (Connection) -> Void] = [:]
    private var _requests: [RecordedRequest] = []
    private var earlyClosePaths = Set<String>()
    private var completedPaths = Set<String>()
    private var connectionThreads: [Thread] = []
    private var acceptThread: Thread?
    private var stopped = false

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0  // ephemeral
        guard withUnsafePointer(to: &address, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        guard Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.ECONNABORTED)
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        })
        port = UInt16(bigEndian: bound.sin_port)
        listenFD = fd
    }

    /// Register a synchronous scripted response for one exact path. The
    /// handler runs on its own connection thread, so plain `usleep` delays
    /// and repeated `sendChunk` calls produce a deterministic mid-response
    /// timeline a real SSE/HTTP server would.
    func register(path: String, _ handler: @escaping @Sendable (Connection) -> Void) {
        stateLock.lock()
        handlers[path] = handler
        stateLock.unlock()
    }

    func start() {
        let thread = Thread { [self] in acceptLoop() }
        thread.stackSize = 1 << 20
        thread.start()
        acceptThread = thread
    }

    private func acceptLoop() {
        while true {
            var clientAddr = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &clientAddr, {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenFD, $0, &length)
                }
            })
            if client < 0 { return }  // listen socket closed (stop)
            var nosig: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
            var sendTimeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
            var recvTimeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, socklen_t(MemoryLayout<timeval>.size))
            let thread = Thread { [self] in serve(client) }
            thread.stackSize = 1 << 20
            stateLock.lock()
            connectionThreads.append(thread)
            stateLock.unlock()
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        defer { Darwin.close(fd) }
        // Read request head (bounded) then body per Content-Length.
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil, buffer.count < 64 * 1024 {
            let read = recv(fd, &chunk, chunk.count, 0)
            if read <= 0 { return }
            buffer.append(contentsOf: chunk[0..<read])
        }
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
        let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
        var body = buffer[headEnd.upperBound...]
        var contentLength = 0
        for line in head.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                contentLength = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let deadline = Date().addingTimeInterval(10)
        while body.count < contentLength, Date() < deadline {
            let read = recv(fd, &chunk, min(chunk.count, contentLength - body.count), 0)
            if read <= 0 { break }
            body.append(contentsOf: chunk[0..<read])
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let request = RecordedRequest(
            method: parts[0], path: parts[1], headers: headers, body: Data(body),
            receivedAtMillis: Int64(Date().timeIntervalSince1970 * 1000))
        stateLock.lock()
        _requests.append(request)
        let handler = handlers[request.path]
        stateLock.unlock()
        guard let handler else {
            let connection = Connection(fd: fd, request: request, fixture: self)
            connection.sendHead(status: 404, headers: ["content-length": "0"])
            return
        }
        handler(Connection(fd: fd, request: request, fixture: self))
    }

    private func write(fd: Int32, _ data: Data, path: String) {
        data.withUnsafeBytes { raw in
            var sent = 0
            guard let base = raw.baseAddress else { return }
            while sent < raw.count {
                let written = Darwin.send(fd, base + sent, raw.count - sent, 0)
                if written <= 0 {
                    stateLock.lock()
                    earlyClosePaths.insert(path)
                    stateLock.unlock()
                    return
                }
                sent += written
            }
        }
    }

    // MARK: observation APIs (tests assert on these)

    var requests: [RecordedRequest] {
        stateLock.lock(); defer { stateLock.unlock() }
        return _requests
    }

    func count(for path: String) -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return _requests.filter { $0.path == path }.count
    }

    func headers(for path: String, occurrence: Int = 0) -> [String: String]? {
        stateLock.lock(); defer { stateLock.unlock() }
        let matches = _requests.filter { $0.path == path }
        guard occurrence < matches.count else { return nil }
        return matches[occurrence].headers
    }

    /// True when a write to the client failed or timed out — i.e. the CLIENT
    /// was gone before this scripted response finished.
    func sawClientAbort(for path: String) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return earlyClosePaths.contains(path)
    }

    /// Same signal, exposed for scripted handlers that want to stop early.
    func clientAborted(for path: String) -> Bool { sawClientAbort(for: path) }

    func stop() {
        stateLock.lock()
        guard !stopped else { stateLock.unlock(); return }
        stopped = true
        stateLock.unlock()
        Darwin.shutdown(listenFD, SHUT_RDWR)
        Darwin.close(listenFD)
    }

    deinit { stop() }
}

extension ScriptedLoopbackFixture {
    /// Deterministic wall-clock pause inside a connection handler thread.
    static func sleep(_ milliseconds: Int) {
        usleep(UInt32(milliseconds) * 1_000)
    }
}
#endif
