// FloeIOSAutomationTests — synthetic loopback fixtures and in-memory stores.
//
// These fixtures exercise the real client transport against a real loopback
// socket and an independently coded v1 envelope helper. They are NOT device
// proof and never contact a real Bridge service.

import CryptoKit
import Darwin
import Foundation
@testable import FloeIOSAutomation

struct TestFailure: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

func testExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure("expectation failed: \(message)") }
}

func testExpectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    if actual != expected {
        throw TestFailure("\(message): expected \(expected), got \(actual)")
    }
}

final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        self.stored = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Value) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&stored)
        lock.unlock()
    }
}

// MARK: - Clock / randomness / authority

final class TestClock: IOSBridgeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }

    func set(_ date: Date) {
        lock.lock()
        value = date
        lock.unlock()
    }
}

final class TestRandomness: IOSBridgeRandomness, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Data]
    private var counter: UInt8 = 1

    init(_ queued: [Data] = []) {
        self.queued = queued
    }

    func bytes(_ count: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if !queued.isEmpty {
            let next = queued.removeFirst()
            if next.count == count { return next }
        }
        var output = Data()
        output.reserveCapacity(count)
        for _ in 0..<count {
            output.append(counter)
            counter &+= 1
        }
        return output
    }
}

struct AllowAllAuthority: IOSAutomationTaskAuthority {
    func authorize(_ request: IOSAutomationAuthorizationRequest) async
        -> IOSAutomationAuthorizationDecision {
        .allowed
    }
}

struct DenyAllAuthority: IOSAutomationTaskAuthority {
    func authorize(_ request: IOSAutomationAuthorizationRequest) async
        -> IOSAutomationAuthorizationDecision {
        .denied(reason: "test denial")
    }
}

struct StubCompanionProbe: IOSBridgeCompanionProbe {
    let value: IOSBridgeCompanionPresence
    func presence() async -> IOSBridgeCompanionPresence { value }
}

// MARK: - In-memory pairing store

actor MemoryPairingStore: IOSBridgePairingStore {
    enum Mode: Sendable, Equatable {
        case normal
        case locked
        case unavailable
        case failSave
        case failDelete
        case corruptOnLoad
        case mismatchOnReadback
        case mismatchAfterSave
    }

    private(set) var records: [IOSBridgePairingHandle: Data] = [:]
    private(set) var saveCount = 0
    private(set) var deleteCount = 0
    private var mode: Mode = .normal
    private var alternateRecord: IOSBridgePairingRecord?
    private var savedSinceMismatch = false

    func setMode(_ mode: Mode) {
        self.mode = mode
        savedSinceMismatch = false
    }

    func setAlternateRecord(_ record: IOSBridgePairingRecord?) {
        alternateRecord = record
    }

    func seed(_ record: IOSBridgePairingRecord, for handle: IOSBridgePairingHandle) throws {
        records[handle] = try record.encodedSecretPayload()
    }

    func hasRecord(_ handle: IOSBridgePairingHandle) -> Bool {
        records[handle] != nil
    }

    func availability(for handle: IOSBridgePairingHandle) async -> IOSBridgeCredentialAvailability {
        switch mode {
        case .locked: return .locked(reason: "test lock")
        case .unavailable: return .unavailable(reason: "test unavailable")
        default: break
        }
        return records[handle] == nil ? .missing : .available
    }

    func load(_ handle: IOSBridgePairingHandle) async throws -> IOSBridgePairingRecord {
        switch mode {
        case .locked: throw IOSBridgePairingStoreError.locked
        case .unavailable: throw IOSBridgePairingStoreError.unavailable("test")
        case .corruptOnLoad: throw IOSBridgePairingStoreError.corrupt
        case .mismatchOnReadback:
            if let alternateRecord { return alternateRecord }
            throw IOSBridgePairingStoreError.corrupt
        case .mismatchAfterSave:
            if savedSinceMismatch, let alternateRecord { return alternateRecord }
        default: break
        }
        guard let data = records[handle] else {
            throw IOSBridgePairingStoreError.missing
        }
        return try IOSBridgePairingRecord.decodeSecretPayload(data)
    }

    func save(_ record: IOSBridgePairingRecord, for handle: IOSBridgePairingHandle) async throws {
        saveCount += 1
        switch mode {
        case .locked: throw IOSBridgePairingStoreError.locked
        case .unavailable, .failSave: throw IOSBridgePairingStoreError.unavailable("test")
        default: break
        }
        records[handle] = try record.encodedSecretPayload()
        if mode == .mismatchAfterSave {
            savedSinceMismatch = true
        }
    }

    func delete(_ handle: IOSBridgePairingHandle) async throws {
        deleteCount += 1
        switch mode {
        case .locked: throw IOSBridgePairingStoreError.locked
        case .unavailable, .failDelete: throw IOSBridgePairingStoreError.unavailable("test")
        default: break
        }
        guard records.removeValue(forKey: handle) != nil else {
            throw IOSBridgePairingStoreError.missing
        }
    }
}

