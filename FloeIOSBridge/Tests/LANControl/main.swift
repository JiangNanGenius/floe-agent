import Darwin
import Foundation
import Network

// A focused macOS host qualification for the encrypted LAN control server.
// It starts the real NWListener/NWConnection path on loopback and uses the same
// pinned iCTRL v1 envelope as the device. No phone, DDI, Xcode or signing is
// involved. The synthetic submit/result closures stand in for the existing
// file dispatchers so this proves transport/auth/replay/fencing behavior, not
// App acceptance.

var checks = 0
var failures = 0

@MainActor func expect(_ condition: @autoclosure () -> Bool,
            _ name: String,
            _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition() {
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name) \(detail())")
    }
}

@MainActor func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ name: String) {
    checks += 1
    if actual == expected {
        print("PASS \(name)")
    } else {
        failures += 1
        print("FAIL \(name) actual=\(actual) expected=\(expected)")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock(); value += 1; lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

final class StartBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var failure: String?
    private let semaphore = DispatchSemaphore(value: 0)

    func markReady() {
        lock.lock(); ready = true; lock.unlock()
        semaphore.signal()
    }

    func markFailed(_ message: String) {
        lock.lock(); failure = message; lock.unlock()
        semaphore.signal()
    }

    func wait(_ timeout: TimeInterval) -> Bool {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return false }
        lock.lock(); defer { lock.unlock() }
        return ready && failure == nil
    }

    var error: String? {
        lock.lock(); defer { lock.unlock() }
        return failure
    }
}

/// Deterministic pause at the sealed-response commit boundary. The hook is
/// one-shot: after `arm()` the next commit attempt signals `reached` and blocks
/// until `releaseResponse()`. The test performs a lifecycle change while the
/// server is paused, then releases it and checks that no stale reply is
/// enqueued.
final class CommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private let reached = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func hook() {
        lock.lock()
        let shouldPause = armed
        if shouldPause { armed = false }
        lock.unlock()
        guard shouldPause else { return }
        reached.signal()
        // Bounded so a broken fixture cannot wedge the server queue forever.
        _ = release.wait(timeout: .now() + 15)
    }

    func waitUntilPaused(_ timeout: TimeInterval) -> Bool {
        reached.wait(timeout: .now() + timeout) == .success
    }

    func releaseResponse() {
        release.signal()
    }
}

/// Thread-safe completion box for a request that is sent while the server is
/// paused. `completed` distinguishes an empty/cancelled reply from a timeout.
final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var didComplete = false
    private let done = DispatchSemaphore(value: 0)

    func complete(_ value: Data?) {
        lock.lock()
        guard !didComplete else { lock.unlock(); return }
        didComplete = true
        data = value
        lock.unlock()
        done.signal()
    }

    func wait(_ timeout: TimeInterval) -> (completed: Bool, data: Data?) {
        _ = done.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return (didComplete, data)
    }
}

final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); lines.append(line); lock.unlock()
    }

    func count(containing needle: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return lines.filter { $0.contains(needle) }.count
    }
}

final class SyntheticDriver: @unchecked Sendable {
    let counter = Counter()
    private let key: Data
    private let lock = NSLock()
    private var seen: [String: String] = [:]
    private var recorded: [BridgeLANControlRequest] = []

    init(key: Data) {
        self.key = key
    }

    var lastRequest: BridgeLANControlRequest? {
        lock.lock(); defer { lock.unlock() }
        return recorded.last
    }

    var recordedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return recorded.count
    }

    func submit(_ request: BridgeLANControlRequest) -> BridgeLANSubmitOutcome {
        let digest = BridgeControlArguments.contentDigest(
            action: request.action, parameters: request.parameters
        )
        lock.lock()
        if let existing = seen[request.id] {
            lock.unlock()
            guard existing == digest else {
                return .rejected(code: "command_replayed",
                                 message: "This command ID was already used with different content.")
            }
            return .accepted(id: request.id, lane: request.lane, action: request.action,
                             generation: request.generation, duplicate: true)
        }
        seen[request.id] = digest
        recorded.append(request)
        lock.unlock()
        counter.increment()
        return .accepted(id: request.id, lane: request.lane, action: request.action,
                         generation: request.generation, duplicate: false)
    }

    func result(_ request: BridgeLANResultRequest) -> BridgeLANCommandResultOutcome {
        if request.id == "late-1" {
            return .late(BridgeLANLateResult(
                status: "ok",
                action: "stop",
                processIdentifier: request.pid,
                generation: request.generation,
                resultingGeneration: request.generation + 1,
                processedAt: "2026-11-01T00:00:00.000Z",
                error: nil
            ))
        }
        if request.id == "pending-1" {
            return .pending
        }
        return .ready(BridgeLANCommandResultPayload(
            status: "ok",
            action: "status",
            processIdentifier: request.pid,
            generation: request.generation,
            resultingGeneration: request.generation,
            processedAt: "2026-11-01T00:00:00.000Z",
            details: [
                "engineRunning": "true",
                "resultingGeneration": "\(request.generation)",
            ],
            error: nil,
            artifact: nil,
            artifactError: nil
        ))
    }
}

final class LoopbackClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "org.floeagent.iosbridge.lan-check.client")
    private let ready = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var output = Data()
    private var didFinish = false
    private let timeout: TimeInterval

    init(port: UInt16, timeout: TimeInterval) {
        self.timeout = timeout
        self.connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            using: .tcp
        )
    }

    func run(request: Data) -> Data? {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state)
        }
        connection.start(queue: queue)
        guard ready.wait(timeout: .now() + timeout) == .success else {
            connection.cancel()
            return nil
        }
        connection.send(content: request, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.finish() }
        })
        receive()
        _ = finished.wait(timeout: .now() + timeout)
        connection.cancel()
        return snapshot()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            ready.signal()
        case .failed, .cancelled:
            ready.signal()
            finish()
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.output.append(data)
                self.lock.unlock()
            }
            if complete || error != nil {
                self.finish()
            } else {
                self.receive()
            }
        }
    }

    private func finish() {
        lock.lock()
        if didFinish {
            lock.unlock()
            return
        }
        didFinish = true
        lock.unlock()
        finished.signal()
    }

    private func snapshot() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return output.isEmpty ? nil : output
    }

    static func send(port: UInt16, request: Data) -> Data? {
        let client = LoopbackClient(port: port, timeout: 4)
        return client.run(request: request)
    }

    static func request(_ method: String,
                        path: String,
                        body: Data? = nil,
                        headers: [String: String] = [:]) -> Data {
        var allHeaders = headers
        allHeaders["Host"] = allHeaders["Host"] ?? "127.0.0.1"
        allHeaders["Content-Length"] = "\(body?.count ?? 0)"
        var head = "\(method) \(path) HTTP/1.1\r\n"
        for key in allHeaders.keys.sorted() {
            head += "\(key): \(allHeaders[key] ?? "")\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        return data
    }
}

