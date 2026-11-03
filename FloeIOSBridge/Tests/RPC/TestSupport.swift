import CryptoKit
import Darwin
import Foundation

import BridgeCore
import BridgeHost
struct TestFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure("expectation failed: \(message)") }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw TestFailure("\(message): expected \(expected), got \(actual)")
    }
}

func expectNotNil<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw TestFailure("expected non-nil: \(message)") }
    return value
}

func expectContains(_ haystack: String, _ needle: String, _ message: String) throws {
    if !haystack.contains(needle) {
        throw TestFailure("\(message): \(String(haystack.prefix(400))) does not contain \(needle)")
    }
}

final class MutableClock: @unchecked Sendable {
    private let lock = BridgeRPCLock()
    private var value: Date

    init(_ value: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.value = value
    }

    func now() -> Date {
        lock.withLock { value }
    }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(seconds) }
    }
}

final class MemoryClientStore: BridgeRPCClientStore, @unchecked Sendable {
    private let lock = BridgeRPCLock()
    private var clients: [String: BridgeRPCStoredClient] = [:]
    private var nonceState: [String: [String: Int]] = [:]

    var failLoadClients = false
    var failLoadNonces = false
    var failSaveNonces = false
    var failUpsert = false
    var failRemove = false
    var failRemoveAll = false
    var upsertEntered: DispatchSemaphore?
    var upsertBlock: DispatchSemaphore?

    private(set) var upserts = 0
    private(set) var removals = 0

    func loadClients() throws -> [BridgeRPCStoredClient] {
        if failLoadClients { throw BridgeRPCStoreError.unavailable("test-load-clients") }
        return lock.withLock { Array(clients.values) }
    }

    func loadNonces() throws -> [String: [String: Int]] {
        if failLoadNonces { throw BridgeRPCStoreError.unavailable("test-load-nonces") }
        return lock.withLock { nonceState }
    }

    func upsertClient(_ client: BridgeRPCStoredClient) throws {
        upsertEntered?.signal()
        upsertBlock?.wait()
        if failUpsert { throw BridgeRPCStoreError.unavailable("test-upsert") }
        lock.withLock {
            clients[client.clientID] = client
            upserts += 1
        }
    }

    func removeClient(clientID: String) throws {
        if failRemove { throw BridgeRPCStoreError.unavailable("test-remove") }
        lock.withLock {
            if clients.removeValue(forKey: clientID) != nil { removals += 1 }
            nonceState.removeValue(forKey: clientID)
        }
    }

    func removeAllClients() throws {
        if failRemoveAll { throw BridgeRPCStoreError.unavailable("test-remove-all") }
        lock.withLock {
            removals += clients.count
            clients.removeAll()
            nonceState.removeAll()
        }
    }

    func saveNonces(_ nonces: [String: [String: Int]]) throws {
        if failSaveNonces { throw BridgeRPCStoreError.unavailable("test-save-nonces") }
        lock.withLock { nonceState = nonces }
    }

    func count() -> Int {
        lock.withLock { clients.count }
    }

    func nonceCount() -> Int {
        lock.withLock { nonceState.values.reduce(0) { $0 + $1.count } }
    }

    func stored(clientID: String) -> BridgeRPCStoredClient? {
        lock.withLock { clients[clientID] }
    }
}

final class ApprovalGate: @unchecked Sendable {
    private let lock = BridgeRPCLock()
    private var pending: [String: CheckedContinuation<BridgeRPCApprovalDecision, Never>] = [:]

    var handler: BridgeRPCApprovalHandler {
        { [weak self] request in
            guard let self else { return .deny }
            return await withCheckedContinuation { continuation in
                self.lock.withLock {
                    self.pending[request.requestID] = continuation
                }
            }
        }
    }

    func pendingCount() -> Int {
        lock.withLock { pending.count }
    }

    func finish(requestID: String, decision: BridgeRPCApprovalDecision) {
        let continuation: CheckedContinuation<BridgeRPCApprovalDecision, Never>? = lock.withLock {
            pending.removeValue(forKey: requestID)
        }
        continuation?.resume(returning: decision)
    }