// MARK: - Record / context helpers

func testKey(_ seed: UInt8 = 0) -> Data {
    Data((0..<32).map { UInt8(($0 + Int(seed)) % 256) })
}

func testRecord(
    key: Data = testKey(),
    clientName: String = "Floe on iPhone",
    grantedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    expiresAt: Date? = nil
) throws -> IOSBridgePairingRecord {
    let expiry = expiresAt ?? grantedAt.addingTimeInterval(30 * 24 * 60 * 60)
    return try IOSBridgePairingRecord(
        tokenID: IOSBridgeEnvelope.tokenID(for: key),
        clientName: clientName,
        grantedAt: grantedAt,
        lastVerifiedAt: grantedAt,
        expiresAt: expiry,
        protocolVersion: 1,
        keyMaterial: key
    )
}

func testContext(
    taskID: UUID = UUID(),
    generation: UInt64 = 1,
    operationID: String? = nil,
    cancellation: IOSAutomationCancellationToken = IOSAutomationCancellationToken(),
    window: IOSAutomationExecutionWindow = .foreground(),
    authorityOverride: (any IOSAutomationTaskAuthority)? = nil
) -> IOSAutomationCallContext {
    IOSAutomationCallContext(
        taskID: taskID,
        taskGeneration: generation,
        clientSessionID: "test-session",
        toolCallID: "test-call",
        toolIdempotencyKey: nil,
        operationID: operationID,
        cancellation: cancellation,
        executionWindow: window,
        authorityOverride: authorityOverride
    )
}

// MARK: - Fixture HTTP server

struct FixtureRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var jsonObject: [String: IOSBridgeJSONValue]? {
        guard let value = try? IOSBridgeJSONValue.decode(body) else { return nil }
        return value.objectValue
    }
}

struct FixtureResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
    let delay: TimeInterval
    /// A test-only way to close the socket without any HTTP response, which
    /// simulates an interrupted mutation after Bridge may have read it.
    let drop: Bool

    init(
        status: Int,
        headers: [String: String] = [:],
        body: Data,
        delay: TimeInterval = 0,
        drop: Bool = false
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.delay = delay
        self.drop = drop
    }

    static func dropping() -> FixtureResponse {
        FixtureResponse(status: 0, body: Data(), drop: true)
    }
}