struct HTTPResponse {
    var status: Int
    var body: Data
}

func parseHTTP(_ data: Data) -> HTTPResponse? {
    guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
    let head = data.subdata(in: data.startIndex..<separator.lowerBound)
    guard let text = String(data: head, encoding: .utf8) else { return nil }
    guard let first = text.components(separatedBy: "\r\n").first else { return nil }
    let parts = first.split(separator: " ")
    guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
    let body = data.subdata(in: separator.upperBound..<data.endIndex)
    return HTTPResponse(status: status, body: body)
}

func jsonObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func sealedBody(_ inner: [String: Any],
                key: Data,
                timestamp: Int = Int(Date().timeIntervalSince1970)) -> (body: Data, nonceHex: String)? {
    guard let plaintext = try? JSONSerialization.data(
        withJSONObject: inner,
        options: [.sortedKeys, .withoutEscapingSlashes]
    ), let nonce = BridgeLANCrypto.randomBytes(16) else { return nil }
    let envelope = BridgeLANCrypto.sealRequest(
        plaintext,
        key: key,
        nonce: nonce,
        timestamp: timestamp
    )
    guard let body = try? JSONSerialization.data(withJSONObject: envelope) else { return nil }
    return (body, BridgeLANCrypto.hexLowercase(nonce))
}

func openSealed(_ response: HTTPResponse,
                key: Data,
                nonceHex: String) -> [String: Any]? {
    guard response.status == 200,
          let object = jsonObject(response.body),
          let plaintext = try? BridgeLANCrypto.openResponse(
              object, key: key, expectedNonceHex: nonceHex
          ) else {
        return nil
    }
    return jsonObject(plaintext)
}

func runReferenceControllerServer() -> Never {
    let environment = ProcessInfo.processInfo.environment
    guard environment["FLOE_LAN_CONTROL_SERVE"] == "1" else { exit(2) }
    guard let keyHex = environment["FLOE_LAN_CONTROL_KEY_HEX"],
          let key = BridgeLANCrypto.strictHex(keyHex, byteCount: 32) else {
        print("LAN-CONTROL-SERVE missing key")
        exit(2)
    }
    let port = UInt16(environment["FLOE_LAN_CONTROL_PORT"] ?? "47680") ?? 47_680
    let seconds = Double(environment["FLOE_LAN_CONTROL_SECONDS"] ?? "20") ?? 20
    let driver = SyntheticDriver(key: key)
    let server = BridgeLANControlServer()
    let started = StartBox()
    server.setStateChangeHandler { listening, error in
        if listening { started.markReady() } else if let error { started.markFailed(error) }
    }
    do {
        try server.start(BridgeLANControlServer.Runtime(
            port: port,
            key: key,
            state: { BridgeLANCurrentState(pid: 4_242, generation: 7) },
            submit: { driver.submit($0) },
            result: { driver.result($0) },
            log: { print("LAN-CONTROL-SERVE \($0)") }
        ))
    } catch {
        print("LAN-CONTROL-SERVE start failed")
        exit(3)
    }
    guard started.wait(3) else {
        print("LAN-CONTROL-SERVE not ready")
        exit(4)
    }
    print("LAN-CONTROL-SERVE READY \(port)")
    fflush(stdout)
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.1)
    }
    server.stop()
    print("LAN-CONTROL-SERVE STOPPED submits=\(driver.counter.count)")
    exit(0)
}

if ProcessInfo.processInfo.environment["FLOE_LAN_CONTROL_SERVE"] == "1" {
    runReferenceControllerServer()
}

func discoverSession(port: UInt16, key: Data) -> (session: String, pid: Int, generation: Int)? {
    guard let sealed = sealedBody(["v": 1, "kind": "session"], key: key),
          let raw = LoopbackClient.send(
              port: port,
              request: LoopbackClient.request("POST", path: "/v1/session", body: sealed.body)
          ),
          let response = parseHTTP(raw),
          let opened = openSealed(response, key: key, nonceHex: sealed.nonceHex),
          opened["state"] as? String == "session",
          let session = opened["sessionId"] as? String,
          BridgeLANSessionID.isCanonical(session),
          let pid = opened["currentPid"] as? Int,
          let generation = opened["currentGeneration"] as? Int else {
        return nil
    }
    return (session, pid, generation)
}

let key = Data(repeating: 0x5A, count: 32)
let readonlyBearer = BridgeLANControlKey.encode(Data(repeating: 0x11, count: 32))
let driver = SyntheticDriver(key: key)

var server: BridgeLANControlServer?
var selectedPort: UInt16?

for candidate in UInt16(47_666)...UInt16(47_675) {
    let instance = BridgeLANControlServer()
    let box = StartBox()
    instance.setStateChangeHandler { listening, error in
        if listening {
            box.markReady()
        } else if let error {
            box.markFailed(error)
        }
    }
    do {
        try instance.start(BridgeLANControlServer.Runtime(
            port: candidate,
            key: key,
            state: { BridgeLANCurrentState(pid: 4_242, generation: 7) },
            submit: { request in driver.submit(request) },
            result: { request in driver.result(request) },
            log: { _ in }
        ))
    } catch {
        continue
    }
    if box.wait(2) {
        server = instance
        selectedPort = candidate
        break
    }
    instance.stop()
}

guard let server, let port = selectedPort else {
    print("FAIL real LAN server could not bind a loopback port")
    exit(1)
}
print("PASS real LAN server listening on loopback port \(port)")
guard let initial = discoverSession(port: port, key: key) else {
    print("FAIL initial encrypted session discovery")
    server.stop()
    exit(1)
}
let initialSession = initial.session
expectEqual(initial.pid, 4_242, "session discovery returns the current PID")
expectEqual(initial.generation, 7, "session discovery returns the current generation")

func send(_ request: Data) -> HTTPResponse? {
    guard let data = LoopbackClient.send(port: port, request: request) else { return nil }
    return parseHTTP(data)
}