    func finishAll(_ decision: BridgeRPCApprovalDecision) {
        let all = lock.withLock { () -> [CheckedContinuation<BridgeRPCApprovalDecision, Never>] in
            let values = Array(pending.values)
            pending.removeAll()
            return values
        }
        for continuation in all { continuation.resume(returning: decision) }
    }
}

final class FakeExecutor: BridgeRPCExecutor, @unchecked Sendable {
    typealias Handler = @Sendable (BridgeRPCInvocation) async -> BridgeRPCExecutionOutcome
    typealias PermitHandler = @Sendable (BridgeRPCInvocation, BridgeRPCDispatchPermit) async
        -> BridgeRPCExecutionOutcome

    private let lock = BridgeRPCLock()
    private var storedReadiness: BridgeRPCEngineReadiness = .notReady(reason: "test")
    private var storedMethods: Set<String> = []
    private var executionCount = 0
    private var sdkDispatchCount = 0
    private var lastInvocation: BridgeRPCInvocation?
    private var handler: Handler?
    private var permitHandler: PermitHandler?
    private var autoAuthorize: Bool

    init(readiness: BridgeRPCEngineReadiness = .notReady(reason: "test"),
         supportedMethods: Set<String> = [],
         handler: Handler? = nil) {
        storedReadiness = readiness
        storedMethods = supportedMethods
        self.handler = handler
        self.autoAuthorize = true
    }

    init(readiness: BridgeRPCEngineReadiness = .notReady(reason: "test"),
         supportedMethods: Set<String> = [],
         autoAuthorize: Bool,
         permitHandler: @escaping PermitHandler) {
        storedReadiness = readiness
        storedMethods = supportedMethods
        self.permitHandler = permitHandler
        self.autoAuthorize = autoAuthorize
    }

    var readiness: BridgeRPCEngineReadiness {
        lock.withLock { storedReadiness }
    }

    var supportedMethods: Set<String> {
        lock.withLock { storedMethods }
    }

    func setReadiness(_ value: BridgeRPCEngineReadiness) {
        lock.withLock { storedReadiness = value }
    }

    func setSupportedMethods(_ value: Set<String>) {
        lock.withLock { storedMethods = value }
    }

    func setHandler(_ value: @escaping Handler) {
        lock.withLock { handler = value }
    }

    func execute(_ invocation: BridgeRPCInvocation,
                 permit: BridgeRPCDispatchPermit) async -> BridgeRPCExecutionOutcome {
        if autoAuthorize {
            guard permit.authorizeDispatch() else {
                return .failure(.fenced)
            }
            lock.withLock { sdkDispatchCount += 1 }
        }
        let (handler, permitHandler) = lock.withLock { () -> (Handler?, PermitHandler?) in
            executionCount += 1
            lastInvocation = invocation
            return (self.handler, self.permitHandler)
        }
        if let permitHandler {
            return await permitHandler(invocation, permit)
        }
        guard let handler else {
            return .failure(.serverError("No test handler"))
        }
        return await handler(invocation)
    }

    func count() -> Int {
        lock.withLock { executionCount }
    }

    func sdkCount() -> Int {
        lock.withLock { sdkDispatchCount }
    }

    func noteSDK() {
        lock.withLock { sdkDispatchCount += 1 }
    }

    func invocation() -> BridgeRPCInvocation? {
        lock.withLock { lastInvocation }
    }
}

struct TestLogs: BridgeRPCLogSource {
    var lines: [String] = ["log line one", "log line two", "sensitive-looking=false"]
    var files: [String]? = ["2026-11-01.log 12 bytes"]
    var history: String? = "history line\n"

    func recentLog(limit: Int, matching: String?) -> [String] {
        let filtered = matching.map { needle in lines.filter { $0.contains(needle) } } ?? lines
        return Array(filtered.suffix(max(0, limit)))
    }

    func logFiles() -> [String]? { files }
    func logHistory(date: String?) -> String? { history }
}

struct TestResources: BridgeRPCResourceProvider {
    var skill: String? = "# Floe Bridge test skill\nENDPOINTS /pair /rpc /schema /skill /stream /logs\n"
    var remote: String? = "<!doctype html><title>Bridge</title>"

    func skillMarkdown() -> String? { skill }
    func remotePageHTML() -> String? { remote }
}

final class TestStreamSource: BridgeRPCStreamSource, @unchecked Sendable {
    let contentType: String
    private let lock = BridgeRPCLock()
    private var openCount = 0
    private var stop = false