final class FixtureHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (FixtureRequest) -> FixtureResponse

    private let handler: Handler
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var stopped = false
    private var boundPort: UInt16 = 0
    private var storedRequests: [FixtureRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestFailure("socket failed") }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw TestFailure("bind/listen failed: \(String(cString: strerror(errno)))")
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            throw TestFailure("getsockname failed")
        }
        lock.lock()
        listenFD = fd
        boundPort = UInt16(bigEndian: actual.sin_port)
        stopped = false
        storedRequests = []
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "FloeIOSAutomation.FixtureHTTP"
        thread.start()
        return boundPort
    }

    func stop() {
        lock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        lock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    var requests: [FixtureRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    var requestCount: Int { requests.count }

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = listenFD
            let isStopped = stopped
            lock.unlock()
            if isStopped || fd < 0 { return }
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            DispatchQueue.global().async { [weak self] in
                self?.handle(client)
            }
        }
    }

    private func handle(_ fd: Int32) {
        defer { close(fd) }
        var timeout = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        guard let request = readRequest(fd) else { return }
        lock.lock()
        storedRequests.append(request)
        lock.unlock()
        let response = handler(request)
        if response.delay > 0 {
            Thread.sleep(forTimeInterval: response.delay)
        }
        if response.drop { return }
        writeResponse(fd, response)
    }

    private func readRequest(_ fd: Int32) -> FixtureRequest? {
        var data = Data()
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while data.range(of: terminator) == nil {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { return nil }
            data.append(contentsOf: buffer[0..<count])
            if data.count > 64 * 1_024 { return nil }
        }
        guard let separator = data.range(of: terminator),
              let head = String(
                  data: data.subdata(in: data.startIndex..<separator.lowerBound),
                  encoding: .utf8
              ) else {
            return nil
        }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength >= 0, contentLength <= IOSBridgeProtocol.maxRequestBodyBytes else {
            return nil
        }
        while data.count < (separator.upperBound - data.startIndex) + contentLength {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { return nil }
            data.append(contentsOf: buffer[0..<count])
        }
        let bodyStart = data.index(data.startIndex, offsetBy: separator.upperBound - data.startIndex)
        let body = data.subdata(in: bodyStart..<data.endIndex)
        return FixtureRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: headers,
            body: body
        )
    }

    private func writeResponse(_ fd: Int32, _ response: FixtureResponse) {
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        if headers["Content-Type"] == nil, headers["content-type"] == nil {
            headers["Content-Type"] = "application/json; charset=utf-8"
        }
        var head = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var bytes = Data(head.utf8)
        bytes.append(response.body)
        _ = sendAll(fd, bytes)
    }

    private func sendAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            while offset < raw.count {
                let sent = send(fd, base.advanced(by: offset), raw.count - offset, 0)
                if sent > 0 {
                    offset += sent
                    continue
                }
                if sent < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
    }

    private func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Response"
        }
    }
}

// MARK: - Independent v1 fixture crypto

enum FixtureCrypto {
    static let keyCount = 32
    static let nonceCount = 16
    static let tagCount = 32

    static func openRequest(
        _ value: IOSBridgeJSONValue,
        key: Data
    ) throws -> (plaintext: Data, nonce: Data, nonceHex: String, timestamp: Int) {
        guard let object = value.objectValue,
              object["v"] == .int(1),
              let tokenText = object["tok"]?.stringValue,
              let timestamp = object["ts"]?.intValue, timestamp >= 0,
              let nonceHex = object["nonce"]?.stringValue,
              let nonce = strictHex(nonceHex, count: nonceCount),
              let tokenBytes = strictHex(tokenText, count: 4),
              let ciphertextBase64 = object["ct"]?.stringValue,
              let ciphertext = Data(base64Encoded: ciphertextBase64, options: []),
              let tagText = object["tag"]?.stringValue,
              let tag = strictHex(tagText, count: tagCount) else {
            throw TestFailure("fixture could not parse request envelope")
        }
        let keyMAC = hmac(key, Data("ictrl-v1|mac".utf8) + nonce)
        let signed = Data("v1".utf8) + tokenBytes + be64(UInt64(timestamp))
            + nonce + ciphertext
        guard hmac(keyMAC, signed) == tag else {
            throw TestFailure("fixture request tag mismatch")
        }
        let encryptionKey = hmac(key, Data("ictrl-v1|enc-req".utf8) + nonce)
        return (keystreamXOR(encryptionKey, nonce, ciphertext), nonce, nonceHex, timestamp)
    }

    static func sealResponse(
        _ plaintext: Data,
        key: Data,
        nonceHex: String
    ) throws -> IOSBridgeJSONValue {
        guard let nonce = strictHex(nonceHex, count: nonceCount) else {
            throw TestFailure("fixture nonce invalid")
        }
        let macKey = hmac(key, Data("ictrl-v1|mac".utf8) + nonce)
        let encryptionKey = hmac(key, Data("ictrl-v1|enc-resp".utf8) + nonce)
        let ciphertext = keystreamXOR(encryptionKey, nonce, plaintext)
        let tag = hmac(macKey, Data("resp".utf8) + nonce + ciphertext)
        return .object([
            "v": .int(1),
            "nonce": .string(nonceHex),
            "ct": .string(ciphertext.base64EncodedString()),
            "tag": .string(hex(tag)),
        ])
    }