// 1. The legacy read-only bearer has no authority on the control endpoint.
if let response = send(LoopbackClient.request(
    "POST", path: "/v1/control", body: Data("{}".utf8),
    headers: ["Authorization": "Bearer \(readonlyBearer)"]
)) {
    expectEqual(response.status, 401, "readonly bearer cannot authorize control")
    expectEqual(driver.counter.count, 0, "readonly bearer submits nothing")
} else {
    expect(false, "readonly bearer request completed")
}

// 2. A sealed control request is accepted and bound to PID/generation.
let controlInner: [String: Any] = [
    "v": 1,
    "id": "status-1",
    "lane": "host",
    "action": "status",
    "pid": 4_242,
    "generation": 7,
    "session": initialSession,
]
if let sealed = sealedBody(controlInner, key: key),
   let response = send(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body)),
   let opened = openSealed(response, key: key, nonceHex: sealed.nonceHex) {
    expectEqual(opened["state"] as? String, "accepted", "sealed control accepted")
    expectEqual(opened["id"] as? String, "status-1", "sealed control preserves command ID")
    expectEqual(opened["currentPid"] as? Int, 4_242, "sealed control returns current PID")
    expectEqual(opened["currentGeneration"] as? Int, 7, "sealed control returns current generation")
    expectEqual(driver.counter.count, 1, "sealed control submitted exactly once")
} else {
    expect(false, "sealed control round trip")
}

// 3. The exact same envelope is a nonce replay and dispatches nothing.
if let sealed = sealedBody(controlInner, key: key),
   let first = send(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body)),
   let second = send(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body)) {
    expectEqual(first.status, 200, "fresh envelope accepted")
    expectEqual(second.status, 401, "replayed envelope rejected")
    expectEqual(driver.counter.count, 1, "replay did not dispatch a second command")
} else {
    expect(false, "replay fixture completed")
}

// 4. A modified tag is rejected before dispatch and returns only a plain error.
if let sealed = sealedBody(controlInner, key: key),
   let envelope = jsonObject(sealed.body),
   var tag = envelope["tag"] as? String {
    tag = String(tag.dropLast()) + (tag.hasSuffix("0") ? "1" : "0")
    var tampered = envelope
    tampered["tag"] = tag
    if let body = try? JSONSerialization.data(withJSONObject: tampered),
       let response = send(LoopbackClient.request("POST", path: "/v1/control", body: body)) {
        expectEqual(response.status, 401, "tampered envelope rejected")
        expectEqual(driver.counter.count, 1, "tampered envelope submits nothing")
    } else {
        expect(false, "tampered envelope request completed")
    }
} else {
    expect(false, "tampered envelope fixture")
}

// 5. A stale generation is a sealed, non-dispatching error with the live value.
var staleInner = controlInner
staleInner["id"] = "status-old"
staleInner["generation"] = 6
if let sealed = sealedBody(staleInner, key: key),
   let response = send(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body)),
   let opened = openSealed(response, key: key, nonceHex: sealed.nonceHex) {
    expectEqual((opened["error"] as? [String: Any])?["code"] as? String,
                "stale_generation", "stale generation is refused")
    expectEqual(opened["currentGeneration"] as? Int, 7,
                "stale refusal reports the current generation")
    expectEqual(driver.counter.count, 1, "stale generation submits nothing")
} else {
    expect(false, "stale generation round trip")
}

// 6. Result retrieval is authenticated, bound, and returns the synthetic result.
if let sealed = sealedBody(
    ["v": 1, "id": "status-1", "pid": 4_242, "generation": 7,
     "session": initialSession],
    key: key
),
   let response = send(LoopbackClient.request("POST", path: "/v1/result", body: sealed.body)),
   let opened = openSealed(response, key: key, nonceHex: sealed.nonceHex) {
    expectEqual(opened["state"] as? String, "ready", "result retrieval ready")
    let result = opened["result"] as? [String: Any]
    expectEqual(result?["action"] as? String, "status", "result action is bound")
    expectEqual(result?["processIdentifier"] as? Int, 4_242, "result PID is bound")
    expectEqual(result?["generation"] as? Int, 7, "result generation is bound")
    expectEqual(result?["resultingGeneration"] as? Int, 7,
                "result reports the post-action generation")
} else {
    expect(false, "result retrieval round trip")
}

// 7. A late result after a fence is not presented as a current success.
if let sealed = sealedBody(
    ["v": 1, "id": "late-1", "pid": 4_242, "generation": 7,
     "session": initialSession],
    key: key
),
   let response = send(LoopbackClient.request("POST", path: "/v1/result", body: sealed.body)),
   let opened = openSealed(response, key: key, nonceHex: sealed.nonceHex) {
    expectEqual(opened["state"] as? String, "late", "late result state")
    let result = opened["result"] as? [String: Any]
    expectEqual(result?["resultingGeneration"] as? Int, 8,
                "late result reports the resulting generation")
} else {
    expect(false, "late result round trip")
}

// 8. Strict HTTP framing rejects ambiguous bodies before authentication.
if let response = send(Data(
    "POST /v1/control HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}".utf8
)) {
    expectEqual(response.status, 400, "duplicate Content-Length rejected")
}
if let response = send(Data(
    "POST /v1/control HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8
)) {
    expectEqual(response.status, 400, "chunked transfer rejected")
}
if let response = send(Data(
    "POST /v1/control HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8
)) {
    expectEqual(response.status, 400, "missing Host rejected")
}
if let response = send(Data((
    "POST /v1/control HTTP/1.1\r\nHost: x\r\nContent-Length: 999999\r\n\r\n"
).utf8)) {
    expectEqual(response.status, 413, "oversized body rejected")
}
expectEqual(driver.counter.count, 1, "all malformed HTTP requests submit nothing")

// 9. The listener explicitly prohibits cellular while remaining usable on
// loopback (the tests above) and Wi-Fi/Ethernet.
let listenerParameters = BridgeLANControlServer.makeListenerParameters()
expect(listenerParameters.prohibitedInterfaceTypes?.contains(.cellular) == true,
       "LAN listener prohibits cellular")