    init(contentType: String = "application/octet-stream") {
        self.contentType = contentType
    }

    var opens: Int { lock.withLock { openCount } }

    func openStream(clientID: String, channel: BridgeRPCStreamChannel) async -> Bool {
        lock.withLock { openCount += 1 }
        guard channel.yield(Data("first-frame\n".utf8)) else { return false }
        Task {
            var tick = 0
            while !Task.isCancelled {
                let done = self.lock.withLock { self.stop || channel.isFinished }
                if done { break }
                try? await Task.sleep(nanoseconds: 60_000_000)
                if channel.isFinished { break }
                tick += 1
                if !channel.yield(Data("frame-\(tick)\n".utf8)) { break }
            }
            channel.finish()
        }
        return true
    }

    func markStop() {
        lock.withLock { stop = true }
    }
}

final class ServerFixture: @unchecked Sendable {
    let store: MemoryClientStore
    let authority: BridgeRPCAuthority
    let registry: BridgeRPCEngineRegistry
    let coordinator: BridgeRPCExecutionCoordinator
    let service: BridgeRPCService
    let server: BridgeRPCNetworkServer
    let logs: (any BridgeRPCLogSource)?
    let streamSource: (any BridgeRPCStreamSource)?
    private let logLock = BridgeRPCLock()
    private var logLines: [String] = []

    init(limits: BridgeRPCLimits = TestLimits.standard,
         approval: BridgeRPCApprovalHandler? = { _ in .approve },
         resources: any BridgeRPCResourceProvider = TestResources(),
         logs: (any BridgeRPCLogSource)? = TestLogs(),
         streamSource: (any BridgeRPCStreamSource)? = nil,
         clock: MutableClock? = nil,
         random: (@Sendable (Int) -> Data?)? = nil) {
        self.store = MemoryClientStore()
        self.logs = logs
        self.streamSource = streamSource
        if let clock, let random {
            self.authority = BridgeRPCAuthority(store: store, limits: limits,
                                                approvalHandler: approval,
                                                now: { clock.now() }, random: random)
        } else if let clock {
            self.authority = BridgeRPCAuthority(store: store, limits: limits,
                                                approvalHandler: approval,
                                                now: { clock.now() })
        } else if let random {
            self.authority = BridgeRPCAuthority(store: store, limits: limits,
                                                approvalHandler: approval,
                                                random: random)
        } else {
            self.authority = BridgeRPCAuthority(store: store, limits: limits,
                                                approvalHandler: approval)
        }
        self.registry = BridgeRPCEngineRegistry()
        self.coordinator = BridgeRPCExecutionCoordinator(limits: limits)
        self.service = BridgeRPCService(
            configuration: .init(requestedPort: 0, limits: limits),
            authority: authority,
            registry: registry,
            coordinator: coordinator,
            resources: resources,
            logs: logs,
            streamSource: streamSource
        )
        self.server = BridgeRPCNetworkServer(service: service, limits: limits)
        server.setLogHandler { [weak self] line in
            self?.logLock.withLock { self?.logLines.append(line) }
        }
    }

    func start() throws -> UInt16 {
        try server.start(requestedPort: 0)
        guard let port = server.snapshot.port else {
            throw TestFailure("server did not report a port")
        }
        return port
    }

    func stop() {
        server.stop()
    }

    func transportLog() -> [String] {
        logLock.withLock { logLines }
    }
}

enum TestLimits {
    static let standard = BridgeRPCLimits(
        maxRequestHeadBytes: 16_384,
        maxRequestBodyBytes: 262_144,
        maxJSONResponseBytes: 4 * 1_024 * 1_024,
        maxConnections: 8,
        maxQueuedAutomationCalls: 16,
        maxCompletedOperations: 256,
        maxOperationLedgerBytes: 8 * 1_024 * 1_024,
        maxSingleOperationResultBytes: 1 * 1_024 * 1_024,
        streamConsumerBufferBytes: 262_144,
        maxStreamConsumers: 8,
        timestampWindow: 120,
        nonceCapacityPerClient: 4_096,
        approvalTimeout: 0.6,
        pairCooldown: 0.3,
        inactivityWindow: 30 * 24 * 60 * 60,
        maxClients: 100,
        streamTicketTTL: 60,
        maxStreamTickets: 128,
        requestReadTimeout: 8,
        responseWriteTimeout: 8,
        executionTimeout: 5
    )
}