    static func wrapKey(
        key: Data,
        clientPublicKey: Data
    ) throws -> (devicePublicKey: Data, tokenCiphertext: Data) {
        let devicePrivate = Curve25519.KeyAgreement.PrivateKey()
        let devicePublic = devicePrivate.publicKey.rawRepresentation
        let clientPublic = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: clientPublicKey
        )
        let shared = try devicePrivate.sharedSecretFromKeyAgreement(with: clientPublic)
        let sharedData = shared.withUnsafeBytes { Data($0) }
        let wrapKey = hmac(
            sharedData,
            Data("ictrl-pair".utf8) + clientPublicKey + devicePublic
        )
        let pad = hmac(wrapKey, Data("ictrl-wrap".utf8))
        let ciphertext = Data(zip(key, pad).map { $0 ^ $1 })
        return (devicePublic, ciphertext)
    }

    static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func keystreamXOR(_ key: Data, _ nonce: Data, _ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        var output = Data(count: data.count)
        let input = [UInt8](data)
        var offset = 0
        var counter: UInt32 = 0
        while offset < input.count {
            var bigEndian = counter.bigEndian
            let block = [UInt8](hmac(key, nonce + Data(bytes: &bigEndian, count: 4)))
            let end = min(input.count, offset + block.count)
            for index in offset..<end {
                output[index] = input[index] ^ block[index - offset]
            }
            offset = end
            counter &+= 1
        }
        return output
    }

    static func be64(_ value: UInt64) -> Data {
        var bigEndian = value.bigEndian
        return Data(bytes: &bigEndian, count: 8)
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func strictHex(_ value: String, count: Int) -> Data? {
        guard value.count == count * 2, value == value.lowercased() else { return nil }
        var output = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            output.append(byte)
            index = next
        }
        return output
    }
}

// MARK: - Fixture response builders

func fixtureInfoBody(
    protocolVersion: Int = 1,
    engine: String = "ready",
    capabilities: [String] = ["envelope_v1", "jsonrpc_2.0", "config", "device_info"]
) -> Data {
    IOSBridgeJSONValue.object([
        "product": .string("Floe iOS Bridge"),
        "server_version": .string("1.0.0"),
        "protocol_version": .int(protocolVersion),
        "transport": .string("localhost-first"),
        "lan_enabled": .bool(false),
        "engine": .string(engine),
        "capabilities": .array(capabilities.map(IOSBridgeJSONValue.string)),
        "endpoints": .array([]),
        "note": .string("test"),
    ]).canonicalData()
}

func fixtureError(
    _ status: Int,
    code: String,
    message: String,
    retryAfter: Int? = nil
) -> FixtureResponse {
    var error: [String: IOSBridgeJSONValue] = [
        "code": .string(code),
        "message": .string(message),
    ]
    if let retryAfter {
        error["retry_after"] = .int(retryAfter)
    }
    return FixtureResponse(
        status: status,
        body: IOSBridgeJSONValue.object(["error": .object(error)]).canonicalData()
    )
}

func fixtureParseRPC(
    _ request: FixtureRequest,
    key: Data
) throws -> (method: String, params: [String: IOSBridgeJSONValue], id: IOSBridgeJSONValue, nonceHex: String) {
    guard let envelope = try? IOSBridgeJSONValue.decode(request.body) else {
        throw TestFailure("fixture rpc body is not JSON")
    }
    let opened = try FixtureCrypto.openRequest(envelope, key: key)
    guard let value = try? IOSBridgeJSONValue.decode(opened.plaintext),
          let object = value.objectValue,
          let method = object["method"]?.stringValue,
          let id = object["id"] else {
        throw TestFailure("fixture rpc plaintext is malformed")
    }
    let params = object["params"]?.objectValue ?? [:]
    return (method, params, id, opened.nonceHex)
}