// 10. A captured, never-dispatched packet from before a disable/rearm is
// refused even though the retained key, PID, generation and clock second are
// identical. The per-arm session is the fence; timestamp is not.
let rearmInner: [String: Any] = [
    "v": 1,
    "id": "status-before-rearm",
    "lane": "host",
    "action": "status",
    "pid": 4_242,
    "generation": 7,
    "session": initialSession,
]
let rearmSecond = Int(Date().timeIntervalSince1970)
let capturedBeforeRearm = sealedBody(
    rearmInner, key: key, timestamp: rearmSecond
)
let futureCapturedBeforeRearm = sealedBody(
    rearmInner, key: key, timestamp: rearmSecond + 60
)
server.stop()
expect(!server.isListening, "server stops cleanly")

guard let capturedBeforeRearm, let futureCapturedBeforeRearm else {
    print("FAIL rearm fixture")
    exit(1)
}
let driver2 = SyntheticDriver(key: key)
let server2 = BridgeLANControlServer()
let box2 = StartBox()
server2.setStateChangeHandler { listening, error in
    if listening { box2.markReady() } else if let error { box2.markFailed(error) }
}
let rearmPort: UInt16 = 47_676
do {
    try server2.start(BridgeLANControlServer.Runtime(
        port: rearmPort,
        key: key,
        state: { BridgeLANCurrentState(pid: 4_242, generation: 7) },
        submit: { driver2.submit($0) },
        result: { driver2.result($0) },
        log: { _ in }
    ))
} catch {
    print("FAIL rearm server start")
    exit(1)
}
guard box2.wait(2) else {
    print("FAIL rearm server readiness")
    exit(1)
}
guard let session2 = discoverSession(port: rearmPort, key: key)?.session else {
    print("FAIL post-rearm session discovery")
    exit(1)
}
let freshRearmInner: [String: Any] = [
    "v": 1,
    "id": "status-after-rearm",
    "lane": "host",
    "action": "status",
    "pid": 4_242,
    "generation": 7,
    "session": session2,
]
func send2(_ request: Data) -> HTTPResponse? {
    guard let data = LoopbackClient.send(port: rearmPort, request: request) else { return nil }
    return parseHTTP(data)
}
if let response = send2(LoopbackClient.request(
    "POST", path: "/v1/control", body: capturedBeforeRearm.body
)), let opened = openSealed(response, key: key, nonceHex: capturedBeforeRearm.nonceHex) {
    expectEqual(response.status, 200, "pre-rearm packet returns a sealed error")
    expectEqual(driver2.counter.count, 0, "pre-rearm packet submits nothing")
    expectEqual((opened["error"] as? [String: Any])?["code"] as? String,
                "session_mismatch", "pre-rearm packet reports the session fence")
} else {
    expect(false, "pre-rearm packet request completed")
}
if let sealed = sealedBody(freshRearmInner, key: key),
   let response = send2(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body)),
   let opened = openSealed(response, key: key, nonceHex: sealed.nonceHex) {
    expectEqual(opened["state"] as? String, "accepted",
                "fresh packet accepted after rearm")
    expectEqual(driver2.counter.count, 1, "fresh packet submits once after rearm")
} else {
    expect(false, "post-rearm fresh packet round trip")
}
// A captured envelope with a future timestamp (+60s, still inside the ±120s
// window) from the previous session must also be refused after rearm.
if let response = send2(LoopbackClient.request(
    "POST", path: "/v1/control", body: futureCapturedBeforeRearm.body
)), let opened = openSealed(response, key: key,
                            nonceHex: futureCapturedBeforeRearm.nonceHex) {
    expectEqual(response.status, 200, "future-dated pre-rearm packet returns a sealed error")
    expectEqual((opened["error"] as? [String: Any])?["code"] as? String,
                "session_mismatch", "future-dated packet reports the session fence")
    expectEqual(driver2.counter.count, 1,
                "future-dated pre-rearm packet submits nothing")
} else {
    expect(false, "future-dated pre-rearm packet request completed")
}

// 11. A fence with the same retained key also rejects a previously captured
// packet, while a fresh request after the fence is accepted.
let capturedBeforeFence = sealedBody(
    freshRearmInner, key: key, timestamp: Int(Date().timeIntervalSince1970)
)
server2.fence()
if let capturedBeforeFence,
   let response = send2(LoopbackClient.request(
       "POST", path: "/v1/control", body: capturedBeforeFence.body
   )),
   let opened = openSealed(response, key: key, nonceHex: capturedBeforeFence.nonceHex) {
    expectEqual(response.status, 200, "pre-fence packet returns a sealed error")
    expectEqual(driver2.counter.count, 1, "pre-fence packet submits nothing")
    expectEqual((opened["error"] as? [String: Any])?["code"] as? String,
                "session_mismatch", "pre-fence packet reports the session fence")
} else {
    expect(false, "fence packet request completed")
}
guard let session2b = discoverSession(port: rearmPort, key: key)?.session else {
    print("FAIL post-fence session discovery")
    exit(1)
}
let afterFenceInner: [String: Any] = [
    "v": 1,
    "id": "status-after-fence",
    "lane": "host",
    "action": "status",
    "pid": 4_242,
    "generation": 7,
    "session": session2b,
]
if let sealed = sealedBody(afterFenceInner, key: key),
   let response = send2(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body)),
   let opened = openSealed(response, key: key, nonceHex: sealed.nonceHex) {
    expectEqual(opened["state"] as? String, "accepted",
                "fresh packet accepted after fence")
    expectEqual(driver2.counter.count, 2, "fresh packet submits once after fence")
} else {
    expect(false, "post-fence fresh packet round trip")
}

// 12. Key rotation invalidates an envelope created under the old key before it
// can submit or receive a sealed response.
let rotatedKey = Data(repeating: 0x77, count: 32)
let oldKeyEnvelope = sealedBody(rearmInner, key: key)
do {
    try server2.replaceKey(rotatedKey)
} catch {
    expect(false, "key rotation accepted")
}
if let oldKeyEnvelope,
   let response = send2(LoopbackClient.request(
       "POST", path: "/v1/control", body: oldKeyEnvelope.body
   )) {
    expectEqual(response.status, 401, "old-key envelope rejected after rotation")
    expectEqual(driver2.counter.count, 2, "old-key envelope submits nothing")
} else {
    expect(false, "old-key envelope request completed")
}
guard let session3 = discoverSession(port: rearmPort, key: rotatedKey)?.session else {
    print("FAIL post-rotation session discovery")
    exit(1)
}
let newKeyInner: [String: Any] = [
    "v": 1,
    "id": "status-after-rotation",
    "lane": "host",
    "action": "status",
    "pid": 4_242,
    "generation": 7,
    "session": session3,
]
if let sealed = sealedBody(newKeyInner, key: rotatedKey),
   let response = send2(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body)),
   let opened = openSealed(response, key: rotatedKey, nonceHex: sealed.nonceHex) {
    expectEqual(opened["state"] as? String, "accepted",
                "new-key packet accepted after rotation")
    expectEqual(driver2.counter.count, 3, "new-key packet submits once")
} else {
    expect(false, "new-key packet round trip")
}