// MARK: - Raw HTTP client

struct RawHTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: Data
    var raw: Data
}

enum HTTPClientError: Error, CustomStringConvertible {
    case failure(String)
    var description: String {
        switch self { case .failure(let message): return message }
    }
}

enum RawHTTP {
    static func request(host: String,
                        port: UInt16,
                        method: String,
                        path: String,
                        extraHeaders: [String: String] = [:],
                        body: Data = Data(),
                        halfClose: Bool = false) throws -> RawHTTPResponse {
        let fd = try connect(host: host, port: port)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var headers: [String: String] = [
            "Host": host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)",
            "Connection": "close",
            "Content-Length": String(body.count),
        ]
        for (key, value) in extraHeaders { headers[key] = value }
        var head = "\(method) \(path) HTTP/1.1\r\n"
        for key in headers.keys.sorted() {
            head += "\(key): \(headers[key]!)\r\n"
        }
        head += "\r\n"
        var request = Data(head.utf8)
        request.append(body)
        try sendAll(fd, request)
        if halfClose { shutdown(fd, SHUT_WR) }
        let raw = try readAll(fd)
        return try parse(raw)
    }

    static func raw(host: String, port: UInt16, bytes: Data, halfClose: Bool = false) throws -> RawHTTPResponse {
        let fd = try connect(host: host, port: port)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        try sendAll(fd, bytes)
        if halfClose { shutdown(fd, SHUT_WR) }
        let raw = try readAll(fd)
        if raw.isEmpty {
            return RawHTTPResponse(status: -1, headers: [:], body: Data(), raw: Data())
        }
        return try parse(raw)
    }

    static func connect(host: String, port: UInt16) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else {
            throw HTTPClientError.failure("getaddrinfo \(host): \(String(cString: gai_strerror(status)))")
        }
        defer { freeaddrinfo(first) }
        var lastError = "no address"
        for pointer in sequence(first: first, next: { $0.pointee.ai_next }) {
            let fd = socket(pointer.pointee.ai_family, pointer.pointee.ai_socktype, pointer.pointee.ai_protocol)
            if fd < 0 { lastError = "socket failed"; continue }
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                       socklen_t(MemoryLayout<Int32>.size))
            let connected = Darwin.connect(fd, pointer.pointee.ai_addr, pointer.pointee.ai_addrlen)
            if connected == 0 { return fd }
            lastError = String(cString: strerror(errno))
            close(fd)
        }
        throw HTTPClientError.failure("connect \(host):\(port): \(lastError)")
    }

    static func sendAll(_ fd: Int32, _ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let sent = send(fd, base.advanced(by: offset), raw.count - offset, 0)
                if sent > 0 { offset += sent; continue }
                if sent < 0 && errno == EINTR { continue }
                throw HTTPClientError.failure("send failed: \(String(cString: strerror(errno)))")
            }
        }
    }

    static func readAll(_ fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
                if data.count > 32 * 1_024 * 1_024 { break }
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            throw HTTPClientError.failure("recv failed: \(String(cString: strerror(errno)))")
        }
        return data
    }

    static func parse(_ raw: Data) throws -> RawHTTPResponse {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let range = raw.range(of: separator) else {
            throw HTTPClientError.failure("response has no header terminator")
        }
        let headData = raw.subdata(in: raw.startIndex..<range.lowerBound)
        guard let head = String(data: headData, encoding: .utf8) else {
            throw HTTPClientError.failure("response head is not UTF-8")
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw HTTPClientError.failure("response has no status line")
        }
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else {
            throw HTTPClientError.failure("bad status line \(statusLine)")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        var body = raw.subdata(in: range.upperBound..<raw.endIndex)
        if headers["transfer-encoding"]?.lowercased() == "chunked" {
            body = try decodeChunked(body)
        }
        return RawHTTPResponse(status: status, headers: headers, body: body, raw: raw)
    }

    static func decodeChunked(_ data: Data) throws -> Data {
        var output = Data()
        var index = data.startIndex
        while index < data.endIndex {
            guard let lineEnd = data[index...].range(of: Data("\r\n".utf8))?.lowerBound else {
                throw HTTPClientError.failure("chunk header truncated")
            }
            let sizeText = String(decoding: data[index..<lineEnd], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else {
                throw HTTPClientError.failure("bad chunk size \(sizeText)")
            }
            index = data.index(lineEnd, offsetBy: 2)
            if size == 0 { break }
            guard data.distance(from: index, to: data.endIndex) >= size + 2 else {
                throw HTTPClientError.failure("chunk body truncated")
            }
            let end = data.index(index, offsetBy: size)
            output.append(data[index..<end])
            index = data.index(end, offsetBy: 2)
        }
        return output
    }
}

// MARK: - Pairing / RPC client

struct RPCSession {
    let key: Data
    let tokenID: String
    let clientName: String
}

struct PairResult {
    let session: RPCSession
    let didOpen: Bool
    let response: RawHTTPResponse
}

enum BridgeTestClient {
    static func pairPlain(host: String, port: UInt16, name: String) throws -> PairResult {
        let body = BridgeRPCJSONValue.object([
            "client_name": .string(name),
            "plain": .bool(true),
        ]).canonicalData()
        let response = try RawHTTP.request(host: host, port: port, method: "POST",
                                           path: "/pair", body: body)
        guard response.status == 200,
              let object = try BridgeRPCJSON.decode(response.body).objectValue,
              let token = object["token"]?.stringValue,
              let key = BridgeRPCEnvelope.strictHex(token, byteCount: 32),
              let tokenID = object["tok"]?.stringValue else {
            throw TestFailure("plain pairing failed: \(response.status) \(String(decoding: response.body, as: UTF8.self))")
        }
        return PairResult(session: RPCSession(key: key, tokenID: tokenID, clientName: name),
                          didOpen: true, response: response)
    }

    static func pairX25519(host: String, port: UInt16, name: String) throws -> PairResult {
        let clientPrivate = Curve25519.KeyAgreement.PrivateKey()
        let clientPublic = clientPrivate.publicKey.rawRepresentation
        let body = BridgeRPCJSONValue.object([
            "client_name": .string(name),
            "pub": .string(clientPublic.base64EncodedString()),
        ]).canonicalData()
        let response = try RawHTTP.request(host: host, port: port, method: "POST",
                                           path: "/pair", body: body)
        guard response.status == 200,
              let object = try BridgeRPCJSON.decode(response.body).objectValue,
              let tokenID = object["tok"]?.stringValue,
              let publicBase64 = object["pub"]?.stringValue,
              let devicePublicData = Data(base64Encoded: publicBase64),
              let tokenCiphertext = object["token_ct"]?.stringValue.flatMap({
                  BridgeRPCEnvelope.strictHex($0, byteCount: 32)
              }) else {
            throw TestFailure("X25519 pairing failed: \(response.status) \(String(decoding: response.body, as: UTF8.self))")
        }
        let devicePublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: devicePublicData)
        let shared = try clientPrivate.sharedSecretFromKeyAgreement(with: devicePublic)
        let sharedData = shared.withUnsafeBytes { Data($0) }
        guard let key = BridgeRPCEnvelope.unwrapKey(
            tokenCiphertext: tokenCiphertext,
            sharedSecret: sharedData,
            clientPublicKey: clientPublic,
            devicePublicKey: devicePublicData
        ) else {
            throw TestFailure("X25519 unwrap failed")
        }
        return PairResult(session: RPCSession(key: key, tokenID: tokenID, clientName: name),
                          didOpen: true, response: response)
    }

    struct CallResult {
        let response: BridgeRPCJSONValue
        let plaintext: Data
        let nonce: Data
        let httpStatus: Int
    }

    static func call(session: RPCSession,
                     host: String,
                     port: UInt16,
                     method: String,
                     params: BridgeRPCJSONValue = .object([:]),
                     id: BridgeRPCJSONValue = .int(1),
                     operationID: String? = nil,
                     timestamp: Int? = nil,
                     nonce: Data? = nil) throws -> CallResult {
        let request = BridgeRPCRequest(method: method, params: params, id: id, operationID: operationID)
        let nonceData = nonce ?? BridgeRPCEnvelope.randomBytes(16)!
        let ts = timestamp ?? Int(Date().timeIntervalSince1970)
        let envelope = BridgeRPCEnvelope.sealRequest(request.encodedData(),
                                                     key: session.key,
                                                     nonce: nonceData,
                                                     timestamp: ts)
        let http = try RawHTTP.request(host: host, port: port, method: "POST",
                                       path: "/rpc", body: envelope.canonicalData())
        guard http.status == 200 else {
            throw TestFailure("rpc transport \(http.status): \(String(decoding: http.body, as: UTF8.self))")
        }
        let envelopeValue = try BridgeRPCJSON.decode(http.body)
        let plaintext = try BridgeRPCEnvelope.openResponse(
            envelopeValue,
            key: session.key,
            expectedNonceHex: BridgeRPCEnvelope.hexLowercase(nonceData)
        )
        let value = try BridgeRPCJSON.decode(plaintext)
        return CallResult(response: value, plaintext: plaintext, nonce: nonceData, httpStatus: http.status)
    }

    static func errorCode(_ result: CallResult) -> Int? {
        result.response.objectValue?["error"]?.objectValue?["code"]?.intValue
    }

    static func resultObject(_ result: CallResult) -> [String: BridgeRPCJSONValue]? {
        result.response.objectValue?["result"]?.objectValue
    }
}