func fixtureRPCResult(
    _ request: FixtureRequest,
    key: Data,
    result: IOSBridgeJSONValue
) throws -> FixtureResponse {
    guard let envelope = try? IOSBridgeJSONValue.decode(request.body) else {
        throw TestFailure("fixture rpc body is not JSON")
    }
    let opened = try FixtureCrypto.openRequest(envelope, key: key)
    guard let value = try? IOSBridgeJSONValue.decode(opened.plaintext),
          let object = value.objectValue,
          let id = object["id"] else {
        throw TestFailure("fixture rpc plaintext is malformed")
    }
    let response = IOSBridgeJSONValue.object([
        "jsonrpc": .string("2.0"),
        "id": id,
        "result": result,
    ])
    let sealed = try FixtureCrypto.sealResponse(
        response.canonicalData(),
        key: key,
        nonceHex: opened.nonceHex
    )
    return FixtureResponse(status: 200, body: sealed.canonicalData())
}

func fixtureRPCError(
    _ request: FixtureRequest,
    key: Data,
    code: Int,
    message: String,
    data: [String: IOSBridgeJSONValue]? = nil
) throws -> FixtureResponse {
    guard let envelope = try? IOSBridgeJSONValue.decode(request.body) else {
        throw TestFailure("fixture rpc body is not JSON")
    }
    let opened = try FixtureCrypto.openRequest(envelope, key: key)
    guard let value = try? IOSBridgeJSONValue.decode(opened.plaintext),
          let object = value.objectValue,
          let id = object["id"] else {
        throw TestFailure("fixture rpc plaintext is malformed")
    }
    var error: [String: IOSBridgeJSONValue] = [
        "code": .int(code),
        "message": .string(message),
    ]
    if let data { error["data"] = .object(data) }
    let response = IOSBridgeJSONValue.object([
        "jsonrpc": .string("2.0"),
        "id": id,
        "error": .object(error),
    ])
    let sealed = try FixtureCrypto.sealResponse(
        response.canonicalData(),
        key: key,
        nonceHex: opened.nonceHex
    )
    return FixtureResponse(status: 200, body: sealed.canonicalData())
}

func fixturePairResponse(
    _ request: FixtureRequest,
    key: Data,
    expireSeconds: Int = 1_702_592_000
) throws -> FixtureResponse {
    guard let object = request.jsonObject,
          let clientName = object["client_name"]?.stringValue,
          let publicBase64 = object["pub"]?.stringValue,
          let clientPublic = Data(base64Encoded: publicBase64, options: []),
          clientPublic.count == 32 else {
        return fixtureError(400, code: "bad_request", message: "fixture pairing body malformed")
    }
    let wrapped = try FixtureCrypto.wrapKey(key: key, clientPublicKey: clientPublic)
    let body = IOSBridgeJSONValue.object([
        "tok": .string(IOSBridgeEnvelope.tokenID(for: key)),
        "client_name": .string(clientName),
        "expires": .int(expireSeconds),
        "pub": .string(wrapped.devicePublicKey.base64EncodedString()),
        "token_ct": .string(FixtureCrypto.hex(wrapped.tokenCiphertext)),
    ]).canonicalData()
    return FixtureResponse(status: 200, body: body)
}

func fixtureConfigResult(
    key: Data,
    engine: String = "ready",
    reason: String? = nil,
    methods: [String] = ["device_info", "page_source", "screenshot", "tap", "type"],
    expiresAt: Int,
    sensitiveInput: Bool = false,
    port: Int = 8200
) -> IOSBridgeJSONValue {
    let tokenID = IOSBridgeEnvelope.tokenID(for: key)
    return .object([
        "port": .int(port),
        "lan_enabled": .bool(false),
        "bonjour_enabled": .bool(false),
        "engine": .object([
            "state": .string(engine),
            "reason": reason.map(IOSBridgeJSONValue.string) ?? .null,
            "supported_methods": .array(methods.map(IOSBridgeJSONValue.string)),
        ]),
        "capabilities": .array(["envelope_v1", "jsonrpc_2.0", "config"].map(IOSBridgeJSONValue.string)),
        "clients": .array([
            .object([
                "client_id": .string(tokenID),
                "client_name": .string("Floe on iPhone"),
                "granted_at": .int(1_700_000_000),
                "last_active_at": .int(1_700_000_000),
                "expires_at": .int(expiresAt),
                "last_address": .string("127.0.0.1"),
                "last_via": .string("local"),
                "sensitive_input_granted": .bool(sensitiveInput),
            ]),
        ]),
        "stopping": .bool(false),
    ])
}