// 13. Accepting an authenticated shutdown closes NEW command admission
// synchronously. A second authenticated command sent immediately afterwards
// must not submit anything; only the ack is permitted to flush.
let shutdownCount = Counter()
let driver3 = SyntheticDriver(key: key)
let server3 = BridgeLANControlServer()
let box3 = StartBox()
server3.setStateChangeHandler { listening, error in
    if listening { box3.markReady() } else if let error { box3.markFailed(error) }
}
let shutdownPort: UInt16 = 47_677
do {
    try server3.start(BridgeLANControlServer.Runtime(
        port: shutdownPort,
        key: key,
        state: { BridgeLANCurrentState(pid: 4_242, generation: 7) },
        submit: { driver3.submit($0) },
        result: { driver3.result($0) },
        shutdown: { _ in shutdownCount.increment() },
        log: { _ in }
    ))
} catch {
    print("FAIL shutdown server start")
    exit(1)
}
guard box3.wait(2) else {
    print("FAIL shutdown server readiness")
    exit(1)
}
guard let session3b = discoverSession(port: shutdownPort, key: key)?.session else {
    print("FAIL shutdown session discovery")
    exit(1)
}
func send3(_ request: Data) -> HTTPResponse? {
    guard let data = LoopbackClient.send(port: shutdownPort, request: request) else { return nil }
    return parseHTTP(data)
}
let missingSessionInner: [String: Any] = [
    "v": 1,
    "id": "missing-session",
    "lane": "host",
    "action": "status",
    "pid": 4_242,
    "generation": 7,
]
if let sealed = sealedBody(missingSessionInner, key: key),
   let response = send3(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body)),
   let opened = openSealed(response, key: key, nonceHex: sealed.nonceHex) {
    expectEqual((opened["error"] as? [String: Any])?["code"] as? String,
                "bad_request", "missing session is refused before submit")
    expectEqual(driver3.counter.count, 0, "missing session submits nothing")
} else {
    expect(false, "missing-session request completed")
}
let wrongSession = String(repeating: "b", count: 32)
var wrongSessionInner = missingSessionInner
wrongSessionInner["id"] = "wrong-session"
wrongSessionInner["session"] = wrongSession
if let sealed = sealedBody(wrongSessionInner, key: key),
   let response = send3(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body)),
   let opened = openSealed(response, key: key, nonceHex: sealed.nonceHex) {
    expectEqual((opened["error"] as? [String: Any])?["code"] as? String,
                "session_mismatch", "wrong session is refused before submit")
    expectEqual(driver3.counter.count, 0, "wrong session submits nothing")
} else {
    expect(false, "wrong-session request completed")
}
let wrongResultSession: [String: Any] = [
    "v": 1,
    "id": "status-1",
    "pid": 4_242,
    "generation": 7,
    "session": wrongSession,
]
if let sealed = sealedBody(wrongResultSession, key: key),
   let response = send3(LoopbackClient.request("POST", path: "/v1/result", body: sealed.body)),
   let opened = openSealed(response, key: key, nonceHex: sealed.nonceHex) {
    expectEqual((opened["error"] as? [String: Any])?["code"] as? String,
                "session_mismatch", "wrong result session cannot fetch a result")
} else {
    expect(false, "wrong result session request completed")
}

let shutdownInner: [String: Any] = [
    "v": 1,
    "id": "shutdown-1",
    "lane": "host",
    "action": "shutdown",
    "pid": 4_242,
    "generation": 7,
    "session": session3b,
]
if let sealed = sealedBody(shutdownInner, key: key),
   let response = send3(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body)),
   let opened = openSealed(response, key: key, nonceHex: sealed.nonceHex) {
    expectEqual(opened["state"] as? String, "accepted", "shutdown accepted")
    expectEqual(opened["final"] as? Bool, true, "shutdown ack is final")
    expectEqual(shutdownCount.count, 1, "shutdown callback ran once")
    expectEqual(driver3.counter.count, 1, "shutdown submission counted once")
} else {
    expect(false, "shutdown ack round trip")
}

let afterShutdown: [String: Any] = [
    "v": 1,
    "id": "start-after-shutdown",
    "lane": "host",
    "action": "start",
    "pid": 4_242,
    "generation": 7,
    "session": session3b,
]
if let sealed = sealedBody(afterShutdown, key: key),
   let response = send3(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body)) {
    expectEqual(response.status, 401, "post-shutdown command is refused")
    if let error = jsonObject(response.body)?["error"] as? [String: Any] {
        expectEqual(error["code"] as? String, "admission_closed",
                    "post-shutdown refusal names the closed admission")
    }
    expectEqual(driver3.counter.count, 1, "post-shutdown command causes zero new submit")
} else {
    expect(false, "post-shutdown command request completed")
}
server3.stop()
expect(!server3.isListening, "shutdown server stops cleanly")

// 14. Final sealed-response commit vs. lifecycle revocation.
//
// `beforeResponseCommit` pauses the real server after the body has been sealed
// and before the final enqueue. A key rotation, fence or stop then completes
// while the server is paused; releasing the seam must drop the already-sealed
// stale response with zero bytes (no old-key result) while a live response
// through the same seam still commits and fresh requests work.
let raceKeyA = Data(repeating: 0xA1, count: 32)
let raceKeyB = Data(repeating: 0xB2, count: 32)
let raceDriver = SyntheticDriver(key: raceKeyA)
let raceGate = CommitGate()
let raceLog = LogBox()
let commitDropMarker = "lan_control_response_commit_dropped"

func raceBody(id: String, session: String) -> [String: Any] {
    [
        "v": 1,
        "id": id,
        "lane": "host",
        "action": "status",
        "pid": 4_242,
        "generation": 7,
        "session": session,
    ]
}

func waitForDropCount(_ expected: Int, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if raceLog.count(containing: commitDropMarker) >= expected { return true }
        Thread.sleep(forTimeInterval: 0.02)
    } while Date() < deadline
    return raceLog.count(containing: commitDropMarker) >= expected
}