// MARK: - Host helpers

func waitSemaphore(_ semaphore: DispatchSemaphore, timeout: TimeInterval = 3) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + timeout)
}

func blockingSleep(_ seconds: TimeInterval) {
    Thread.sleep(forTimeInterval: seconds)
}

func waitGroup(_ group: DispatchGroup, timeout: TimeInterval = 5) -> DispatchTimeoutResult {
    group.wait(timeout: .now() + timeout)
}

func testCString(_ pointer: UnsafePointer<CChar>) -> String {
    let count = strlen(pointer)
    let raw = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
    return String(decoding: UnsafeBufferPointer(start: raw, count: count), as: UTF8.self)
}

func fakeIPv4Sockaddr(_ address: String, port: UInt16 = 43210) -> sockaddr_storage {
    var storage = sockaddr_storage()
    withUnsafeMutablePointer(to: &storage) { pointer in
        pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { value in
            value.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            value.pointee.sin_family = sa_family_t(AF_INET)
            value.pointee.sin_port = port.bigEndian
            _ = withUnsafeMutablePointer(to: &value.pointee.sin_addr) {
                inet_pton(AF_INET, address, $0)
            }
        }
    }
    return storage
}

func fakeIPv6Sockaddr(_ address: String, port: UInt16 = 43210,
                     scopeID: UInt32 = 0) -> sockaddr_storage {
    var storage = sockaddr_storage()
    withUnsafeMutablePointer(to: &storage) { pointer in
        pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { value in
            value.pointee.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            value.pointee.sin6_family = sa_family_t(AF_INET6)
            value.pointee.sin6_port = port.bigEndian
            value.pointee.sin6_scope_id = scopeID
            _ = withUnsafeMutablePointer(to: &value.pointee.sin6_addr) {
                inet_pton(AF_INET6, address, $0)
            }
        }
    }
    return storage
}

func lanIPv6Addresses() -> [String] {
    var result: [String] = []
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
    defer { freeifaddrs(pointer) }
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let value = entry.pointee
        guard let address = value.ifa_addr,
              address.pointee.sa_family == UInt8(AF_INET6) else { continue }
        let name = testCString(value.ifa_name)
        guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        var raw = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
        guard inet_ntop(AF_INET6, &raw, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else { continue }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if text.hasPrefix("fe80:") || text == "::1" { continue }
        result.append(text)
    }
    return result
}

func lanIPv4Addresses() -> [String] {
    var result: [String] = []
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
    defer { freeifaddrs(pointer) }
    for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let value = entry.pointee
        guard let address = value.ifa_addr,
              address.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = testCString(value.ifa_name)
        guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        guard inet_ntop(AF_INET, &raw, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        if !text.hasPrefix("127.") { result.append(text) }
    }
    return result
}

@discardableResult
func waitUntil(timeout: TimeInterval = 5,
               interval: UInt64 = 20_000_000,
               _ condition: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: interval)
    }
    return condition()
}