var raceServer: BridgeLANControlServer?
var racePort: UInt16?
for candidate in UInt16(47_678)...UInt16(47_687) {
    let instance = BridgeLANControlServer()
    let box = StartBox()
    instance.setStateChangeHandler { listening, error in
        if listening {
            box.markReady()
        } else if let error {
            box.markFailed(error)
        }
    }
    do {
        try instance.start(BridgeLANControlServer.Runtime(
            port: candidate,
            key: raceKeyA,
            state: { BridgeLANCurrentState(pid: 4_242, generation: 7) },
            submit: { raceDriver.submit($0) },
            result: { raceDriver.result($0) },
            log: { raceLog.append($0) },
            beforeResponseCommit: { raceGate.hook() }
        ))
    } catch {
        continue
    }
    if box.wait(2) {
        raceServer = instance
        racePort = candidate
        break
    }
    instance.stop()
}
guard let raceServer, let racePort else {
    print("FAIL race server could not bind a loopback port")
    exit(1)
}
guard let raceSessionA = discoverSession(port: racePort, key: raceKeyA)?.session else {
    print("FAIL race session discovery")
    raceServer.stop()
    exit(1)
}

func sendRace(_ request: Data) -> HTTPResponse? {
    guard let data = LoopbackClient.send(port: racePort, request: request) else { return nil }
    return parseHTTP(data)
}
func sendRaceAsync(_ request: Data) -> ResponseBox {
    let box = ResponseBox()
    DispatchQueue.global().async {
        box.complete(LoopbackClient.send(port: racePort, request: request))
    }
    return box
}

// 14a. Control: the paused path still commits while the arm is unchanged.
if let sealed = sealedBody(raceBody(id: "race-live", session: raceSessionA), key: raceKeyA) {
    raceGate.arm()
    let box = sendRaceAsync(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body))
    expect(raceGate.waitUntilPaused(5), "commit seam pauses a live response")
    expectEqual(raceDriver.counter.count, 1, "live paused response submitted once")
    raceGate.releaseResponse()
    let result = box.wait(6)
    if let raw = result.data, let response = parseHTTP(raw),
       let opened = openSealed(response, key: raceKeyA, nonceHex: sealed.nonceHex) {
        expectEqual(opened["state"] as? String, "accepted",
                    "live response still commits through the paused seam")
    } else {
        expect(false, "live response still commits through the paused seam",
               "completed=\(result.completed)")
    }
    expectEqual(raceLog.count(containing: commitDropMarker), 0,
                "live response is not dropped at the commit boundary")
} else {
    expect(false, "race live fixture")
}

// 14b. Key rotation wins after sealing but before the commit. `replaceKey` does
// not cancel sockets, so the old code would deliver the old-key body here; the
// fixed commit must drop it and leave the connection empty.
if let sealed = sealedBody(raceBody(id: "race-rotate", session: raceSessionA), key: raceKeyA) {
    raceGate.arm()
    let box = sendRaceAsync(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body))
    expect(raceGate.waitUntilPaused(5), "commit seam pauses before key rotation")
    expectEqual(raceDriver.counter.count, 2, "rotation-paused response submitted once")
    do {
        try raceServer.replaceKey(raceKeyB)
        expect(true, "key rotation completes while the sealed response is paused")
    } catch {
        expect(false, "key rotation completes while the sealed response is paused", "\(error)")
    }
    raceGate.releaseResponse()
    expect(waitForDropCount(1, timeout: 3), "rotation drop is recorded at the commit boundary")
    let result = box.wait(6)
    let lateOldKey = result.data.flatMap { raw -> [String: Any]? in
        guard let response = parseHTTP(raw) else { return nil }
        return openSealed(response, key: raceKeyA, nonceHex: sealed.nonceHex)
    }
    expect(result.completed, "rotation-paused connection completes")
    expect(result.data == nil, "sealed old-key response is not committed after rotation",
           "lateBytes=\(result.data?.count ?? 0) oldKeyDecrypt=\(lateOldKey != nil)")
    expectEqual(raceLog.count(containing: commitDropMarker), 1,
                "exactly one rotation drop is recorded")
} else {
    expect(false, "race rotation fixture")
}

guard let raceSessionB = discoverSession(port: racePort, key: raceKeyB)?.session else {
    print("FAIL post-rotation race session discovery")
    raceServer.stop()
    exit(1)
}
if let sealed = sealedBody(raceBody(id: "race-after-rotate", session: raceSessionB),
                           key: raceKeyB),
   let response = sendRace(LoopbackClient.request(
       "POST", path: "/v1/control", body: sealed.body
   )),
   let opened = openSealed(response, key: raceKeyB, nonceHex: sealed.nonceHex) {
    expectEqual(opened["state"] as? String, "accepted",
                "fresh response commits after key rotation")
    expectEqual(raceDriver.counter.count, 3, "fresh response after rotation submitted once")
} else {
    expect(false, "fresh response after rotation round trip")
}

// 14c. Fence wins after sealing but before the commit.
if let sealed = sealedBody(raceBody(id: "race-fence", session: raceSessionB), key: raceKeyB) {
    raceGate.arm()
    let box = sendRaceAsync(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body))
    expect(raceGate.waitUntilPaused(5), "commit seam pauses before fence")
    expectEqual(raceDriver.counter.count, 4, "fence-paused response submitted once")
    raceServer.fence()
    expect(raceServer.isListening, "fence keeps the control listener available")
    raceGate.releaseResponse()
    expect(waitForDropCount(2, timeout: 3), "fence drop is recorded at the commit boundary")
    let result = box.wait(6)
    expect(result.completed, "fence-paused connection completes")
    expect(result.data == nil, "sealed pre-fence response is not committed",
           "lateBytes=\(result.data?.count ?? 0)")
    expectEqual(raceLog.count(containing: commitDropMarker), 2,
                "exactly one fence drop is recorded")
} else {
    expect(false, "race fence fixture")
}

guard let raceSessionB2 = discoverSession(port: racePort, key: raceKeyB)?.session else {
    print("FAIL post-fence race session discovery")
    raceServer.stop()
    exit(1)
}
if let sealed = sealedBody(raceBody(id: "race-after-fence", session: raceSessionB2),
                           key: raceKeyB),
   let response = sendRace(LoopbackClient.request(
       "POST", path: "/v1/control", body: sealed.body
   )),
   let opened = openSealed(response, key: raceKeyB, nonceHex: sealed.nonceHex) {
    expectEqual(opened["state"] as? String, "accepted",
                "fresh response commits after fence")
    expectEqual(raceDriver.counter.count, 5, "fresh response after fence submitted once")
} else {
    expect(false, "fresh response after fence round trip")
}

// 14d. Stop wins after sealing but before the commit.
if let sealed = sealedBody(raceBody(id: "race-stop", session: raceSessionB2), key: raceKeyB) {
    raceGate.arm()
    let box = sendRaceAsync(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body))
    expect(raceGate.waitUntilPaused(5), "commit seam pauses before stop")
    expectEqual(raceDriver.counter.count, 6, "stop-paused response submitted once")
    raceServer.stop()
    expect(!raceServer.isListening, "stop completes while the sealed response is paused")
    raceGate.releaseResponse()
    expect(waitForDropCount(3, timeout: 3), "stop drop is recorded at the commit boundary")
    let result = box.wait(6)
    expect(result.completed, "stop-paused connection completes")
    expect(result.data == nil, "sealed pre-stop response is not committed",
           "lateBytes=\(result.data?.count ?? 0)")
    expectEqual(raceLog.count(containing: commitDropMarker), 3,
                "exactly one stop drop is recorded")
} else {
    expect(false, "race stop fixture")
}

server2.stop()
expect(!server2.isListening, "rearm server stops cleanly")

// 15. Typed generic-action parameters through the same real NWListener path.
let typedKey = Data(repeating: 0x6B, count: 32)
let typedDriver = SyntheticDriver(key: typedKey)
let typedLog = LogBox()
var typedServer: BridgeLANControlServer?
var typedPort: UInt16?
for candidate in UInt16(47_688)...UInt16(47_697) {
    let instance = BridgeLANControlServer()
    let box = StartBox()
    instance.setStateChangeHandler { listening, error in
        if listening { box.markReady() } else if let error { box.markFailed(error) }
    }
    do {
        try instance.start(BridgeLANControlServer.Runtime(
            port: candidate,
            key: typedKey,
            state: { BridgeLANCurrentState(pid: 4_242, generation: 7) },
            submit: { typedDriver.submit($0) },
            result: { typedDriver.result($0) },
            log: { typedLog.append($0) }
        ))
    } catch {
        continue
    }
    if box.wait(2) {
        typedServer = instance
        typedPort = candidate
        break
    }
    instance.stop()
}
guard let typedServer, let typedPort else {
    print("FAIL typed LAN server could not bind a loopback port")
    exit(1)
}
guard let typedSession = discoverSession(port: typedPort, key: typedKey)?.session else {
    print("FAIL typed LAN session discovery")
    typedServer.stop()
    exit(1)
}
func sendTyped(_ request: Data) -> HTTPResponse? {
    guard let data = LoopbackClient.send(port: typedPort, request: request) else { return nil }
    return parseHTTP(data)
}
func typedInner(id: String,
                action: String,
                params: [String: Any],
                session: String = typedSession,
                generation: Int = 7) -> [String: Any] {
    [
        "v": 1,
        "id": id,
        "lane": "engine",
        "action": action,
        "pid": 4_242,
        "generation": generation,
        "session": session,
        "params": params,
    ]
}

let activateParams: [String: Any] = ["bundleIdentifier": "com.apple.Preferences"]
let activateInner = typedInner(id: "typed-activate-1", action: "activate_app",
                               params: activateParams)
if let sealed = sealedBody(activateInner, key: typedKey),
   let response = sendTyped(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body)),
   let opened = openSealed(response, key: typedKey, nonceHex: sealed.nonceHex) {
    expectEqual(opened["state"] as? String, "accepted", "typed activate accepted")
    let expected = BridgeControlArguments.resultDigest(
        action: "activate_app",
        parameters: BridgeControlParameters(bundleIdentifier: "com.apple.Preferences")
    )
    expectEqual(opened["parametersDigest"] as? String, expected,
                "typed activate returns the argument digest")
    let received = typedDriver.lastRequest
    expectEqual(received?.parameters?.bundleIdentifier, "com.apple.Preferences",
                "typed activate carries the bundle identifier")
    expectEqual(typedDriver.counter.count, 1, "typed activate submits once")
} else {
    expect(false, "typed activate round trip")
}

// The same command ID with different arguments is not a duplicate.
var changedActivate = activateInner
changedActivate["params"] = ["bundleIdentifier": "com.apple.mobilesafari"]
if let sealed = sealedBody(changedActivate, key: typedKey),
   let response = sendTyped(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body)),
   let opened = openSealed(response, key: typedKey, nonceHex: sealed.nonceHex) {
    expectEqual((opened["error"] as? [String: Any])?["code"] as? String,
                "command_replayed", "changed typed arguments are not a duplicate")
    expectEqual(typedDriver.counter.count, 1,
                "changed typed arguments submit nothing new")
} else {
    expect(false, "changed typed arguments round trip")
}
if let sealed = sealedBody(activateInner, key: typedKey),
   let response = sendTyped(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body)),
   let opened = openSealed(response, key: typedKey, nonceHex: sealed.nonceHex) {
    expectEqual(opened["state"] as? String, "accepted", "identical typed request is accepted")
    expectEqual(opened["duplicate"] as? Bool, true, "identical typed request is a duplicate")
    expectEqual(typedDriver.counter.count, 1, "identical duplicate submits nothing new")
} else {
    expect(false, "identical typed duplicate round trip")
}

// Text is carried to the driver but never appears in the response or logs.
let typedSecret = "floe-typed-secret-42"
let typeInner = typedInner(id: "typed-text-1", action: "type_text", params: [
    "bundleIdentifier": "com.apple.Preferences",
    "text": typedSecret,
    "identifier": "floe.controlTest.textField",
])
if let sealed = sealedBody(typeInner, key: typedKey),
   let response = sendTyped(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body)),
   let opened = openSealed(response, key: typedKey, nonceHex: sealed.nonceHex) {
    expectEqual(opened["state"] as? String, "accepted", "typed text accepted")
    expectEqual(typedDriver.lastRequest?.parameters?.text, typedSecret,
                "typed text reaches the driver boundary")
    expect(!(opened["parametersDigest"] as? String ?? "").contains(typedSecret),
           "typed text is not echoed in the response digest")
    expectEqual(typedLog.count(containing: typedSecret), 0,
                "typed text is not written to the control log")
    expectEqual(typedDriver.counter.count, 2, "typed text submits once")
} else {
    expect(false, "typed text round trip")
}

// An explicit field label is carried through the same encrypted typed path.
let labelInner = typedInner(id: "typed-label-1", action: "type_text", params: [
    "bundleIdentifier": "com.apple.Preferences",
    "text": "label-fixture",
    "label": "搜索",
])
if let sealed = sealedBody(labelInner, key: typedKey),
   let response = sendTyped(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body)),
   let opened = openSealed(response, key: typedKey, nonceHex: sealed.nonceHex) {
    expectEqual(opened["state"] as? String, "accepted", "typed label selector accepted")
    expectEqual(typedDriver.lastRequest?.parameters?.label, "搜索",
                "typed label selector reaches the driver")
    expectEqual(typedDriver.counter.count, 3, "typed label selector submits once")
} else {
    expect(false, "typed label selector round trip")
}

@MainActor func typedRejected(_ inner: [String: Any], code: String, name: String) {
    guard let sealed = sealedBody(inner, key: typedKey),
          let response = sendTyped(LoopbackClient.request("POST", path: "/v1/control", body: sealed.body)),
          let opened = openSealed(response, key: typedKey, nonceHex: sealed.nonceHex) else {
        expect(false, "\(name) round trip")
        return
    }
    expectEqual((opened["error"] as? [String: Any])?["code"] as? String, code, name)
}

typedRejected(typedInner(id: "typed-missing-bundle-1", action: "tap", params: [
    "normalizedX": 0.5, "normalizedY": 0.5,
]), code: "invalid_bundle_identifier", name: "typed tap requires a bundle")
typedRejected(typedInner(id: "typed-forbidden-1", action: "tap", params: [
    "bundleIdentifier": "com.apple.springboard", "identifier": "home",
]), code: "forbidden_target", name: "typed tap refuses SpringBoard")
typedRejected(typedInner(id: "typed-range-1", action: "tap", params: [
    "bundleIdentifier": "com.apple.Preferences", "normalizedX": 2.0, "normalizedY": 0.5,
]), code: "invalid_coordinates", name: "typed tap refuses out-of-range coordinates")
typedRejected(typedInner(id: "typed-text-large-1", action: "type_text", params: [
    "bundleIdentifier": "com.apple.Preferences",
    "text": String(repeating: "x", count: 4_097),
]), code: "invalid_text", name: "typed text refuses an oversized body")
typedRejected(typedInner(id: "typed-text-two-targets-1", action: "type_text", params: [
    "bundleIdentifier": "com.apple.Preferences",
    "text": "x",
    "identifier": "settings.search",
    "label": "搜索",
]), code: "ambiguous_arguments", name: "typed text refuses two field selectors")
typedRejected([
    "v": 1, "id": "typed-legacy-1", "lane": "engine", "action": "status",
    "pid": 4_242, "generation": 7, "session": typedSession,
    "params": ["bundleIdentifier": "com.apple.Preferences"],
], code: "parameters_not_applicable",
   name: "typed parameters are refused on a legacy action")
typedRejected(typedInner(id: "typed-stale-1", action: "activate_app",
                         params: activateParams, generation: 6),
              code: "stale_generation", name: "stale typed generation is refused")
expectEqual(typedDriver.counter.count, 3,
            "rejected typed requests dispatch nothing")

// Typed arguments survive a fresh arm only with the new session.
let capturedTyped = sealedBody(typedInner(id: "typed-before-rearm", action: "activate_app",
                                          params: activateParams), key: typedKey)
typedServer.stop()
expect(!typedServer.isListening, "typed server stops cleanly")
guard let capturedTyped else {
    print("FAIL typed rearm fixture")
    exit(1)
}
let typedDriver2 = SyntheticDriver(key: typedKey)
let typedServer2 = BridgeLANControlServer()
let typedBox2 = StartBox()
typedServer2.setStateChangeHandler { listening, error in
    if listening { typedBox2.markReady() } else if let error { typedBox2.markFailed(error) }
}
let typedRearmPort: UInt16 = 47_698
do {
    try typedServer2.start(BridgeLANControlServer.Runtime(
        port: typedRearmPort,
        key: typedKey,
        state: { BridgeLANCurrentState(pid: 4_242, generation: 7) },
        submit: { typedDriver2.submit($0) },
        result: { typedDriver2.result($0) },
        log: { _ in }
    ))
} catch {
    print("FAIL typed rearm server start")
    exit(1)
}
guard typedBox2.wait(2) else {
    print("FAIL typed rearm server readiness")
    exit(1)
}
guard let typedSession2 = discoverSession(port: typedRearmPort, key: typedKey)?.session else {
    print("FAIL typed rearm session discovery")
    typedServer2.stop()
    exit(1)
}
if let response = LoopbackClient.send(port: typedRearmPort, request: LoopbackClient.request(
    "POST", path: "/v1/control", body: capturedTyped.body
)).flatMap(parseHTTP),
   let opened = openSealed(response, key: typedKey, nonceHex: capturedTyped.nonceHex) {
    expectEqual((opened["error"] as? [String: Any])?["code"] as? String,
                "session_mismatch", "captured typed packet is refused after rearm")
    expectEqual(typedDriver2.counter.count, 0,
                "captured typed packet dispatches nothing after rearm")
} else {
    expect(false, "captured typed packet request completed")
}
let freshTypedInner = typedInner(id: "typed-after-rearm", action: "activate_app",
                                 params: activateParams, session: typedSession2)
if let sealed = sealedBody(freshTypedInner, key: typedKey),
   let response = LoopbackClient.send(port: typedRearmPort, request: LoopbackClient.request(
       "POST", path: "/v1/control", body: sealed.body
   )).flatMap(parseHTTP),
   let opened = openSealed(response, key: typedKey, nonceHex: sealed.nonceHex) {
    expectEqual(opened["state"] as? String, "accepted",
                "fresh typed request is accepted after rearm")
    expectEqual(typedDriver2.counter.count, 1,
                "fresh typed request submits once after rearm")
} else {
    expect(false, "fresh typed request round trip after rearm")
}
typedServer2.stop()
expect(!typedServer2.isListening, "typed rearm server stops cleanly")

print(failures == 0 ? "LAN-CONTROL PASS checks=\(checks)"
                     : "LAN-CONTROL FAIL checks=\(checks) failures=\(failures)")
if failures != 0 { exit(1) }
