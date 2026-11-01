import Foundation
import Dispatch

var failures = 0
var checks = 0

@MainActor func expect(_ condition: @autoclosure () -> Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
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

// MARK: - SHA-256

expectEqual(
    BridgeAtomicFile.sha256(Data("abc".utf8)),
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    "sha256 abc"
)
expectEqual(
    BridgeAtomicFile.sha256(Data()),
    "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "sha256 empty"
)

// MARK: - Encrypted LAN control primitives (pinned iCTRL v1 contract)

let lanKey = Data(0..<32)
let lanNonce = Data(16..<32)
let lanTimestamp = 1_700_000_000
let lanPlaintext = Data(#"{"action":"status","generation":3,"id":"status-1","lane":"host","pid":1999,"v":1}"#.utf8)
let lanRequest = BridgeLANCrypto.sealRequest(
    lanPlaintext, key: lanKey, nonce: lanNonce, timestamp: lanTimestamp
)
expectEqual(lanRequest["tok"] as? String, "630dcd29", "LAN envelope tok vector")
expectEqual(lanRequest["nonce"] as? String,
            "101112131415161718191a1b1c1d1e1f", "LAN envelope nonce vector")
expectEqual(lanRequest["ct"] as? String,
            "HnNSWFXCpINswCIHVCauQYgMKbKVw4vvgDGvdzuGgl8p9ggP7etA3tp7FPS85mXuVRuERwwk8nyLX2RS6s3CJNfx6TEdyACTHROcWyvPKC3e",
            "LAN envelope ciphertext vector")
expectEqual(lanRequest["tag"] as? String,
            "942d12114ed184ffa6bef38eb060e640ba2384aeb449d6f35d4493821857b3f3",
            "LAN envelope tag vector")

if let parsed = try? BridgeLANCrypto.parse(lanRequest),
   let opened = try? BridgeLANCrypto.open(parsed, key: lanKey) {
    expectEqual(opened, lanPlaintext, "LAN envelope opens to the exact plaintext")
} else {
    expect(false, "LAN envelope known vector opens")
}
if let parsed = try? BridgeLANCrypto.parse(lanRequest) {
    var tampered = lanRequest
    if var tag = tampered["tag"] as? String {
        tag = String(tag.dropLast()) + (tag.hasSuffix("3") ? "4" : "3")
        tampered["tag"] = tag
    }
    if let parsedTampered = try? BridgeLANCrypto.parse(tampered) {
        expect((try? BridgeLANCrypto.open(parsedTampered, key: lanKey)) == nil,
               "LAN envelope rejects a modified tag")
    } else {
        expect(false, "LAN tampered tag parses")
    }
    expect((try? BridgeLANCrypto.open(parsed, key: Data(repeating: 9, count: 32))) == nil,
           "LAN envelope rejects the wrong key")
} else {
    expect(false, "LAN tamper fixture parses")
}

let lanResponsePlaintext = Data(#"{"ok":true,"state":"accepted"}"#.utf8)
let lanResponse = BridgeLANCrypto.sealResponse(
    lanResponsePlaintext, key: lanKey, nonce: lanNonce,
    nonceHex: "101112131415161718191a1b1c1d1e1f"
)
if let responseObject = try? JSONSerialization.jsonObject(with: lanResponse) as? [String: Any],
   let openedResponse = try? BridgeLANCrypto.openResponse(
       responseObject, key: lanKey,
       expectedNonceHex: "101112131415161718191a1b1c1d1e1f"
   ) {
    expectEqual(openedResponse, lanResponsePlaintext, "LAN response round trip")
} else {
    expect(false, "LAN response round trip")
}

let controlKey = BridgeLANControlKey.encode(Data(repeating: 7, count: 32))
expect(BridgeLANControlKey.isCanonical(controlKey), "control key canonical")
expectEqual(BridgeLANControlKey.decode(controlKey)?.count, 32, "control key decodes to 32 bytes")
expect(!BridgeLANControlKey.isCanonical(String(controlKey.dropLast())), "control key rejects 31 bytes")
expect(!BridgeLANControlKey.isCanonical(controlKey + "A"), "control key rejects 33 bytes")

let freshNonce = BridgeLANCrypto.randomBytes(16) ?? Data(repeating: 1, count: 16)
let freshTimestamp = Int(Date().timeIntervalSince1970)
let authRequest = BridgeLANCrypto.sealRequest(
    Data(#"{"v":1,"id":"auth-1","lane":"host","action":"status","pid":1999,"generation":3}"#.utf8),
    key: lanKey, nonce: freshNonce, timestamp: freshTimestamp
)
let authBody = (try? JSONSerialization.data(withJSONObject: authRequest)) ?? Data()
let authState = BridgeLANAuthState(key: lanKey)
if let first = try? authState.open(body: authBody) {
    expectEqual(first.tokenID, "630dcd29", "LAN auth returns the verified token id")
} else {
    expect(false, "LAN auth accepts a fresh envelope")
}
do {
    _ = try authState.open(body: authBody)
    expect(false, "LAN auth rejects a replayed nonce")
} catch let failure as BridgeLANCrypto.Failure {
    expectEqual(failure.code, "nonce_replayed", "LAN auth replay code")
} catch {
    expect(false, "LAN auth replay failure is a crypto failure")
}
let staleTimestamp = Int(Date().timeIntervalSince1970) - 600
let staleRequest = BridgeLANCrypto.sealRequest(
    Data(#"{"v":1,"id":"auth-2","lane":"host","action":"status","pid":1999,"generation":3}"#.utf8),
    key: lanKey, nonce: BridgeLANCrypto.randomBytes(16) ?? Data(repeating: 2, count: 16),
    timestamp: staleTimestamp
)
if let staleBody = try? JSONSerialization.data(withJSONObject: staleRequest) {
    do {
        _ = try authState.open(body: staleBody)
        expect(false, "LAN auth rejects a stale timestamp")
    } catch let failure as BridgeLANCrypto.Failure {
        expectEqual(failure.code, "ts_skew", "LAN auth timestamp code")
    } catch {
        expect(false, "LAN auth stale failure is a crypto failure")
    }
}

let testSession = String(repeating: "a", count: 32)

func lanSealedBody(key: Data, timestamp: Int, nonce: Data) -> Data? {
    let inner: [String: Any] = [
        "v": 1,
        "id": "auth-epoch",
        "lane": "host",
        "action": "status",
        "pid": 1_999,
        "generation": 3,
        "session": testSession,
    ]
    guard let plaintext = try? JSONSerialization.data(
        withJSONObject: inner,
        options: [.sortedKeys, .withoutEscapingSlashes]
    ) else { return nil }
    let envelope = BridgeLANCrypto.sealRequest(
        plaintext, key: key, nonce: nonce, timestamp: timestamp
    )
    return try? JSONSerialization.data(withJSONObject: envelope)
}

// A key rotation between a successful MAC check and the nonce commit must not
// commit a nonce, and must not return an opened request sealed for the old key.
let rotateKeyA = Data(repeating: 0x21, count: 32)
let rotateKeyB = Data(repeating: 0x22, count: 32)
let rotateAuth = BridgeLANAuthState(key: rotateKeyA)
let rotateSessionBefore = rotateAuth.currentSession
let rotateNonce = BridgeLANCrypto.randomBytes(16) ?? Data(repeating: 0x31, count: 16)
if let rotateBody = lanSealedBody(
    key: rotateKeyA,
    timestamp: Int(Date().timeIntervalSince1970),
    nonce: rotateNonce
) {
    do {
        _ = try rotateAuth.open(body: rotateBody) {
            rotateAuth.replaceKey(rotateKeyB)
        }
        expect(false, "LAN auth rejects rotation between MAC and commit")
    } catch let failure as BridgeLANCrypto.Failure {
        expectEqual(failure.code, "auth_stale", "LAN auth rotation window code")
    } catch {
        expect(false, "LAN auth rotation window failure type")
    }
    expectEqual(rotateAuth.revision.eventCount, 0,
                "LAN auth rotation window commits no nonce")
    expect(rotateAuth.currentSession != rotateSessionBefore,
           "LAN auth rotates the session on key replacement")
    expect((try? rotateAuth.open(body: rotateBody)) == nil,
           "LAN auth old key fails after commit-window rotation")
} else {
    expect(false, "LAN auth rotation fixture")
}
if let newKeyBody = lanSealedBody(
    key: rotateKeyB,
    timestamp: Int(Date().timeIntervalSince1970),
    nonce: BridgeLANCrypto.randomBytes(16) ?? Data(repeating: 0x32, count: 16)
), let opened = try? rotateAuth.open(body: newKeyBody) {
    expectEqual(opened.revision.epoch, 2, "LAN auth epoch advances on rotation")
    expect(opened.isCurrent(), "LAN auth new opened request is current")
} else {
    expect(false, "LAN auth new key accepted after rotation")
}

// The per-arm session identifier is the authorization epoch. It rotates on
// arm/fence and key replacement; a captured envelope under the old session must
// not submit or receive a sealed old-key result even on the same clock second.
let armKey = Data(repeating: 0x41, count: 32)
let armedAuth = BridgeLANAuthState(key: armKey)
let initialSession = armedAuth.currentSession
expect(BridgeLANSessionID.isCanonical(initialSession), "LAN auth initial session is canonical")
if let currentBody = lanSealedBody(
    key: armKey, timestamp: Int(Date().timeIntervalSince1970),
    nonce: BridgeLANCrypto.randomBytes(16) ?? Data(repeating: 0x43, count: 16)
), let opened = try? armedAuth.open(body: currentBody) {
    expect(armedAuth.isCurrentSession(initialSession), "LAN auth current session matches")
    expect(opened.isCurrent(), "LAN auth current-arm request is current")
    expect(opened.seal(Data("{}".utf8)) != nil, "LAN auth seals while current")
    armedAuth.arm()
    expect(armedAuth.currentSession != initialSession,
           "LAN auth arm rotates the session")
    expect(!armedAuth.isCurrentSession(initialSession),
           "LAN auth old session is no longer current")
    expect(!opened.isCurrent(), "LAN auth arm invalidates an opened request")
    expect(opened.seal(Data("{}".utf8)) == nil,
           "LAN auth old-key seal is refused after arm")
    expectEqual(armedAuth.revision.eventCount, 0,
                "LAN auth arm resets the event watermark")
} else {
    expect(false, "LAN auth current-arm fixture")
}
if let discovery = try? BridgeLANRequestDecoder.discovery(
    Data(#"{"kind":"session","v":1}"#.utf8)
) {
    expectEqual(discovery.version, 1, "LAN discovery decodes the session request")
} else {
    expect(false, "LAN discovery decodes the session request")
}
expect((try? BridgeLANRequestDecoder.discovery(
    Data(#"{"kind":"status","v":1}"#.utf8)
)) == nil, "LAN discovery rejects another kind")

// MARK: - Strict HTTP framing

func lanHTTP(_ text: String) -> Data { Data(text.utf8) }
switch BridgeHTTPParser.inspect(lanHTTP("POST /v1/control HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}")) {
case .ready(let head, let body):
    expectEqual(head.path, "/v1/control", "HTTP parser accepts a complete request")
    expectEqual(body, Data("{}".utf8), "HTTP parser returns the exact body")
default:
    expect(false, "HTTP parser complete request")
}
switch BridgeHTTPParser.inspect(lanHTTP("POST /v1/control HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n")) {
case .incomplete:
    expect(true, "HTTP parser waits for the declared body")
default:
    expect(false, "HTTP parser incomplete body")
}
switch BridgeHTTPParser.inspect(lanHTTP("POST /v1/control HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}")) {
case .invalid(let status, let code):
    expectEqual(status, 400, "HTTP parser duplicate content length status")
    expectEqual(code, "duplicate_content_length", "HTTP parser duplicate content length code")
default:
    expect(false, "HTTP parser duplicate content length")
}
switch BridgeHTTPParser.inspect(lanHTTP("POST /v1/control HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n")) {
case .invalid(let status, _):
    expectEqual(status, 400, "HTTP parser rejects chunked transfer")
default:
    expect(false, "HTTP parser chunked rejection")
}
switch BridgeHTTPParser.inspect(lanHTTP("POST /v1/control HTTP/1.1\r\nContent-Length: 0\r\n\r\n")) {
case .invalid(_, let code):
    expectEqual(code, "missing_host", "HTTP parser requires Host")
default:
    expect(false, "HTTP parser missing Host")
}
switch BridgeHTTPParser.inspect(lanHTTP("POST /v1/control HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\n\r\n{}X")) {
case .invalid(_, let code):
    expectEqual(code, "unexpected_trailing_bytes", "HTTP parser rejects overread")
default:
    expect(false, "HTTP parser overread rejection")
}
switch BridgeHTTPParser.inspect(lanHTTP("GET /v1/control HTTP/1.1\r\nHost: x\r\n\r\n")) {
case .ready(let head, _):
    expectEqual(head.method, "GET", "HTTP parser keeps GET for route-level 405")
default:
    expect(false, "HTTP parser GET framing")
}

// MARK: - LAN policy, ledger and artifact confinement

expect(BridgeLANControlArmPolicy.shouldDisarm(
    controlEnabled: true, serverStarted: false, listening: false
), "Stop disarms an owner-enabled idle control preference")
expect(BridgeLANControlArmPolicy.shouldDisarm(
    controlEnabled: false, serverStarted: true, listening: true
), "Stop disarms a started control listener")
expect(!BridgeLANControlArmPolicy.shouldDisarm(
    controlEnabled: false, serverStarted: false, listening: false
), "Stop leaves an already-disarmed control entrance alone")

let hostRequest = BridgeLANControlRequest(
    id: "status-1", lane: .host, action: "status", pid: 1999, generation: 3,
    session: testSession
)
expect(BridgeLANControlPolicy.validate(hostRequest) == nil, "LAN host status accepted")
expect(BridgeLANControlPolicy.validate(
    BridgeLANControlRequest(id: "shot-1", lane: .host, action: "screenshot",
                           pid: 1999, generation: 3, session: testSession)
) != nil, "LAN host rejects engine-only action")
expect(BridgeLANControlPolicy.validate(
    BridgeLANControlRequest(id: "stop-1", lane: .engine, action: "stop_engine",
                           pid: 1999, generation: 3, session: testSession)
) == nil, "LAN engine stop accepted")
expect(BridgeLANControlPolicy.validate(
    BridgeLANControlRequest(id: "remove-1", lane: .host, action: "remove_ddi",
                           pid: 1999, generation: 3, session: testSession)
) != nil, "LAN host rejects DDI removal")
expect(BridgeLANControlPolicy.validate(
    BridgeLANControlRequest(id: "a/b", lane: .host, action: "status",
                           pid: 1999, generation: 3, session: testSession)
) != nil, "LAN rejects a non-canonical command ID")

var lanLedger = BridgeLANCommandLedger(maxRecords: 8, commandTTL: 60)
if case .accepted(let firstRecord) = lanLedger.submit(hostRequest) {
    expectEqual(firstRecord.id, "status-1", "LAN ledger accepted record identity")
    expectEqual(firstRecord.generation, 3, "LAN ledger binds the request generation")
} else {
    expect(false, "LAN ledger accepted record identity")
}
switch lanLedger.submit(hostRequest) {
case .duplicate(let record):
    expectEqual(record.id, "status-1", "LAN ledger duplicate is idempotent")
default:
    expect(false, "LAN ledger duplicate")
}
let conflicting = BridgeLANControlRequest(
    id: "status-1", lane: .host, action: "start", pid: 1999, generation: 3,
    session: testSession
)
if case .replayed = lanLedger.submit(conflicting) {
    expect(true, "LAN ledger rejects a conflicting reuse")
} else {
    expect(false, "LAN ledger conflicting reuse")
}
let ledgerURL = URL(fileURLWithPath: "/tmp/lan-ledger-command.json")
_ = lanLedger.markIssued(id: "status-1", fileURL: ledgerURL)
let fencedRecords = lanLedger.fence(reason: "stop")
expectEqual(fencedRecords.count, 1, "LAN ledger fences an issued command")
if case .fenced = lanLedger.disposition(id: "status-1", pid: 1999, generation: 3,
                                        session: testSession, hasResult: false) {
    expect(true, "LAN ledger fenced disposition")
} else {
    expect(false, "LAN ledger fenced disposition")
}
if case .late = lanLedger.disposition(id: "status-1", pid: 1999, generation: 3,
                                      session: testSession, hasResult: true) {
    expect(true, "LAN ledger late result after fence")
} else {
    expect(false, "LAN ledger late result after fence")
}
if case .unknown = lanLedger.disposition(id: "status-1", pid: 2000, generation: 3,
                                         session: testSession, hasResult: true) {
    expect(true, "LAN ledger binds PID")
} else {
    expect(false, "LAN ledger PID binding")
}
if case .sessionMismatch = lanLedger.disposition(
    id: "status-1", pid: 1999, generation: 3,
    session: String(repeating: "b", count: 32), hasResult: true
) {
    expect(true, "LAN ledger binds the session before artifact access")
} else {
    expect(false, "LAN ledger session binding")
}

func lanResult(action: String, status: String, details: [String: String]) -> BridgeCommandResult {
    BridgeCommandResult(id: "shot-1", action: action, status: status,
                        authoredBy: "check", processIdentifier: 1999,
                        generation: 3, details: details)
}
expectEqual(BridgeLANArtifactPolicy.safeScreenshotFileName(
    commandID: "shot-1",
    result: lanResult(action: "screenshot", status: "ok",
                      details: ["screenshotFile": "screenshot-shot-1-1700000000123.png"])
), "screenshot-shot-1-1700000000123.png", "LAN artifact accepts the owned name")
expect(BridgeLANArtifactPolicy.safeScreenshotFileName(
    commandID: "shot-1",
    result: lanResult(action: "screenshot", status: "ok",
                      details: ["screenshotFile": "../secret.png"])
) == nil, "LAN artifact rejects traversal")
expect(BridgeLANArtifactPolicy.safeScreenshotFileName(
    commandID: "shot-1",
    result: lanResult(action: "status", status: "ok",
                      details: ["screenshotFile": "screenshot-shot-1-1700000000123.png"])
) == nil, "LAN artifact requires the screenshot action")

let installLike = BridgeLANControlKey.encode(Data(repeating: 3, count: 32))
let sameKeyCommand = BridgeCommandEnvelope(
    id: "configure-1", action: "configure_recovery", pid: 1999,
    token: installLike, controlKey: installLike
)
expectEqual(BridgeCommandPolicy.validate(
    sameKeyCommand, lane: .host, expectedPid: 1999, expectedToken: installLike
), .controlKeyMatchesInstallToken, "configure_recovery rejects the diagnostics token as control key")
let distinctKeyCommand = BridgeCommandEnvelope(
    id: "configure-2", action: "configure_recovery", pid: 1999,
    token: installLike, controlKey: controlKey
)
expectEqual(BridgeCommandPolicy.validate(
    distinctKeyCommand, lane: .host, expectedPid: 1999, expectedToken: installLike
), .accepted, "configure_recovery accepts a distinct canonical control key")
let legacyEnvelope = BridgeCommandEnvelope(
    id: "legacy-1", action: "status", pid: 1999, token: installLike
)
expect(legacyEnvelope.controlEnabled == nil && legacyEnvelope.controlKey == nil,
       "legacy envelope keeps optional control fields absent")

// MARK: - Packet reflector

let local = BridgeTransport.interfaceAddressValue
let peer = BridgeTransport.peerAddressValue

var reflector = BridgeIPv4Reflector()
let forward = BridgeIPv4Reflector.makePacket(source: local, destination: peer)
expect(BridgeIPv4Reflector.headerChecksumIsValid(forward, headerLength: 20), "fixture header checksum valid")
switch reflector.reflect(forward) {
case .reflected(let bytes):
    expectEqual(BridgeIPv4Reflector.readUInt32(bytes, at: 12), peer, "forward reflected source becomes peer")
    expectEqual(BridgeIPv4Reflector.readUInt32(bytes, at: 16), local, "forward reflected destination becomes local")
    expect(BridgeIPv4Reflector.headerChecksumIsValid(bytes, headerLength: 20), "forward reflected checksum valid")
    expectEqual(bytes.count, forward.count, "forward reflection length preserved")
case .rejected(let reason):
    expect(false, "forward reflection", "\(reason)")
}

let reverse = BridgeIPv4Reflector.makePacket(source: peer, destination: local)
switch reflector.reflect(reverse) {
case .reflected(let bytes):
    expectEqual(BridgeIPv4Reflector.readUInt32(bytes, at: 12), local, "reverse reflected source becomes local")
    expectEqual(BridgeIPv4Reflector.readUInt32(bytes, at: 16), peer, "reverse reflected destination becomes peer")
case .rejected(let reason):
    expect(false, "reverse reflection", "\(reason)")
}

expectEqual(reflector.counters.received, 2, "counter received")
expectEqual(reflector.counters.reflected, 2, "counter reflected")

var short = forward
short.removeLast()
if case .rejected(let reason) = reflector.reflect(short) {
    expectEqual(reason, .lengthMismatch, "totalLength mismatch rejected")
} else { expect(false, "totalLength mismatch rejected") }

var ipv6 = [UInt8](repeating: 0, count: 40)
ipv6[0] = 0x60
if case .rejected(let reason) = reflector.reflect(ipv6) {
    expectEqual(reason, .notIPv4, "IPv6 rejected")
} else { expect(false, "IPv6 rejected") }

if case .rejected(let reason) = reflector.reflect(Array(repeating: 0, count: 10)) {
    expectEqual(reason, .truncatedHeader, "truncated header rejected")
} else { expect(false, "truncated header rejected") }

var badIHL = forward
badIHL[0] = 0x44
if case .rejected(let reason) = reflector.reflect(badIHL) {
    expectEqual(reason, .invalidHeaderLength, "IHL below 5 rejected")
} else { expect(false, "IHL below 5 rejected") }

let fragment = BridgeIPv4Reflector.makePacket(source: local, destination: peer, flagsAndFragment: 0x2000)
if case .rejected(let reason) = reflector.reflect(fragment) {
    expectEqual(reason, .fragmented, "MF fragment rejected")
} else { expect(false, "MF fragment rejected") }

let foreign = BridgeIPv4Reflector.makePacket(source: 0x0808_0808, destination: peer)
if case .rejected(let reason) = reflector.reflect(foreign) {
    expectEqual(reason, .unexpectedAddresses, "unexpected address rejected")
} else { expect(false, "unexpected address rejected") }

var badChecksum = forward
badChecksum[10] ^= 0xFF
if case .rejected(let reason) = reflector.reflect(badChecksum) {
    expectEqual(reason, .invalidHeaderChecksum, "bad header checksum rejected")
} else { expect(false, "bad header checksum rejected") }

// IPv4 options: 24-byte header, total length 44.
var optionsPacket = [UInt8](repeating: 0, count: 44)
optionsPacket[0] = 0x46
optionsPacket[2] = 0
optionsPacket[3] = 44
optionsPacket[6] = 0x40
optionsPacket[8] = 64
optionsPacket[9] = 6
BridgeIPv4Reflector.writeUInt32(local, into: &optionsPacket, at: 12)
BridgeIPv4Reflector.writeUInt32(peer, into: &optionsPacket, at: 16)
let optionsChecksum = BridgeIPv4Reflector.internetChecksum(optionsPacket, range: 0..<24)
optionsPacket[10] = UInt8(optionsChecksum >> 8)
optionsPacket[11] = UInt8(optionsChecksum & 0xFF)
switch reflector.reflect(optionsPacket) {
case .reflected(let bytes):
    expectEqual(bytes[0], 0x46, "IHL options preserved")
    expect(BridgeIPv4Reflector.headerChecksumIsValid(bytes, headerLength: 24), "options checksum valid")
case .rejected(let reason):
    expect(false, "options packet reflection", "\(reason)")
}

// MARK: - Lifecycle and generation fences

var lifecycle = BridgeLifecycle(hostPid: 4242)
expectEqual(lifecycle.snapshot.phase, .idle, "lifecycle starts idle")
let first = lifecycle.beginStart(trigger: "self-check")
expect(lifecycle.isCurrent(first), "fresh generation is current")
expect(lifecycle.markBootstrapDispatched(first), "bootstrap dispatch accepted")
expect(!lifecycle.markBootstrapDispatched(first), "second dispatch refused")
expect(lifecycle.noteEngineEntry(first, pid: 4242, testMethod: "testBridgeEngineLoop", hostPid: 4242), "engine entry accepted")
expectEqual(lifecycle.snapshot.phase, .ready, "phase ready after entry")
expect(lifecycle.acceptsEngineCommands, "engine accepts commands")

expect(lifecycle.requestEngineStop(reason: "self-check stop"), "engine stop accepted")
expectEqual(lifecycle.snapshot.phase, .stopped, "phase stopped")
expect(lifecycle.snapshot.engineEntryObserved, "driver entry retained after stop")
expect(!lifecycle.acceptsEngineCommands, "commands closed after stop")
expectEqual(lifecycle.requestEngineResume(), .resumed, "engine resume accepted")
expectEqual(lifecycle.snapshot.phase, .ready, "phase ready after resume")
expect(lifecycle.acceptsEngineCommands, "commands reopened after resume")

let beforeFence = lifecycle.snapshot.generation
let fenced = lifecycle.fence(reason: "self-check fence")
expect(fenced != beforeFence, "fence increments generation")
expect(!lifecycle.isCurrent(beforeFence), "old generation dead after fence")
expect(!lifecycle.markBootstrapDispatched(beforeFence), "old generation cannot dispatch")
expect(!lifecycle.noteEngineEntry(beforeFence, pid: 4242, testMethod: "late", hostPid: 4242), "late entry rejected")

var preEntry = BridgeLifecycle(hostPid: 7)
let pending = preEntry.beginStart(trigger: "pre-entry-stop")
expect(preEntry.markBootstrapDispatched(pending), "pre-entry dispatch")
let generationBeforeStop = preEntry.snapshot.generation
expect(preEntry.requestEngineStop(reason: "stop-before-entry"), "pre-entry stop accepted")
expect(preEntry.snapshot.generation != generationBeforeStop, "pre-entry stop fences generation")
expect(!preEntry.snapshot.serviceRunning, "pre-entry stop closes service")
expect(preEntry.noteEngineEntry(pending, pid: 7, testMethod: "late", hostPid: 7),
       "late real entry after stop records initialized driver")
expect(!preEntry.snapshot.engineRunning, "late entry does not re-enable stopped service")
expectEqual(preEntry.snapshot.phase, .stopped, "late entry keeps stopped phase")
expect(!preEntry.acceptsEngineCommands, "late entry does not open commands")
expect(preEntry.snapshot.engineEntryObserved, "late entry records entry")
expectEqual(preEntry.requestEngineResume(), .resumed, "later Start reuses late-initialized driver")
expectEqual(preEntry.snapshot.phase, .ready, "resume after late entry ready")
expect(preEntry.acceptsEngineCommands, "commands reopen after late-entry resume")
expect(!preEntry.noteEngineEntry(pending + 1000, pid: 7, testMethod: "stale", hostPid: 7),
       "entry from the wrong dispatch generation rejected")

var pendingRestart = BridgeLifecycle(hostPid: 9)
let pendingGeneration = pendingRestart.beginStart(trigger: "pending")
expect(pendingRestart.markBootstrapDispatched(pendingGeneration), "pending restart dispatch")
expect(pendingRestart.requestEngineStop(reason: "stop-during-init"), "stop during initialization accepted")
let restartDecision = pendingRestart.requestStart(trigger: "start-while-pending")
if case .waitingForExistingBootstrap(let waitingGeneration) = restartDecision {
    expect(waitingGeneration != pendingGeneration, "restart uses a new service generation")
    expect(pendingRestart.snapshot.serviceRunning, "restart re-enables service while initializer pending")
    expect(pendingRestart.noteEngineEntry(pendingGeneration, pid: 9, testMethod: "late-entry", hostPid: 9),
           "pending initializer entry accepted after restart")
    expectEqual(pendingRestart.snapshot.phase, .ready, "pending initializer promotes re-enabled service")
    expect(pendingRestart.acceptsEngineCommands, "pending initializer commands open after entry")
} else {
    expect(false, "start while bootstrap pending waits instead of refusing", "\(restartDecision)")
}

// MARK: - Terminal post-dispatch faults

var terminal = BridgeLifecycle(hostPid: 5151)
let terminalGeneration = terminal.beginStart(trigger: "terminal")
expect(terminal.markBootstrapDispatched(terminalGeneration), "terminal fixture dispatch")
expect(terminal.failTerminal(terminalGeneration, code: "engine-entry-timeout", message: "no entry"),
       "post-dispatch timeout latches terminal fault")
expect(terminal.snapshot.terminalFault, "terminal fault flag set")
expectEqual(terminal.snapshot.errorCode, "engine-entry-timeout", "terminal fault code retained")
expect(terminal.reenableServiceForPendingBootstrap(reason: "after-fault") == nil,
       "terminal fault cannot be re-armed into another wait")
expectEqual(terminal.requestStart(trigger: "after-terminal"),
            .reopenRequired(code: "engine-entry-timeout"),
            "Start after terminal fault requires reopen")
expectEqual(terminal.requestEngineResume(),
            .reopenRequired(code: "engine-entry-timeout"),
            "Resume after terminal fault requires reopen")
expect(terminal.requestEngineStop(reason: "stop-after-terminal"), "Stop accepted after terminal fault")
expect(terminal.snapshot.terminalFault, "Stop does not clear terminal fault")
expectEqual(terminal.snapshot.phase, .failed, "Stop keeps the faulted phase")
expectEqual(terminal.requestStart(trigger: "after-stop"),
            .reopenRequired(code: "engine-entry-timeout"),
            "Start remains blocked after Stop")
expect(!terminal.noteEngineEntry(terminalGeneration, pid: 5151, testMethod: "late", hostPid: 5151),
       "late entry is not accepted as ready after terminal fault")
expect(terminal.snapshot.engineEntryObserved, "late entry retained only as diagnostic state")
expect(!terminal.snapshot.engineRunning, "late entry does not run the faulted service")
expectEqual(terminal.requestEngineResume(),
            .reopenRequired(code: "engine-entry-timeout"),
            "late entry cannot reopen the faulted service")
let terminalGenerationBeforeBegin = terminal.snapshot.generation
expectEqual(terminal.beginStart(trigger: "forced-restart"), terminalGenerationBeforeBegin,
            "beginStart refuses to reset a terminal fault")
expect(terminal.snapshot.terminalFault, "beginStart does not clear terminal fault")

var engineFault = BridgeLifecycle(hostPid: 6161)
let engineFaultGeneration = engineFault.beginStart(trigger: "engine-fault")
expect(engineFault.markBootstrapDispatched(engineFaultGeneration), "engine fault fixture dispatch")
expect(engineFault.noteEngineEntry(engineFaultGeneration, pid: 6161, testMethod: "loop", hostPid: 6161),
       "engine fault fixture entry")
expectEqual(engineFault.snapshot.phase, .ready, "engine fault fixture ready")
expect(engineFault.noteEngineFailure(pid: 6161, code: "engine-halted", message: "engine loop failed"),
       "engine failure latches terminal fault")
expect(engineFault.snapshot.terminalFault, "engine failure flag set")
expectEqual(engineFault.requestEngineResume(),
            .reopenRequired(code: "engine-halted"),
            "engine failure Resume requires reopen")
expectEqual(engineFault.requestStart(trigger: "after-engine-fault"),
            .reopenRequired(code: "engine-halted"),
            "engine failure Start requires reopen")
expect(!engineFault.noteEngineFailure(pid: 9999, code: "foreign", message: "wrong pid"),
       "engine failure from another PID rejected")

var retryable = BridgeLifecycle(hostPid: 7171)
let retryableGeneration = retryable.beginStart(trigger: "retry")
expect(retryable.fail(retryableGeneration, code: "ddi-download-failed", message: "retry"),
       "pre-bootstrap failure recorded")
expect(!retryable.snapshot.terminalFault, "pre-bootstrap DDI failure stays retryable")
if case .started(let retryNextGeneration) = retryable.requestStart(trigger: "retry-again") {
    expect(retryNextGeneration != retryableGeneration, "retry uses a new generation")
    expect(retryable.snapshot.serviceRunning, "retry re-enables the service")
    expectEqual(retryable.snapshot.phase, .preparing, "retry restarts preparation")
} else {
    expect(false, "pre-bootstrap DDI failure can retry")
}

var idleStop = BridgeLifecycle(hostPid: 10)
expect(!idleStop.requestEngineStop(reason: "idle"), "idle stop reports no work")
expectEqual(idleStop.snapshot.phase, .idle, "idle stop does not invent stopped state")

var wrongPid = BridgeLifecycle(hostPid: 11)
let wrongGeneration = wrongPid.beginStart(trigger: "pid")
_ = wrongPid.markBootstrapDispatched(wrongGeneration)
expect(!wrongPid.noteEngineEntry(wrongGeneration, pid: 12, testMethod: "wrong", hostPid: 11), "entry from another PID rejected")

// MARK: - Tokens and command policy

expect(BridgeInstallToken.constantTimeEquals("abc123", "abc123"), "constant-time token match")
expect(!BridgeInstallToken.constantTimeEquals("abc124", "abc123"), "constant-time token mismatch")
expect(!BridgeInstallToken.constantTimeEquals("abc12", "abc123"), "constant-time token length mismatch")
expect(!BridgeInstallToken.constantTimeEquals("", ""), "empty token rejected")

let command = BridgeCommandEnvelope(id: "cmd-1", action: "start", pid: 99, token: "secret")
expectEqual(
    BridgeCommandPolicy.validate(command, lane: .host, expectedPid: 99, expectedToken: "secret"),
    .accepted,
    "host command accepted"
)
expectEqual(
    BridgeCommandPolicy.validate(command, lane: .host, expectedPid: 98, expectedToken: "secret"),
    .pidMismatch,
    "host command pid mismatch"
)
expectEqual(
    BridgeCommandPolicy.validate(command, lane: .host, expectedPid: 99, expectedToken: "wrong"),
    .invalidToken,
    "host command token rejected"
)
let engineActionAsHost = BridgeCommandEnvelope(id: "cmd-2", action: "screenshot", pid: 99, token: "secret")
expectEqual(
    BridgeCommandPolicy.validate(engineActionAsHost, lane: .host, expectedPid: 99, expectedToken: "secret"),
    .unsupportedAction,
    "lane action separation"
)
expectEqual(BridgeAtomicFile.safeIdentifier("a/b c"), "a_b_c", "unsafe identifier sanitized")

// MARK: - Synthetic token shape, rotation policy and lane separation
// These checks use deterministic/random non-credential values only. They do
// not read or write the prototype Keychain item.

let canonicalZeroToken = String(repeating: "A", count: 43)
expectEqual(canonicalZeroToken.utf8.count, BridgeInstallToken.canonicalTokenLength,
            "canonical token length is 43 bytes")
expect(BridgeInstallToken.isCanonical(canonicalZeroToken), "canonical zero-byte token accepted")
expect(!BridgeInstallToken.isCanonical(String(repeating: "A", count: 42)), "42-byte token rejected")
expect(!BridgeInstallToken.isCanonical(String(repeating: "A", count: 44)), "44-byte token rejected")
expect(!BridgeInstallToken.isCanonical(String(repeating: "A", count: 42) + "="), "padded token rejected")
expect(!BridgeInstallToken.isCanonical(String(repeating: "A", count: 42) + "+"), "base64 plus rejected")
expect(!BridgeInstallToken.isCanonical(String(repeating: "A", count: 42) + "/"), "base64 slash rejected")
expect(!BridgeInstallToken.isCanonical(String(repeating: "A", count: 42) + "!"), "non-alphabet token rejected")
expect(!BridgeInstallToken.isCanonical(String(repeating: "A", count: 42) + "B"),
       "non-canonical trailing bits rejected")
expect(!BridgeInstallToken.isCanonical(""), "empty token rejected")

let generatedToken = try! BridgeInstallToken.generate()
expect(BridgeInstallToken.isCanonical(generatedToken), "generated 32-byte token is canonical")
expectEqual(generatedToken.utf8.count, BridgeInstallToken.canonicalTokenLength,
            "generated token length is 43 bytes")

do {
    let accepted = try BridgeInstallToken.validateReplacement(generatedToken, current: canonicalZeroToken)
    expect(accepted == generatedToken, "different canonical replacement accepted")
} catch {
    expect(false, "different canonical replacement accepted", "unexpected error")
}
do {
    let accepted = try BridgeInstallToken.validateReplacement(canonicalZeroToken, current: nil)
    expect(accepted == canonicalZeroToken, "first-install replacement accepted")
} catch {
    expect(false, "first-install replacement accepted", "unexpected error")
}
do {
    _ = try BridgeInstallToken.validateReplacement("not-a-canonical-token", current: canonicalZeroToken)
    expect(false, "malformed replacement rejected")
} catch BridgeInstallToken.RotationError.invalidReplacement {
    expect(true, "malformed replacement rejected")
} catch {
    expect(false, "malformed replacement rejected", "wrong error")
}
do {
    _ = try BridgeInstallToken.validateReplacement(canonicalZeroToken, current: canonicalZeroToken)
    expect(false, "unchanged replacement rejected")
} catch BridgeInstallToken.RotationError.unchangedReplacement {
    expect(true, "unchanged replacement rejected")
} catch {
    expect(false, "unchanged replacement rejected", "wrong error")
}

expect(BridgeCommandPolicy.hostActions.contains("rotate_token"), "rotation is a host action")
expect(!BridgeCommandPolicy.engineActions.contains("rotate_token"), "rotation is not an engine action")
expect(BridgeCommandPolicy.hostActions.contains("remove_ddi"), "DDI removal is a host action")
expect(!BridgeCommandPolicy.engineActions.contains("remove_ddi"), "DDI removal is not an engine action")

let rotateWithReplacement = BridgeCommandEnvelope(
    id: "cmd-rotate-1",
    action: "rotate_token",
    pid: 99,
    token: canonicalZeroToken,
    replacementToken: generatedToken
)
expectEqual(
    BridgeCommandPolicy.validate(rotateWithReplacement, lane: .host,
                                 expectedPid: 99, expectedToken: canonicalZeroToken),
    .accepted,
    "host rotation with canonical replacement accepted"
)
let rotateGenerated = BridgeCommandEnvelope(
    id: "cmd-rotate-2", action: "rotate_token", pid: 99, token: canonicalZeroToken
)
expectEqual(
    BridgeCommandPolicy.validate(rotateGenerated, lane: .host,
                                 expectedPid: 99, expectedToken: canonicalZeroToken),
    .accepted,
    "host rotation without replacement accepted"
)
let rotateMalformed = BridgeCommandEnvelope(
    id: "cmd-rotate-3",
    action: "rotate_token",
    pid: 99,
    token: canonicalZeroToken,
    replacementToken: "not-a-canonical-token"
)
expectEqual(
    BridgeCommandPolicy.validate(rotateMalformed, lane: .host,
                                 expectedPid: 99, expectedToken: canonicalZeroToken),
    .invalidReplacementToken,
    "host rotation with malformed replacement rejected"
)
let rotateUnchanged = BridgeCommandEnvelope(
    id: "cmd-rotate-4",
    action: "rotate_token",
    pid: 99,
    token: canonicalZeroToken,
    replacementToken: canonicalZeroToken
)
expectEqual(
    BridgeCommandPolicy.validate(rotateUnchanged, lane: .host,
                                 expectedPid: 99, expectedToken: canonicalZeroToken),
    .unchangedReplacementToken,
    "host rotation with unchanged replacement rejected"
)
expectEqual(
    BridgeCommandPolicy.validate(rotateWithReplacement, lane: .engine,
                                 expectedPid: 99, expectedToken: canonicalZeroToken),
    .unsupportedAction,
    "engine lane cannot rotate the token"
)

let oldTokenCommand = BridgeCommandEnvelope(
    id: "cmd-old-token", action: "status", pid: 99, token: canonicalZeroToken
)
expectEqual(
    BridgeCommandPolicy.validate(oldTokenCommand, lane: .host,
                                 expectedPid: 99, expectedToken: generatedToken),
    .invalidToken,
    "old token is invalid once the expected token rotates in the same batch"
)
let newTokenCommand = BridgeCommandEnvelope(
    id: "cmd-new-token", action: "status", pid: 99, token: generatedToken
)
expectEqual(
    BridgeCommandPolicy.validate(newTokenCommand, lane: .host,
                                 expectedPid: 99, expectedToken: generatedToken),
    .accepted,
    "new token is accepted in the same batch"
)

let encodedRotation = try! JSONEncoder().encode(rotateWithReplacement)
let decodedRotation = try! JSONDecoder().decode(BridgeCommandEnvelope.self, from: encodedRotation)
expect(decodedRotation == rotateWithReplacement, "rotation envelope JSON round-trips")
let legacyCommand = try! JSONDecoder().decode(
    BridgeCommandEnvelope.self,
    from: Data("{\"id\":\"cmd-legacy\",\"action\":\"status\"}".utf8)
)
expect(legacyCommand.replacementToken == nil, "legacy command without replacement decodes")
expect(legacyCommand.autoStart == nil, "legacy command without autoStart decodes")
expect(legacyCommand.lanEnabled == nil, "legacy command without lanEnabled decodes")

// MARK: - Recovery configuration policy
// Synthetic values only; the host executor is exercised on the device by the
// primary. These checks pin lane separation, explicit-false handling and
// field presence before any state is applied.

expect(BridgeCommandPolicy.hostActions.contains("configure_recovery"),
       "recovery configuration is a host action")
expect(!BridgeCommandPolicy.engineActions.contains("configure_recovery"),
       "recovery configuration is not an engine action")

let configureAutoStart = BridgeCommandEnvelope(
    id: "cmd-config-1",
    action: "configure_recovery",
    pid: 99,
    token: canonicalZeroToken,
    autoStart: false
)
expectEqual(
    BridgeCommandPolicy.validate(configureAutoStart, lane: .host,
                                 expectedPid: 99, expectedToken: canonicalZeroToken),
    .accepted,
    "explicit false autoStart configuration accepted"
)
let configureLAN = BridgeCommandEnvelope(
    id: "cmd-config-2",
    action: "configure_recovery",
    pid: 99,
    token: canonicalZeroToken,
    lanEnabled: true
)
expectEqual(
    BridgeCommandPolicy.validate(configureLAN, lane: .host,
                                 expectedPid: 99, expectedToken: canonicalZeroToken),
    .accepted,
    "LAN-only recovery configuration accepted"
)
let configureBoth = BridgeCommandEnvelope(
    id: "cmd-config-3",
    action: "configure_recovery",
    pid: 99,
    token: canonicalZeroToken,
    autoStart: true,
    lanEnabled: false
)
expectEqual(
    BridgeCommandPolicy.validate(configureBoth, lane: .host,
                                 expectedPid: 99, expectedToken: canonicalZeroToken),
    .accepted,
    "both recovery fields accepted"
)
let configureEmpty = BridgeCommandEnvelope(
    id: "cmd-config-4",
    action: "configure_recovery",
    pid: 99,
    token: canonicalZeroToken
)
expectEqual(
    BridgeCommandPolicy.validate(configureEmpty, lane: .host,
                                 expectedPid: 99, expectedToken: canonicalZeroToken),
    .missingRecoveryConfiguration,
    "empty recovery configuration rejected"
)
expectEqual(
    BridgeCommandPolicy.validate(configureBoth, lane: .engine,
                                 expectedPid: 99, expectedToken: canonicalZeroToken),
    .unsupportedAction,
    "engine lane cannot configure recovery"
)
expectEqual(
    BridgeCommandPolicy.validate(
        BridgeCommandEnvelope(id: "cmd-config-5", action: "configure_recovery",
                              pid: 98, token: canonicalZeroToken, autoStart: true),
        lane: .host, expectedPid: 99, expectedToken: canonicalZeroToken
    ),
    .pidMismatch,
    "recovery configuration still requires the current PID"
)
expectEqual(
    BridgeCommandPolicy.validate(
        BridgeCommandEnvelope(id: "cmd-config-6", action: "configure_recovery",
                              pid: 99, token: "wrong", autoStart: true),
        lane: .host, expectedPid: 99, expectedToken: canonicalZeroToken
    ),
    .invalidToken,
    "recovery configuration still requires the current token"
)

let encodedConfiguration = try! JSONEncoder().encode(configureBoth)
let decodedConfiguration = try! JSONDecoder().decode(
    BridgeCommandEnvelope.self,
    from: encodedConfiguration
)
expect(decodedConfiguration == configureBoth, "recovery configuration JSON round-trips")
let explicitFalseConfiguration = try! JSONDecoder().decode(
    BridgeCommandEnvelope.self,
    from: Data("{\"id\":\"cmd-config-legacy\",\"action\":\"configure_recovery\",\"pid\":99,\"token\":\"synthetic\",\"autoStart\":false}".utf8)
)
expectEqual(explicitFalseConfiguration.autoStart, false,
            "explicit false survives command decode")
expect(explicitFalseConfiguration.lanEnabled == nil,
       "omitted recovery field stays nil")

// MARK: - Auto-start default policy

expectEqual(BridgeAutoStartPolicy.initialValue(stored: nil), false,
            "autoStart: absent preference starts false before real ready")
expectEqual(BridgeAutoStartPolicy.initialValue(stored: false), false,
            "autoStart: explicit false survives launch")
expectEqual(BridgeAutoStartPolicy.initialValue(stored: true), true,
            "autoStart: explicit true survives launch")
expectEqual(BridgeAutoStartPolicy.valueAfterEngineReady(stored: nil), true,
            "autoStart: unset preference becomes true on real engine-ready")
expect(BridgeAutoStartPolicy.valueAfterEngineReady(stored: false) == nil,
       "autoStart: explicit false is not replaced at engine-ready")
expect(BridgeAutoStartPolicy.valueAfterEngineReady(stored: true) == nil,
       "autoStart: explicit true is not rewritten at engine-ready")

// MARK: - Preparation fact reconciliation

var preparation = BridgeLifecycle(hostPid: 5050)
let preparationPhase = preparation.snapshot.phase
let preparationGeneration = preparation.snapshot.generation
let preparationFacts = BridgePreparationFacts(
    pairingImported: true,
    ddi: .mounted,
    ddiLayout: "system",
    ddiSource: "preexisting",
    ddiDetail: "observed mounted runtime"
)
expect(preparation.applyPreparationFacts(preparationFacts),
       "first preparation observation changes state")
expectEqual(preparation.snapshot.pairingImported, true,
            "preparation pairing fact agrees")
expectEqual(preparation.snapshot.ddi, .mounted, "preparation DDI fact agrees")
expectEqual(preparation.snapshot.ddiLayout, "system", "preparation DDI layout agrees")
expectEqual(preparation.snapshot.ddiSource, "preexisting", "preparation source preserved")
expectEqual(preparation.snapshot.phase, preparationPhase,
            "preparation observation does not advance lifecycle phase")
expectEqual(preparation.snapshot.generation, preparationGeneration,
            "preparation observation does not change generation")
expect(!preparation.snapshot.serviceRunning,
       "preparation observation does not create a service")
expect(!preparation.snapshot.startAttempted,
       "preparation observation does not start preparation")
expect(!preparation.snapshot.oneShotDispatched,
       "preparation observation does not dispatch the one-shot")
let preparedSnapshot = preparation.snapshot
expect(!preparation.applyPreparationFacts(preparationFacts),
       "unchanged preparation facts report no write")
expectEqual(preparation.snapshot, preparedSnapshot,
            "unchanged preparation facts leave the snapshot identical")

var readyPreparation = BridgeLifecycle(hostPid: 5051)
let readyGeneration = readyPreparation.beginStart(trigger: "preparation")
_ = readyPreparation.markBootstrapDispatched(readyGeneration)
_ = readyPreparation.noteEngineEntry(readyGeneration, pid: 5051,
                                     testMethod: "testBridgeEngineLoop", hostPid: 5051)
let readyBefore = readyPreparation.snapshot
let readyFacts = BridgePreparationFacts(
    pairingImported: false,
    ddi: .notMounted,
    ddiLayout: nil,
    ddiSource: nil,
    ddiDetail: nil
)
expect(readyPreparation.applyPreparationFacts(readyFacts),
       "ready preparation facts can be reconciled")
expectEqual(readyPreparation.snapshot.phase, readyBefore.phase,
            "reconciliation never demotes a ready engine")
expectEqual(readyPreparation.snapshot.generation, readyBefore.generation,
            "reconciliation never changes the ready generation")
expectEqual(readyPreparation.snapshot.engineRunning, readyBefore.engineRunning,
            "reconciliation never changes engineRunning")
expectEqual(readyPreparation.snapshot.oneShotDispatched, readyBefore.oneShotDispatched,
            "reconciliation never changes oneShotDispatched")
expectEqual(readyPreparation.snapshot.engineEntryObserved, readyBefore.engineEntryObserved,
            "reconciliation never changes engineEntryObserved")

var faultedPreparation = BridgeLifecycle(hostPid: 5052)
let faultedGeneration = faultedPreparation.beginStart(trigger: "preparation-fault")
_ = faultedPreparation.markBootstrapDispatched(faultedGeneration)
expect(faultedPreparation.failTerminal(faultedGeneration, code: "fixture-fault",
                                       message: "synthetic fault"),
       "preparation fixture latches terminal fault")
let faultedBefore = faultedPreparation.snapshot
_ = faultedPreparation.applyPreparationFacts(
    BridgePreparationFacts(pairingImported: true, ddi: .mounted,
                           ddiLayout: "system", ddiSource: "preexisting")
)
expect(faultedPreparation.snapshot.terminalFault,
       "preparation reconciliation preserves sticky terminal fault")
expectEqual(faultedPreparation.snapshot.terminalFaultCode, faultedBefore.terminalFaultCode,
            "preparation reconciliation preserves terminal fault code")
expectEqual(faultedPreparation.snapshot.phase, faultedBefore.phase,
            "preparation reconciliation leaves faulted phase intact")
expectEqual(faultedPreparation.snapshot.generation, faultedBefore.generation,
            "preparation reconciliation leaves faulted generation intact")

// MARK: - DDI install method and build identity

expectEqual(BridgeDDIInstallMethod.forOperatingSystem(OperatingSystemVersion(majorVersion: 26, minorVersion: 3, patchVersion: 0)),
            .personalized, "iOS 26.3 uses personalized DDI")
expectEqual(BridgeDDIInstallMethod.forOperatingSystem(OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)),
            .cryptex, "iOS 26.4 uses cryptex DDI")
expectEqual(BridgeDDIInstallMethod.forOperatingSystem(OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0)),
            .cryptex, "iOS 27 uses cryptex DDI")
expect(BridgeDDIInstallMethod.personalized.components == [.buildManifest, .image, .trustCache],
       "personalized DDI component set")
expect(BridgeDDIInstallMethod.cryptex.components.contains(.cryptexInfo) &&
       BridgeDDIInstallMethod.cryptex.components.contains(.rootHash),
       "cryptex DDI component set")
expectEqual(BridgeBuild.marketingVersion, "1.0.0", "build marketing version")
expectEqual(BridgeBuild.buildNumber, "15", "build number")
expect(BridgeTransport.interfaceAddressValue == 0x0A07_0002 &&
       BridgeTransport.peerAddressValue == 0x0A07_0001,
       "transport address constants")

expectEqual(BridgeDDILayout.cryptex.executablePath,
            "/private/preboot/Cryptexes/OS/System/Developer/Library/Frameworks/XCTest.framework/XCTest",
            "cryptex XCTest executable path")
expectEqual(BridgeDDILayout.system.executablePath,
            "/System/Developer/Library/Frameworks/XCTest.framework/XCTest",
            "system XCTest executable path")
expectEqual(BridgeDDILayout.legacy.executablePath,
            "/Developer/Library/Frameworks/XCTest.framework/XCTest",
            "legacy XCTest executable path")
expectEqual(BridgeDDILayout.cryptex.coreExecutablePath,
            "/private/preboot/Cryptexes/OS/System/Developer/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore",
            "cryptex XCTestCore executable path")
expectEqual(BridgeDDILayout.system.coreExecutablePath,
            "/System/Developer/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore",
            "system XCTestCore executable path")
expectEqual(BridgeDDILayout.legacy.coreExecutablePath,
            "/Developer/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore",
            "legacy XCTestCore executable path")
expectEqual(BridgeDDIProbe.runtimeCandidates.count, 5, "three XCTest and two XCTestCore candidates")
expectEqual(BridgeDDIProbe.runtimeCandidates.first?.runtime, .xctest, "XCTest images preferred")
expectEqual(BridgeDDIProbe.runtimeCandidates.last?.runtime, .xctestCore, "XCTestCore fallback ordered last")
expect(!BridgeDDIProbe.runtimeCandidates.contains {
    $0.layout == .legacy && $0.runtime == .xctestCore
}, "legacy layout has no XCTestCore loader candidate")

// Real filesystem fixture: a framework directory is never a runtime image.
let ddiFixtureRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("floe-bridge-ddi-\(UUID().uuidString)", isDirectory: true)
let ddiFixtureFramework = ddiFixtureRoot
    .appendingPathComponent("Library/Frameworks/XCTest.framework", isDirectory: true)
try? FileManager.default.createDirectory(at: ddiFixtureFramework, withIntermediateDirectories: true)
let ddiFixtureExecutable = ddiFixtureFramework.appendingPathComponent("XCTest")
let ddiFixtureBytes = Data("fixture-runtime".utf8)
try? ddiFixtureBytes.write(to: ddiFixtureExecutable)

let directoryInspection = BridgeDDIProbe.inspect(path: ddiFixtureFramework.path)
expectEqual(directoryInspection.state, .directory, "DDI fixture: framework directory alone is not a runtime")
expectEqual(directoryInspection.bytes, 0, "DDI fixture: directory exposes no executable byte count")

let executableInspection = BridgeDDIProbe.inspect(path: ddiFixtureExecutable.path)
expectEqual(executableInspection.state, .readable, "DDI fixture: readable XCTest executable recognized")
expectEqual(executableInspection.bytes, UInt64(ddiFixtureBytes.count),
            "DDI fixture: executable size retained as diagnostics")

let missingInspection = BridgeDDIProbe.inspect(
    path: ddiFixtureFramework.appendingPathComponent("MissingExecutable").path
)
expectEqual(missingInspection.state, .missing, "DDI fixture: missing executable classified")

let unreadablePath = ddiFixtureRoot.appendingPathComponent("UnreadableXCTest").path
try? Data("unreadable-runtime".utf8).write(to: URL(fileURLWithPath: unreadablePath))
try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadablePath)
let unreadableInspection = BridgeDDIProbe.inspect(path: unreadablePath)
expectEqual(unreadableInspection.state, .unreadable, "DDI fixture: unreadable executable classified")
try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadablePath)

let executableCandidates = [
    BridgeDDIRuntimeCandidate(layout: .system, runtime: .xctest, path: ddiFixtureExecutable.path)
]
let executableStatus = BridgeDDIProbe.status(candidates: executableCandidates)
expect(executableStatus.mounted, "DDI fixture: executable candidate reports a runtime")
expectEqual(executableStatus.xctestPath, ddiFixtureExecutable.path,
            "DDI fixture: probe selects the executable, not the bundle directory")
expectEqual(executableStatus.runtime, .xctest, "DDI fixture: selected runtime kind")
expectEqual(executableStatus.layout, .system, "DDI fixture: selected layout")
expect(executableStatus.xctestCorePath?.hasSuffix(
    "/Library/PrivateFrameworks/XCTestCore.framework/XCTestCore") == true,
       "DDI fixture: XCTestCore path stays under PrivateFrameworks")

let directoryCandidates = [
    BridgeDDIRuntimeCandidate(layout: .system, runtime: .xctest, path: ddiFixtureFramework.path)
]
let directoryStatus = BridgeDDIProbe.status(candidates: directoryCandidates)
expect(!directoryStatus.mounted, "DDI fixture: directory-only candidate is not mounted")
expect(directoryStatus.xctestPath == nil, "DDI fixture: no executable path selected from a directory")

let missingCandidates = [
    BridgeDDIRuntimeCandidate(layout: .legacy, runtime: .xctestCore,
                              path: ddiFixtureRoot.appendingPathComponent("MissingXCTestCore").path)
]
expect(!BridgeDDIProbe.status(candidates: missingCandidates).mounted,
       "DDI fixture: missing candidate is not mounted")

// MARK: - DDI mount provenance and probe evidence

expectEqual(
    BridgeDDIMountProvenance.classify(alreadyMounted: false, preStateVerifiedAbsent: true),
    .onDevice,
    "provenance: verified absent pre-state plus explicit install belongs to this app"
)
expectEqual(
    BridgeDDIMountProvenance.classify(alreadyMounted: false, preStateVerifiedAbsent: false),
    .preexisting,
    "provenance: install flag without verified absence cannot claim on-device"
)
expectEqual(
    BridgeDDIMountProvenance.classify(alreadyMounted: true, preStateVerifiedAbsent: true),
    .preexisting,
    "provenance: already-mounted report cannot claim this app's install"
)
expectEqual(
    BridgeDDIMountProvenance.classify(alreadyMounted: nil, preStateVerifiedAbsent: true),
    .preexisting,
    "provenance: missing report flag is treated conservatively"
)

var ddiProvenance = BridgeLifecycle(hostPid: 8181)
ddiProvenance.setDDI(.mounted, layout: "system", source: "preexisting", detail: "reused")
expect(ddiProvenance.snapshot.lastOnDeviceMountAt == nil,
       "preexisting mount cannot claim an on-device mount time")
ddiProvenance.setDDI(.mounted, layout: "system", source: "on-device", detail: "observation")
expect(ddiProvenance.snapshot.lastOnDeviceMountAt == nil,
       "ordinary observation cannot fabricate an on-device mount time")
ddiProvenance.recordVerifiedOnDeviceMount(layout: "system", path: "/fixture/XCTest.framework/XCTest")
let verifiedMountAt = ddiProvenance.snapshot.lastOnDeviceMountAt
expect(verifiedMountAt != nil, "verified install records a mount timestamp")
expectEqual(ddiProvenance.snapshot.lastOnDeviceMountLayout, "system", "verified mount records layout")
expectEqual(ddiProvenance.snapshot.lastOnDeviceMountPath,
            "/fixture/XCTest.framework/XCTest", "verified mount records runtime path")
Thread.sleep(forTimeInterval: 0.02)
ddiProvenance.setDDI(.mounted, layout: "system", source: "on-device", detail: "repeat observation")
expectEqual(ddiProvenance.snapshot.lastOnDeviceMountAt, verifiedMountAt,
            "repeated observation keeps the original mount timestamp")
ddiProvenance.setDDI(.notMounted, layout: nil, source: nil, detail: "absent")
expect(ddiProvenance.snapshot.ddiSource == nil, "absent DDI clears stale source")
expect(ddiProvenance.snapshot.ddiLayout == nil, "absent DDI clears stale layout")
ddiProvenance.recordDDIProbe(mounted: false, layout: nil, path: nil, source: nil,
                             detail: "pre-start probe absent")
expect(ddiProvenance.snapshot.lastDDIProbeAt != nil, "pre-start probe records a timestamp when absent")
expectEqual(ddiProvenance.snapshot.lastDDIProbeMounted, false,
            "pre-start probe records the absent result")
expect(ddiProvenance.snapshot.lastDDIProbePath == nil,
       "pre-start absent probe records no runtime path")

// MARK: - DDI service states, removal planning and guards

let ddiCryptexEntry = BridgeDDICryptexEntry(
    identifier: BridgeDDIRemovalPolicy.ddiCryptexIdentifier,
    version: "39.999.999.0.0,0"
)
let ddiCryptexPresent = BridgeDDICryptexQuery.installed(ddiCryptexEntry)
let ddiCryptexAbsent = BridgeDDICryptexQuery.absent
let ddiCryptexUnknown = BridgeDDICryptexQuery.unknown(reason: "transport")
let ddiCryptexNotApplicable = BridgeDDICryptexQuery.notApplicable(reason: "older OS")
let ddiImagesEmpty = BridgeDDIImageQuery.devices([])
let ddiImagesPersonalized = BridgeDDIImageQuery.devices([
    BridgeDDIDeviceImage(diskImageType: "Personalized", isMounted: true)
])
let ddiImagesDeveloper = BridgeDDIImageQuery.devices([
    BridgeDDIDeviceImage(diskImageType: "Developer", isMounted: true)
])
let ddiImagesUnrelated = BridgeDDIImageQuery.devices([
    BridgeDDIDeviceImage(diskImageType: "Cryptex", isMounted: true)
])
let ddiImagesUnknown = BridgeDDIImageQuery.unknown(reason: "service failed")
let ddiImagesNotApplicable = BridgeDDIImageQuery.notApplicable(reason: "older OS")
expect(BridgeDDIDeviceImage(diskImageType: "personalized", isMounted: true).isDeveloperDiskImage,
       "image: developer type matching is case-insensitive")
expect(!BridgeDDIDeviceImage(diskImageType: "Cryptex", isMounted: true).isDeveloperDiskImage,
       "image: unrelated type is not a developer image")

func preStateIsAlreadyMounted(_ decision: BridgeDDIPreStateDecision) -> Bool {
    if case .alreadyMounted = decision { return true }
    return false
}

func preStateIsAbsent(_ decision: BridgeDDIPreStateDecision) -> Bool {
    if case .absent = decision { return true }
    return false
}

func preStateIsUnknown(_ decision: BridgeDDIPreStateDecision) -> Bool {
    if case .unknown = decision { return true }
    return false
}

func planIsUninstallAllVersions(_ plan: BridgeDDIRemovalPlan) -> Bool {
    if case .uninstallCryptex(let identifier, let version) = plan {
        return identifier == BridgeDDIRemovalPolicy.ddiCryptexIdentifier && version == nil
    }
    return false
}

func planIsUnmount(_ plan: BridgeDDIRemovalPlan, path: String, type: String) -> Bool {
    if case .unmountDeveloperImage(let actualPath, let actualType) = plan {
        return actualPath == path && actualType == type
    }
    return false
}

func planIsAlreadyAbsent(_ plan: BridgeDDIRemovalPlan) -> Bool {
    if case .alreadyAbsent = plan { return true }
    return false
}

func planIsFailClosed(_ plan: BridgeDDIRemovalPlan) -> Bool {
    if case .failClosed = plan { return true }
    return false
}

// Present cryptex DDI: a preexisting mount and the identifier-scoped removal.
expect(preStateIsAlreadyMounted(BridgeDDIRemovalPolicy.classifyPreState(
    cryptex: ddiCryptexPresent,
    image: ddiImagesEmpty,
    probeMounted: false,
    installMethod: .cryptex
)), "pre-state: present cryptex is already mounted")
expect(planIsUninstallAllVersions(BridgeDDIRemovalPolicy.removalPlan(
    cryptex: ddiCryptexPresent,
    image: ddiImagesEmpty,
    probeMounted: false,
    installMethod: .cryptex
)), "plan: present cryptex removes only the DDI identifier with all versions")

// Personalized-only and Developer-only image mounter states.
expect(preStateIsAlreadyMounted(BridgeDDIRemovalPolicy.classifyPreState(
    cryptex: ddiCryptexAbsent,
    image: ddiImagesPersonalized,
    probeMounted: false,
    installMethod: .personalized
)), "pre-state: personalized image is a preexisting developer image")
expect(planIsUnmount(BridgeDDIRemovalPolicy.removalPlan(
    cryptex: ddiCryptexAbsent,
    image: ddiImagesPersonalized,
    probeMounted: false,
    installMethod: .personalized
), path: "/System/Developer", type: "Personalized"),
       "plan: personalized image unmounts only /System/Developer")
expect(planIsUnmount(BridgeDDIRemovalPolicy.removalPlan(
    cryptex: ddiCryptexAbsent,
    image: ddiImagesDeveloper,
    probeMounted: false,
    installMethod: .personalized
), path: "/Developer", type: "Developer"),
       "plan: legacy Developer image unmounts only /Developer")

// An unrelated image is not a DDI and must never be unmounted.
expect(preStateIsAbsent(BridgeDDIRemovalPolicy.classifyPreState(
    cryptex: ddiCryptexAbsent,
    image: ddiImagesUnrelated,
    probeMounted: false,
    installMethod: .cryptex
)), "pre-state: unrelated image is not a developer image")
expect(planIsAlreadyAbsent(BridgeDDIRemovalPolicy.removalPlan(
    cryptex: ddiCryptexAbsent,
    image: ddiImagesUnrelated,
    probeMounted: false,
    installMethod: .cryptex
)), "plan: unrelated image is left untouched")

// Both service views present: cryptex removal wins the ordering.
expect(planIsUninstallAllVersions(BridgeDDIRemovalPolicy.removalPlan(
    cryptex: ddiCryptexPresent,
    image: ddiImagesPersonalized,
    probeMounted: false,
    installMethod: .cryptex
)), "plan: both present prefers the identifier-scoped cryptex removal")

// Already absent is an explicit result, not a failure.
expect(preStateIsAbsent(BridgeDDIRemovalPolicy.classifyPreState(
    cryptex: ddiCryptexAbsent,
    image: ddiImagesEmpty,
    probeMounted: false,
    installMethod: .cryptex
)), "pre-state: both services definitively absent")
expect(planIsAlreadyAbsent(BridgeDDIRemovalPolicy.removalPlan(
    cryptex: ddiCryptexAbsent,
    image: ddiImagesEmpty,
    probeMounted: false,
    installMethod: .cryptex
)), "plan: already absent performs no mutation")

// Every failed or non-definitive query fails closed; none may become absence.
expect(preStateIsUnknown(BridgeDDIRemovalPolicy.classifyPreState(
    cryptex: ddiCryptexUnknown,
    image: ddiImagesEmpty,
    probeMounted: false,
    installMethod: .cryptex
)), "pre-state: failed cryptex query is unknown")
expect(planIsFailClosed(BridgeDDIRemovalPolicy.removalPlan(
    cryptex: ddiCryptexUnknown,
    image: ddiImagesEmpty,
    probeMounted: false,
    installMethod: .cryptex
)), "plan: failed cryptex query performs no mutation")
expect(preStateIsUnknown(BridgeDDIRemovalPolicy.classifyPreState(
    cryptex: ddiCryptexAbsent,
    image: ddiImagesUnknown,
    probeMounted: false,
    installMethod: .cryptex
)), "pre-state: failed image query is unknown")
expect(planIsFailClosed(BridgeDDIRemovalPolicy.removalPlan(
    cryptex: ddiCryptexAbsent,
    image: ddiImagesUnknown,
    probeMounted: false,
    installMethod: .cryptex
)), "plan: failed image query performs no mutation")
expect(preStateIsUnknown(BridgeDDIRemovalPolicy.classifyPreState(
    cryptex: ddiCryptexAbsent,
    image: ddiImagesNotApplicable,
    probeMounted: false,
    installMethod: .cryptex
)), "pre-state: not-applicable image service is unknown")
expect(planIsFailClosed(BridgeDDIRemovalPolicy.removalPlan(
    cryptex: ddiCryptexAbsent,
    image: ddiImagesNotApplicable,
    probeMounted: false,
    installMethod: .cryptex
)), "plan: not-applicable image service performs no mutation")

// A known-unsupported cryptexd service is acceptable only on the personalized
// path. On a cryptex OS it remains unknown and fails closed.
expect(preStateIsUnknown(BridgeDDIRemovalPolicy.classifyPreState(
    cryptex: ddiCryptexNotApplicable,
    image: ddiImagesEmpty,
    probeMounted: false,
    installMethod: .cryptex
)), "pre-state: unavailable cryptexd blocks a cryptex-path install")
expect(planIsFailClosed(BridgeDDIRemovalPolicy.removalPlan(
    cryptex: ddiCryptexNotApplicable,
    image: ddiImagesEmpty,
    probeMounted: false,
    installMethod: .cryptex
)), "plan: unavailable cryptexd on a cryptex OS fails closed")
expect(preStateIsAbsent(BridgeDDIRemovalPolicy.classifyPreState(
    cryptex: ddiCryptexNotApplicable,
    image: ddiImagesEmpty,
    probeMounted: false,
    installMethod: .personalized
)), "pre-state: unavailable cryptexd is not applicable on the personalized path")
expect(planIsAlreadyAbsent(BridgeDDIRemovalPolicy.removalPlan(
    cryptex: ddiCryptexNotApplicable,
    image: ddiImagesEmpty,
    probeMounted: false,
    installMethod: .personalized
)), "plan: not-applicable cryptexd on personalized path is already absent")

// Local readability with no service object is unexplained, never absence.
expect(preStateIsUnknown(BridgeDDIRemovalPolicy.classifyPreState(
    cryptex: ddiCryptexAbsent,
    image: ddiImagesEmpty,
    probeMounted: true,
    installMethod: .cryptex
)), "pre-state: readable XCTest without a DDI object is unknown")
expect(planIsFailClosed(BridgeDDIRemovalPolicy.removalPlan(
    cryptex: ddiCryptexAbsent,
    image: ddiImagesEmpty,
    probeMounted: true,
    installMethod: .cryptex
)), "plan: readable XCTest without a DDI object fails closed")

// Removal is restricted to the exact DDI identifier even if a call site
// reports a different cryptex.
let unexpectedCryptex = BridgeDDICryptexQuery.installed(
    BridgeDDICryptexEntry(identifier: "com.apple.MobileAsset.SomethingElse")
)
expect(planIsFailClosed(BridgeDDIRemovalPolicy.removalPlan(
    cryptex: unexpectedCryptex,
    image: ddiImagesEmpty,
    probeMounted: false,
    installMethod: .cryptex
)), "plan: a non-DDI cryptex identifier fails closed")

// ServiceNotFound (21) is typed not-applicable only on the personalized path;
// transport/protocol codes stay unknown.
expectEqual(
    BridgeDDIRemovalPolicy.cryptexQueryAfterServiceError(code: 21, installMethod: .personalized),
    .notApplicable(reason: "cryptexd is not exposed by this OS"),
    "error: ServiceNotFound is not-applicable on the personalized path"
)
if case .unknown = BridgeDDIRemovalPolicy.cryptexQueryAfterServiceError(
    code: 21, installMethod: .cryptex
) {
    expect(true, "error: ServiceNotFound stays unknown on the cryptex path")
} else {
    expect(false, "error: ServiceNotFound stays unknown on the cryptex path")
}
if case .unknown = BridgeDDIRemovalPolicy.cryptexQueryAfterServiceError(
    code: 1, installMethod: .personalized
) {
    expect(true, "error: transport failure on a supported service stays unknown")
} else {
    expect(false, "error: transport failure on a supported service stays unknown")
}

// Guard policy: every refusal is explicit and an idle, paired process passes.
expectEqual(
    BridgeDDIRemovalGuard.decide(BridgeDDIRemovalGuardInput(pairingImported: true)),
    .allowed,
    "guard: idle paired process may remove"
)
expectEqual(
    BridgeDDIRemovalGuard.decide(BridgeDDIRemovalGuardInput(terminalFault: true, pairingImported: true)),
    .refused(code: BridgeDDIRemovalGuard.terminalFaultCode),
    "guard: terminal fault refuses"
)
expectEqual(
    BridgeDDIRemovalGuard.decide(BridgeDDIRemovalGuardInput(oneShotDispatched: true, pairingImported: true)),
    .refused(code: BridgeDDIRemovalGuard.oneShotCode),
    "guard: dispatched one-shot refuses"
)
expectEqual(
    BridgeDDIRemovalGuard.decide(BridgeDDIRemovalGuardInput(engineEntryObserved: true, pairingImported: true)),
    .refused(code: BridgeDDIRemovalGuard.oneShotCode),
    "guard: initialized driver refuses"
)
expectEqual(
    BridgeDDIRemovalGuard.decide(BridgeDDIRemovalGuardInput(ddiWorkerBusy: true, pairingImported: true)),
    .refused(code: BridgeDDIRemovalGuard.workerBusyCode),
    "guard: live DDI worker refuses"
)
expectEqual(
    BridgeDDIRemovalGuard.decide(BridgeDDIRemovalGuardInput(engineRunning: true, pairingImported: true)),
    .refused(code: BridgeDDIRemovalGuard.engineActiveCode),
    "guard: running engine refuses"
)
expectEqual(
    BridgeDDIRemovalGuard.decide(BridgeDDIRemovalGuardInput(serviceRunning: true, pairingImported: true)),
    .refused(code: BridgeDDIRemovalGuard.engineActiveCode),
    "guard: active service refuses"
)
expectEqual(
    BridgeDDIRemovalGuard.decide(BridgeDDIRemovalGuardInput(phaseActive: true, pairingImported: true)),
    .refused(code: BridgeDDIRemovalGuard.engineActiveCode),
    "guard: active startup phase refuses"
)
expectEqual(
    BridgeDDIRemovalGuard.decide(BridgeDDIRemovalGuardInput(autoStartEnabled: true, pairingImported: true)),
    .refused(code: BridgeDDIRemovalGuard.autoStartCode),
    "guard: Auto-recover enabled refuses"
)
expectEqual(
    BridgeDDIRemovalGuard.decide(BridgeDDIRemovalGuardInput()),
    .refused(code: BridgeDDIRemovalGuard.pairingCode),
    "guard: missing pairing refuses"
)

// MARK: - DDI image query shape validation and normalized planning

func imageQueryIsUnknown(_ query: BridgeDDIImageQuery) -> Bool {
    if case .unknown = query { return true }
    return false
}

let parsedEmptyImages = BridgeDDIImageQueryParser.parse([])
expectEqual(parsedEmptyImages, .devices([]), "image parse: empty array is definitive")
expect(parsedEmptyImages.isDefinitive, "image parse: empty array is a definitive query")

let parsedDeveloper = BridgeDDIImageQueryParser.parse([
    .image(diskImageType: "  DeVeLoPeR \n", isMounted: true)
])
expectEqual(parsedDeveloper.deviceList?.first?.diskImageType, "Developer",
            "image parse: developer type is canonical")
expect(parsedDeveloper.hasDeveloperDiskImage, "image parse: normalized developer is a DDI")
expect(planIsUnmount(BridgeDDIRemovalPolicy.removalPlan(
    cryptex: ddiCryptexAbsent,
    image: parsedDeveloper,
    probeMounted: false,
    installMethod: .personalized
), path: "/Developer", type: "Developer"),
       "plan: normalized developer type unmounts /Developer")
expect(!planIsAlreadyAbsent(BridgeDDIRemovalPolicy.removalPlan(
    cryptex: ddiCryptexAbsent,
    image: parsedDeveloper,
    probeMounted: false,
    installMethod: .personalized
)), "plan: normalized developer type is never already absent")

let parsedPersonalized = BridgeDDIImageQueryParser.parse([
    .image(diskImageType: " personalized\t", isMounted: true)
])
expect(planIsUnmount(BridgeDDIRemovalPolicy.removalPlan(
    cryptex: ddiCryptexAbsent,
    image: parsedPersonalized,
    probeMounted: false,
    installMethod: .personalized
), path: "/System/Developer", type: "Personalized"),
       "plan: normalized personalized type unmounts /System/Developer")

let parsedUnrelated = BridgeDDIImageQueryParser.parse([
    .image(diskImageType: "Cryptex", isMounted: true)
])
expect(!parsedUnrelated.hasDeveloperDiskImage, "image parse: unrelated cryptex is not a DDI")
expect(planIsAlreadyAbsent(BridgeDDIRemovalPolicy.removalPlan(
    cryptex: ddiCryptexAbsent,
    image: parsedUnrelated,
    probeMounted: false,
    installMethod: .cryptex
)), "image parse: unrelated image is left untouched")

let whitespaceDirectPlan = BridgeDDIRemovalPolicy.removalPlan(
    cryptex: ddiCryptexAbsent,
    image: .devices([BridgeDDIDeviceImage(diskImageType: "  DEVELOPER ", isMounted: true)]),
    probeMounted: false,
    installMethod: .personalized
)
if case .unmountDeveloperImage(let path, _) = whitespaceDirectPlan {
    expectEqual(path, "/Developer",
                "plan: whitespace developer type is planned, not already absent")
} else {
    expect(false, "plan: whitespace developer type is planned, not already absent",
           "\(whitespaceDirectPlan)")
}

let malformedInvalidEntry = BridgeDDIImageQueryParser.parse([.invalidEntry])
expect(imageQueryIsUnknown(malformedInvalidEntry), "image parse: invalid entry is unknown")
let malformedMissingType = BridgeDDIImageQueryParser.parse([
    .image(diskImageType: nil, isMounted: false)
])
expect(imageQueryIsUnknown(malformedMissingType), "image parse: missing type is unknown")
let malformedEmptyType = BridgeDDIImageQueryParser.parse([
    .image(diskImageType: "", isMounted: false)
])
expect(imageQueryIsUnknown(malformedEmptyType), "image parse: empty type is unknown")
let malformedBlankType = BridgeDDIImageQueryParser.parse([
    .image(diskImageType: " \n\t", isMounted: false)
])
expect(imageQueryIsUnknown(malformedBlankType), "image parse: whitespace-only type is unknown")
let malformedUnknownType = BridgeDDIImageQueryParser.parse([
    .image(diskImageType: "MysteryImage", isMounted: false)
])
expect(imageQueryIsUnknown(malformedUnknownType), "image parse: unrecognized type is unknown")
let oversizedImageType = BridgeDDIImageQueryParser.parse([
    .image(diskImageType: "Developer" + String(repeating: " ", count: 64) + "unknown", isMounted: true)
])
expect(imageQueryIsUnknown(oversizedImageType),
       "image parse: oversized type cannot become a recognized truncated prefix")
expect(planIsFailClosed(BridgeDDIRemovalPolicy.removalPlan(
    cryptex: ddiCryptexAbsent,
    image: oversizedImageType,
    probeMounted: false,
    installMethod: .cryptex
)), "oversized image type: no mutation is planned")
let tooManyObservations = Array(
    repeating: BridgeDDIImageObservation.image(diskImageType: "Cryptex", isMounted: false),
    count: BridgeDDIImageQueryParser.maximumDeviceEntries + 1
)
expect(imageQueryIsUnknown(BridgeDDIImageQueryParser.parse(tooManyObservations)),
       "image parse: over-bound entry count is unknown")

let malformedImage = BridgeDDIImageQueryParser.parse([
    .image(diskImageType: nil, isMounted: true)
])
expect(!malformedImage.isDefinitive, "malformed image: no definitive absence")
expect(!malformedImage.hasDeveloperDiskImage, "malformed image: no developer image claim")
expect(preStateIsUnknown(BridgeDDIRemovalPolicy.classifyPreState(
    cryptex: ddiCryptexAbsent,
    image: malformedImage,
    probeMounted: false,
    installMethod: .cryptex
)), "malformed image: pre-state remains unknown")
expect(planIsFailClosed(BridgeDDIRemovalPolicy.removalPlan(
    cryptex: ddiCryptexAbsent,
    image: malformedImage,
    probeMounted: false,
    installMethod: .cryptex
)), "malformed image: no mutation is planned")

// MARK: - DDI mutation gate and worker lifetime

final class GateEnterCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

let beforeEntryGate = BridgeDDIMutationGate()
expect(!beforeEntryGate.isCancelled && !beforeEntryGate.didEnterMutation,
       "gate: a new gate is open")
expect(beforeEntryGate.cancel(), "gate: cancellation before entry is reported")
expectEqual(beforeEntryGate.beginMutation(), .cancelledBeforeEntry,
            "gate: cancel-before-entry blocks mutation")
expect(!beforeEntryGate.didEnterMutation, "gate: cancelled mutation never entered")

let afterQueryGate = BridgeDDIMutationGate()
expect(afterQueryGate.cancel(),
       "gate: cancellation at the post-query boundary is reported")
expectEqual(afterQueryGate.beginMutation(), .cancelledBeforeEntry,
            "gate: cancellation after read-only work prevents mutation")

let inFlightGate = BridgeDDIMutationGate()
expectEqual(inFlightGate.beginMutation(), .entered,
            "gate: the first mutation entry is accepted")
expect(!inFlightGate.cancel(),
       "gate: cancellation after entry is reported as in-flight")
expect(inFlightGate.isCancelled, "gate: in-flight cancellation is visible")
expect(inFlightGate.didEnterMutation,
       "gate: attempted flag survives cancellation until return")
expectEqual(inFlightGate.beginMutation(), .alreadyEntered,
            "gate: a second mutation entry is impossible")

let concurrentGate = BridgeDDIMutationGate()
let gateCounter = GateEnterCounter()
DispatchQueue.concurrentPerform(iterations: 128) { _ in
    if concurrentGate.beginMutation() == .entered {
        gateCounter.increment()
    }
}
expectEqual(gateCounter.value, 1,
            "gate: concurrent callers allow exactly one mutation entry")

var inFlightReport = BridgeDDIRemovalReport(
    generation: 88,
    installMethod: .cryptex,
    mutationAttempted: true
)
expect(BridgeDDIRemovalCancellation.apply(to: &inFlightReport, gate: inFlightGate),
       "cancellation report: in-flight gate overrides the outcome")
expectEqual(inFlightReport.outcome, .cancelled,
            "cancellation report: in-flight outcome is cancelled")
expectEqual(inFlightReport.mutationAttempted, true,
            "cancellation report: attempted flag is retained")
expect(inFlightReport.errorMessage?.contains("in flight") == true,
       "cancellation report: in-flight wording preserved")
var preEntryReport = BridgeDDIRemovalReport(
    generation: 89,
    installMethod: .cryptex,
    mutationAttempted: false
)
expect(BridgeDDIRemovalCancellation.apply(to: &preEntryReport, gate: beforeEntryGate),
       "cancellation report: pre-entry gate overrides the outcome")
expect(preEntryReport.errorMessage?.contains("no mutation was attempted") == true,
       "cancellation report: pre-entry wording preserved")
let openGate = BridgeDDIMutationGate()
var openReport = BridgeDDIRemovalReport(generation: 90, installMethod: .cryptex)
expect(!BridgeDDIRemovalCancellation.apply(to: &openReport, gate: openGate),
       "cancellation report: an open gate changes nothing")
expectEqual(openReport.outcome, .failed,
            "cancellation report: open gate keeps the original outcome")

let workerLifetime = BridgeDDIWorkerLifetime()
expect(!workerLifetime.isActive, "lifetime: no worker is active initially")
expect(workerLifetime.begin(), "lifetime: first worker owns the shared inputs")
let busyReport = BridgeDDIRemovalReport.busy(generation: 77, installMethod: .cryptex)
expectEqual(busyReport.outcome, .failed, "busy report: outcome is failed")
expectEqual(busyReport.errorCode, "busy", "busy report: stable busy code")
expectEqual(busyReport.mutationAttempted, false, "busy report: no mutation attempted")
expect(!workerLifetime.begin(), "lifetime: a concurrent worker is refused")
expect(workerLifetime.isActive,
       "lifetime: a refused call cannot clear the live worker")
let busyJSON = String(decoding: try! JSONEncoder().encode(busyReport), as: UTF8.self).lowercased()
expect(!busyJSON.contains("pairing"), "busy report: no pairing field")
expect(!busyJSON.contains("token"), "busy report: no token field")
workerLifetime.end()
expect(!workerLifetime.isActive, "lifetime: the owning worker releases the inputs")
expect(workerLifetime.begin(), "lifetime: a later worker may begin after the first ends")
workerLifetime.end()

// Generation fence: Stop cancels the logical removal entry, and a later
// removal receives a distinct generation.
var removalLifecycle = BridgeLifecycle(hostPid: 9001)
let removalGeneration = removalLifecycle.beginDDIRemoval(trigger: "check")
expect(removalLifecycle.isCurrent(removalGeneration),
       "lifecycle: removal begins in an active fenced generation")
expectEqual(removalLifecycle.snapshot.activity, "remove-ddi",
            "lifecycle: removal activity is explicit")
expect(!removalLifecycle.snapshot.startAttempted,
       "lifecycle: removal is not an engine start attempt")
removalLifecycle.requestEngineStop(reason: "check")
expect(!removalLifecycle.isCurrent(removalGeneration),
       "lifecycle: Stop fences the removal generation")
let nextRemovalGeneration = removalLifecycle.beginDDIRemoval(trigger: "check2")
expect(nextRemovalGeneration > removalGeneration,
       "lifecycle: a later removal gets a new generation")

// Structured report: Codable round-trip, bounded non-secret fields, and a real
// atomic write/read.
var removalReport = BridgeDDIRemovalReport(generation: 42, installMethod: .cryptex)
removalReport.outcome = .removed
removalReport.action = "uninstall-cryptex:com.apple.MobileAsset.DDI:all-versions"
removalReport.mutationAttempted = true
removalReport.preCryptex = "installed:com.apple.MobileAsset.DDI"
removalReport.preImages = []
removalReport.postCryptex = "absent"
removalReport.postImages = []
removalReport.remoteAbsent = true
removalReport.localProbeAbsent = true
removalReport.tunnel = "started-and-stopped"
let reportData = try! JSONEncoder().encode(removalReport)
let decodedReport = try! JSONDecoder().decode(BridgeDDIRemovalReport.self, from: reportData)
expectEqual(decodedReport, removalReport, "report: Codable round-trip")
expectEqual(decodedReport.mutationAttempted, true,
            "report: mutation-attempted evidence survives Codable")
let reportJSON = String(decoding: reportData, as: UTF8.self).lowercased()
expect(!reportJSON.contains("token"), "report: no token field")
expect(!reportJSON.contains("pairing"), "report: no pairing field")
expect(!reportJSON.contains("private_key"), "report: no private key field")
let reportURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("floe-bridge-removal-\(UUID().uuidString).json")
expect(BridgeDDIRemovalReport.write(removalReport, to: reportURL), "report: atomic write succeeds")
if let writtenData = try? Data(contentsOf: reportURL),
   let written = try? JSONDecoder().decode(BridgeDDIRemovalReport.self, from: writtenData) {
    expectEqual(written, removalReport, "report: written evidence reads back")
} else {
    expect(false, "report: written evidence reads back")
}
try? FileManager.default.removeItem(at: reportURL)

// MARK: - Tunnel start/stop epoch fence

var tunnelState = BridgeTunnelRunState()
let firstEpoch = tunnelState.beginStart()
expect(tunnelState.completeStart(firstEpoch), "tunnel settings completion starts loop")
expect(tunnelState.allowsRead(epoch: firstEpoch), "tunnel loop allowed for current epoch")
tunnelState.stop()
expect(!tunnelState.allowsRead(epoch: firstEpoch), "tunnel stop closes read loop")
expect(!tunnelState.completeStart(firstEpoch), "stop-before-settings completion cannot resurrect loop")
let secondEpoch = tunnelState.beginStart()
expect(!tunnelState.completeStart(firstEpoch), "old settings completion cannot complete new start")
expect(tunnelState.completeStart(secondEpoch), "new settings completion accepted")
expect(tunnelState.allowsRead(epoch: secondEpoch), "new loop allowed")
tunnelState.stop()
tunnelState.stop()
expect(!tunnelState.shouldRun, "repeated stop remains closed")

// MARK: - DDI stage-probe guard, recorder and install trace

expect(BridgeCommandPolicy.hostActions.contains("ddi_stage_probe"),
       "stage probe is a host file action")
expect(!BridgeCommandPolicy.engineActions.contains("ddi_stage_probe"),
       "stage probe is not an engine action")

let stageProbeAllowed = BridgeDDIStageProbeGuardInput(
    pairingImported: true,
    assetsComplete: true
)
expectEqual(BridgeDDIStageProbeGuard.decide(stageProbeAllowed), .allowed,
            "stage probe allowed when idle, paired and cached")

var stageProbeRefusal = BridgeDDIStageProbeGuardInput(
    terminalFault: true,
    oneShotDispatched: true,
    ddiWorkerBusy: true,
    engineRunning: true,
    autoStartEnabled: true
)
expectEqual(BridgeDDIStageProbeGuard.decide(stageProbeRefusal),
            .refused(code: BridgeDDIStageProbeGuard.terminalFaultCode),
            "terminal fault outranks every other stage-probe refusal")
stageProbeRefusal = BridgeDDIStageProbeGuardInput(
    oneShotDispatched: true,
    ddiWorkerBusy: true,
    engineRunning: true,
    autoStartEnabled: true
)
expectEqual(BridgeDDIStageProbeGuard.decide(stageProbeRefusal),
            .refused(code: BridgeDDIStageProbeGuard.oneShotCode),
            "initialized engine outranks busy/auto-recover")
var stageProbeEntryOnly = BridgeDDIStageProbeGuardInput(engineEntryObserved: true)
expectEqual(BridgeDDIStageProbeGuard.decide(stageProbeEntryOnly),
            .refused(code: BridgeDDIStageProbeGuard.oneShotCode),
            "observed test entry refuses an extra stage probe")
var stageProbeBusy = BridgeDDIStageProbeGuardInput(
    ddiWorkerBusy: true,
    engineRunning: true,
    autoStartEnabled: true
)
expectEqual(BridgeDDIStageProbeGuard.decide(stageProbeBusy),
            .refused(code: BridgeDDIStageProbeGuard.workerBusyCode),
            "live DDI worker outranks engine/auto-recover")
var stageProbeEngine = BridgeDDIStageProbeGuardInput(
    serviceRunning: true,
    autoStartEnabled: true
)
expectEqual(BridgeDDIStageProbeGuard.decide(stageProbeEngine),
            .refused(code: BridgeDDIStageProbeGuard.engineActiveCode),
            "active service refuses a stage probe")
var stageProbeAuto = BridgeDDIStageProbeGuardInput(
    autoStartEnabled: true,
    pairingImported: true,
    assetsComplete: true
)
expectEqual(BridgeDDIStageProbeGuard.decide(stageProbeAuto),
            .refused(code: BridgeDDIStageProbeGuard.autoStartCode),
            "Auto-recover refuses a stage probe")
var stageProbePairing = BridgeDDIStageProbeGuardInput(assetsComplete: true)
expectEqual(BridgeDDIStageProbeGuard.decide(stageProbePairing),
            .refused(code: BridgeDDIStageProbeGuard.pairingCode),
            "stage probe needs an imported pairing record")
var stageProbeAssets = BridgeDDIStageProbeGuardInput(pairingImported: true)
expectEqual(BridgeDDIStageProbeGuard.decide(stageProbeAssets),
            .refused(code: BridgeDDIStageProbeGuard.assetsCode),
            "stage probe never downloads missing assets")

let currentOwner = BridgeDiagnosticReportOwner(hostPid: 4343, generation: 9)
expect(currentOwner.isCurrentProcess(4343), "report owner matches its own PID")
expect(!currentOwner.isCurrentProcess(9999), "report owner rejects another PID")
expect(currentOwner.matchesGeneration(9), "report owner matches its generation")
expect(!currentOwner.matchesGeneration(10), "report owner rejects a newer generation")

var probeLifecycle = BridgeLifecycle(hostPid: 9191)
let probeFence = probeLifecycle.beginDDIStageProbe(trigger: "self-check")
expectEqual(probeLifecycle.snapshot.phase, .preparing,
            "stage probe uses an active lifecycle fence")
expect(probeLifecycle.isCurrent(probeFence.generation),
       "stage probe generation is current while active")
expectEqual(probeLifecycle.snapshot.activity, "ddi-stage-probe",
            "stage probe records its activity")
expect(!probeLifecycle.snapshot.startAttempted,
       "stage probe is not a start attempt")
expect(probeLifecycle.endDDIStageProbe(probeFence, reason: "done"),
       "stage probe ends its own fence")
expectEqual(probeLifecycle.snapshot.phase, .idle,
            "stage probe restores the previous idle phase")
expect(probeLifecycle.snapshot.activity == nil,
       "stage probe clears its activity")
expect(!probeLifecycle.endDDIStageProbe(probeFence, reason: "late"),
       "late stage-probe completion is refused")

var stoppedProbeLifecycle = BridgeLifecycle(hostPid: 9192)
_ = stoppedProbeLifecycle.beginStart(trigger: "fixture")
_ = stoppedProbeLifecycle.fence(reason: "fixture-stop")
let stoppedFence = stoppedProbeLifecycle.beginDDIStageProbe(trigger: "stopped")
expectEqual(stoppedProbeLifecycle.snapshot.phase, .preparing,
            "stage probe fences from a stopped state")
expect(stoppedProbeLifecycle.endDDIStageProbe(stoppedFence, reason: "done"),
       "stage probe end accepted from stopped")
expectEqual(stoppedProbeLifecycle.snapshot.phase, .stopped,
            "stage probe restores the stopped phase")

var cancelledProbeLifecycle = BridgeLifecycle(hostPid: 9193)
let cancelledFence = cancelledProbeLifecycle.beginDDIStageProbe(trigger: "cancel")
expect(cancelledProbeLifecycle.requestEngineStop(reason: "stop-during-probe"),
       "Stop accepts a live stage-probe fence")
expect(!cancelledProbeLifecycle.endDDIStageProbe(cancelledFence, reason: "late"),
       "Stop wins over stage-probe completion")
expectEqual(cancelledProbeLifecycle.snapshot.phase, .stopped,
            "Stop keeps the stopped phase after a probe")
expect(cancelledProbeLifecycle.snapshot.activity == nil,
       "Stop clears the stage-probe activity")

let stageFixedStart = Date(timeIntervalSince1970: 1_700_000_000)
let stageRecorder = BridgeDDIStageProbeRecorder(
    hostPid: 4343,
    generation: 9,
    installMethod: .cryptex,
    startedAt: stageFixedStart
)
expect(stageRecorder.begin(.tssReachability, at: stageFixedStart.addingTimeInterval(1)),
       "recorder begins the TSS stage")
expect(!stageRecorder.begin(.tunnelStart, at: stageFixedStart.addingTimeInterval(1)),
       "recorder refuses two simultaneous stages")
let tssFixtureReport = BridgeTSSReachabilityReport.reached(
    httpStatus: 200,
    connectMilliseconds: 12,
    headersMilliseconds: 30,
    durationMilliseconds: 31
)
stageRecorder.setTSS(tssFixtureReport)
expect(stageRecorder.complete(.tssReachability, at: stageFixedStart.addingTimeInterval(2),
                              detail: "httpStatus=200"),
       "recorder completes the TSS stage")
expect(!stageRecorder.complete(.tssReachability, at: stageFixedStart.addingTimeInterval(3)),
       "recorder refuses a duplicate completion")
expect(stageRecorder.begin(.cachedAssetsLoad, at: stageFixedStart.addingTimeInterval(3)),
       "recorder begins the assets stage")
expect(stageRecorder.fail(.cachedAssetsLoad, at: stageFixedStart.addingTimeInterval(4),
                          code: "ffi-5"),
       "recorder records an FFI error code")
expect(stageRecorder.finish(.failed, at: stageFixedStart.addingTimeInterval(10),
                            errorCode: "assets-load"),
       "recorder finishes the failed report")
let stageDone = stageRecorder.snapshot(at: stageFixedStart.addingTimeInterval(10))
expectEqual(stageDone.outcome, .failed, "recorder retains the failed outcome")
expectEqual(stageDone.stages.count, 2, "recorder retains both stages")
expectEqual(stageDone.stages[0].durationMilliseconds, 1_000,
            "recorder measures the completed stage")
expectEqual(stageDone.stages[1].errorCode, "ffi-5",
            "recorder retains the failed stage code")
expectEqual(stageDone.elapsedMilliseconds, 10_000,
            "recorder reports elapsed milliseconds")
expectEqual(stageDone.tss?.httpStatus, 200, "recorder retains the TSS summary")
expect(!stageRecorder.heartbeat(at: stageFixedStart.addingTimeInterval(20)),
       "a finished report does not heartbeat")
expect(!stageRecorder.finish(.completed, at: stageFixedStart.addingTimeInterval(20)),
       "a finished report cannot be finished twice")

let hungProbe = BridgeDDIStageProbeRecorder(
    hostPid: 4444,
    generation: 10,
    installMethod: .cryptex,
    startedAt: stageFixedStart
)
expect(hungProbe.begin(.personalizationIdentifiers,
                       at: stageFixedStart.addingTimeInterval(1)),
       "hung probe enters the read call")
expect(hungProbe.heartbeat(at: stageFixedStart.addingTimeInterval(16)),
       "hung probe heartbeat is accepted while running")
let hungSnapshot = hungProbe.snapshot(at: stageFixedStart.addingTimeInterval(16))
expectEqual(hungSnapshot.currentStage,
            BridgeDDIProbeStage.personalizationIdentifiers.rawValue,
            "hung probe still reports the entered stage")
expect(hungSnapshot.stages[0].durationMilliseconds == nil,
       "an entered call with no return has no duration")
expectEqual(hungSnapshot.outcome, .running, "hung probe stays running")
expect(hungProbe.finish(.cancelled, at: stageFixedStart.addingTimeInterval(17)),
       "cancelled probe finishes its report")
let hungCancelled = hungProbe.snapshot(at: stageFixedStart.addingTimeInterval(17))
expectEqual(hungCancelled.outcome, .cancelled, "cancelled probe outcome retained")
expectEqual(hungCancelled.currentStage,
            BridgeDDIProbeStage.personalizationIdentifiers.rawValue,
            "a consumed read call is not claimed as returned")

let personalizedProbe = BridgeDDIStageProbeRecorder(
    hostPid: 4545,
    generation: 11,
    installMethod: .personalized,
    startedAt: stageFixedStart
)
expect(!personalizedProbe.snapshot().cryptexProbeApplicable,
       "personalized OS marks cryptex stages inapplicable")
personalizedProbe.note(String(repeating: "x", count: 260))
expect(personalizedProbe.finish(.notApplicable, at: stageFixedStart.addingTimeInterval(1)),
       "personalized probe reports not-applicable")
for index in 0..<30 {
    personalizedProbe.note("fixture-note-\(index)")
}
let personalizedSnapshot = personalizedProbe.snapshot(at: stageFixedStart.addingTimeInterval(1))
expect(personalizedSnapshot.notes.count <= BridgeDDIStageProbeLimits.maximumNotes,
       "probe notes stay bounded")
expect(personalizedSnapshot.notes.allSatisfy {
    $0.count <= BridgeDDIStageProbeLimits.maximumNoteCharacters
}, "each probe note stays bounded")

let probeReportURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("floe-bridge-stage-probe-\(UUID().uuidString).json")
expect(stageRecorder.write(to: probeReportURL), "stage-probe report writes atomically")
if let probeData = try? Data(contentsOf: probeReportURL),
   let decodedProbe = try? JSONDecoder().decode(BridgeDDIStageProbeReport.self, from: probeData) {
    expectEqual(decodedProbe.hostPid, 4343, "stage-probe report retains the owning PID")
    expectEqual(decodedProbe.generation, 9, "stage-probe report retains the owning generation")
    expectEqual(decodedProbe.outcome, .failed, "stage-probe report round-trips its outcome")
    let probeText = String(decoding: probeData, as: UTF8.self).lowercased()
    expect(!probeText.contains("private_key"), "stage-probe report has no private key")
    expect(!probeText.contains("ecid"), "stage-probe report has no ECID")
    expect(!probeText.contains("udid"), "stage-probe report has no UDID")
    expect(!probeText.contains("\"ticket\":"), "stage-probe report has no TSS ticket field")
    expect(probeData.count <= BridgeDDIStageProbeLimits.maximumReportBytes,
           "stage-probe report stays within the byte bound")
} else {
    expect(false, "stage-probe report reads back")
}
try? FileManager.default.removeItem(at: probeReportURL)

let installTrace = BridgeDDIInstallTrace(
    hostPid: 4646,
    generation: 12,
    installMethod: .cryptex,
    startedAt: stageFixedStart
)
expectEqual(installTrace.snapshot(at: stageFixedStart).stage, .preparing,
            "install trace starts before any observed stage")
expect(!installTrace.installEntered(at: stageFixedStart.addingTimeInterval(1)),
       "cryptex cannot enter install before the assets load")
let traceCounts = BridgeDDIAssetByteCounts(
    buildManifest: 100,
    image: 15_895_040,
    trustCache: 1_895,
    cryptexInfo: 430,
    rootHash: 229
)
expect(installTrace.assetsBegan(traceCounts, at: stageFixedStart.addingTimeInterval(1)),
       "install trace records the assets begin")
expectEqual(installTrace.snapshot(at: stageFixedStart.addingTimeInterval(2)).stage,
            .assetsLoading, "assets-loading is the observable stage")
expect(installTrace.assetsLoaded(at: stageFixedStart.addingTimeInterval(2)),
       "install trace records the assets completion")
expect(installTrace.installEntered(at: stageFixedStart.addingTimeInterval(3)),
       "install trace records the opaque call entry")
expect(installTrace.heartbeat(at: stageFixedStart.addingTimeInterval(18)),
       "install heartbeat is accepted while the FFI is live")
let installPending = installTrace.snapshot(at: stageFixedStart.addingTimeInterval(18))
expectEqual(installPending.stage, .opaqueInstallEntered,
            "heartbeat keeps the entered stage instead of inventing progress")
expectEqual(installPending.heartbeats, 1, "install heartbeat is counted")
expectEqual(installPending.elapsedMilliseconds, 18_000,
            "install heartbeat reports elapsed time")
expectEqual(installPending.assets?.image, 15_895_040,
            "install trace retains asset byte counts")
expectEqual(installPending.hostPid, 4646, "install progress retains the owning PID")
expectEqual(installPending.generation, 12, "install progress retains the owning generation")
expect(installTrace.installFailed(code: 5, at: stageFixedStart.addingTimeInterval(20)),
       "install trace records the FFI failure")
let installFailed = installTrace.snapshot(at: stageFixedStart.addingTimeInterval(20))
expectEqual(installFailed.outcome, .failed, "install failure outcome retained")
expectEqual(installFailed.stage, .opaqueInstallEntered,
            "install failure does not invent a later stage")
expectEqual(installFailed.errorCode, "ffi-5", "install failure retains the numeric code")
expect(!installTrace.finish(.returned, at: stageFixedStart.addingTimeInterval(21)),
       "a failed install cannot be re-finished as returned")

let returnedTrace = BridgeDDIInstallTrace(
    hostPid: 4747,
    generation: 13,
    installMethod: .cryptex,
    startedAt: stageFixedStart
)
_ = returnedTrace.assetsBegan(traceCounts, at: stageFixedStart.addingTimeInterval(1))
_ = returnedTrace.assetsLoaded(at: stageFixedStart.addingTimeInterval(2))
_ = returnedTrace.installEntered(at: stageFixedStart.addingTimeInterval(3))
expect(returnedTrace.installReturned(at: stageFixedStart.addingTimeInterval(4)),
       "install trace records the opaque call return")
let returnedSnapshot = returnedTrace.snapshot(at: stageFixedStart.addingTimeInterval(4))
expectEqual(returnedSnapshot.outcome, .returned, "returned install outcome retained")
expectEqual(returnedSnapshot.stage, .opaqueInstallReturned,
            "returned stage is the only post-call stage")

let personalizedTrace = BridgeDDIInstallTrace(
    hostPid: 4848,
    generation: 14,
    installMethod: .personalized,
    startedAt: stageFixedStart
)
expect(!personalizedTrace.assetsBegan(traceCounts),
       "personalized trace has no cryptex asset stage")
expect(personalizedTrace.installEntered(at: stageFixedStart.addingTimeInterval(1)),
       "personalized trace enters from preparing")
let notRunTrace = BridgeDDIInstallTrace(
    hostPid: 4949,
    generation: 15,
    installMethod: .cryptex,
    startedAt: stageFixedStart
)
expect(notRunTrace.finish(.notRun, errorCode: "already-mounted"),
       "an already-mounted worker records not-run")
expectEqual(notRunTrace.snapshot().outcome, .notRun,
            "not-run outcome retained without a fake install stage")

let progressURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("floe-bridge-install-progress-\(UUID().uuidString).json")
expect(returnedTrace.write(to: progressURL), "install progress writes atomically")
if let progressData = try? Data(contentsOf: progressURL),
   let decodedProgress = try? JSONDecoder().decode(BridgeDDIInstallProgress.self, from: progressData) {
    expectEqual(decodedProgress.hostPid, 4747, "install progress round-trips the owning PID")
    expectEqual(decodedProgress.generation, 13, "install progress round-trips the generation")
    expectEqual(decodedProgress.outcome, .returned, "install progress round-trips outcome")
    let progressText = String(decoding: progressData, as: UTF8.self).lowercased()
    expect(!progressText.contains("private_key"), "install progress has no private key")
    expect(!progressText.contains("ecid"), "install progress has no ECID")
    expect(!progressText.contains("nonce"), "install progress has no nonce field")
    expect(progressData.count <= BridgeDDIInstallTraceLimits.maximumProgressBytes,
           "install progress stays within the byte bound")
} else {
    expect(false, "install progress reads back")
}
try? FileManager.default.removeItem(at: progressURL)

// MARK: - Apple TSS reachability report and one-shot completion

expectEqual(BridgeTSSProbePolicy.host, "gs.apple.com", "TSS target is fixed")
expectEqual(BridgeTSSProbePolicy.port, 80, "TSS probe uses plain port 80")
expectEqual(BridgeTSSProbePolicy.method, "HEAD", "TSS probe sends no request body")
expectEqual(BridgeTSSProbePolicy.path, "/TSS/controller?action=2",
            "TSS probe uses the known controller path")
expectEqual(BridgeTSSProbePolicy.totalDeadlineSeconds, 10, "TSS probe has a 10 s deadline")
expectEqual(BridgeTSSProbePolicy.maximumHeaderBytes, 8_192,
            "TSS probe bounds response headers")

let tssHeadFixture = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)
if let parsedHead = BridgeTSSResponseHeadParser.parse(tssHeadFixture) {
    expectEqual(parsedHead.httpStatus, 200, "TSS parser reads the status code")
    expectEqual(parsedHead.headerBytes, tssHeadFixture.count,
                "TSS parser bounds the header length")
} else {
    expect(false, "TSS parser accepts a complete header")
}
if let errorHead = BridgeTSSResponseHeadParser.parse(
    Data("HTTP/1.1 503 Service Unavailable\r\n\r\n".utf8)
) {
    expectEqual(errorHead.httpStatus, 503,
                "a 5xx response still proves reachability")
} else {
    expect(false, "TSS parser accepts a 5xx response head")
}
expect(BridgeTSSResponseHeadParser.parse(Data("HTTP/1.1 200 OK\r\n".utf8)) == nil,
       "TSS parser rejects an incomplete head")
expect(BridgeTSSResponseHeadParser.parse(Data("HTTP/2 200\r\n\r\n".utf8)) == nil,
       "TSS parser rejects a non-HTTP/1.x status line")
expect(BridgeTSSResponseHeadParser.parse(Data("HTTP/1.1 abc OK\r\n\r\n".utf8)) == nil,
       "TSS parser rejects a non-numeric status")
expect(BridgeTSSResponseHeadParser.parse(Data("HTTP/1.1 99 Early\r\n\r\n".utf8)) == nil,
       "TSS parser rejects an out-of-range status")
var oversizedHead = Data(repeating: 0x41, count: 8_193)
oversizedHead.append(Data("\r\n\r\n".utf8))
expect(BridgeTSSResponseHeadParser.parse(oversizedHead) == nil,
       "TSS parser rejects an oversized head")
let headerPlusBody = Data("HTTP/1.1 200 OK\r\n\r\n".utf8)
    + Data(repeating: 0x42, count: 9_000)
if let parsedWithBody = BridgeTSSResponseHeadParser.parse(headerPlusBody) {
    expectEqual(parsedWithBody.httpStatus, 200,
                "TSS parser bounds the head even when a body follows")
    expectEqual(parsedWithBody.headerBytes, 19,
                "TSS parser reports only the header byte count")
} else {
    expect(false, "TSS parser accepts a head followed by a body")
}

expectEqual(BridgeTSSProbeErrorCategory.posix(.ECONNREFUSED), "connection-refused",
            "TSS error category: refused")
expectEqual(BridgeTSSProbeErrorCategory.posix(.ETIMEDOUT), "timed-out",
            "TSS error category: timeout")
expectEqual(BridgeTSSProbeErrorCategory.posix(.ENETUNREACH), "network-unreachable",
            "TSS error category: unreachable")
expect(BridgeTSSProbeErrorCategory.posix(.EIO).hasPrefix("posix-"),
       "TSS error category never exposes a raw address")

let tssReport = BridgeTSSReachabilityReport.reached(
    httpStatus: 200,
    connectMilliseconds: 12,
    headersMilliseconds: 30,
    durationMilliseconds: 31
)
expectEqual(tssReport.outcome, .httpResponse, "TSS report outcome")
expectEqual(tssReport.httpStatus, 200, "TSS report status")
expectEqual(tssReport.dns, .resolved, "TSS report DNS state")
expect(tssReport.note.contains("does not prove the TSS POST"),
       "TSS report explicitly limits its reachability claim")
let tssDictionary = tssReport.dictionary()
expect(tssDictionary["httpStatus"] as? Int == 200, "TSS dictionary status")
expect(tssDictionary["ipAddress"] == nil && tssDictionary["headers"] == nil,
       "TSS dictionary has no address or raw headers")
expect(tssDictionary["body"] == nil, "TSS dictionary has no body")

final class OneShotProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var accepted = 0
    private(set) var winner: Int?
    func record(_ index: Int) {
        lock.lock()
        accepted += 1
        winner = index
        lock.unlock()
    }
}
let oneShotGate = BridgeOneShotValue<Int>()
let oneShotBox = OneShotProbeBox()
DispatchQueue.concurrentPerform(iterations: 64) { index in
    if oneShotGate.deliver(index) {
        oneShotBox.record(index)
    }
}
expectEqual(oneShotBox.accepted, 1, "one-shot completion has exactly one winner")
expectEqual(oneShotGate.current, oneShotBox.winner,
            "one-shot completion retains the winner's value")
expect(!oneShotGate.deliver(999), "one-shot completion ignores a late value")

// MARK: - Packet-tunnel provider snapshot readback

@MainActor func tunnelSnapshotFixture(
    schema: Int = 1,
    epoch: Int = 3,
    readLoopActive: Bool = true,
    shouldRun: Bool = true,
    received: Int = 42,
    reflected: Int = 40,
    rejected: Int = 2,
    fragments: Int = 0,
    interfaceAddress: String = BridgeTransport.interfaceAddress,
    peerAddress: String = BridgeTransport.peerAddress,
    lastRejection: String? = "lengthMismatch"
) -> [String: Any] {
    var reflector: [String: Any] = [
        "received": received,
        "reflected": reflected,
        "rejected": rejected,
        "fragments": fragments,
        "interfaceAddress": interfaceAddress,
        "peerAddress": peerAddress,
    ]
    if let lastRejection { reflector["lastRejection"] = lastRejection }
    return [
        "schema": schema,
        "epoch": epoch,
        "startedAt": "2026-11-01T00:00:00.000Z",
        "uptimeSeconds": 12.5,
        "readLoopActive": readLoopActive,
        "shouldRun": shouldRun,
        "reflector": reflector,
    ]
}

let tunnelFixtureData = try! JSONSerialization.data(withJSONObject: tunnelSnapshotFixture())
if let parsedTunnel = BridgeTunnelProviderSnapshot.parse(
    tunnelFixtureData,
    receivedAt: stageFixedStart
) {
    expectEqual(parsedTunnel.epoch, 3, "tunnel snapshot epoch")
    expectEqual(parsedTunnel.received, 42, "tunnel snapshot received counter")
    expectEqual(parsedTunnel.reflected, 40, "tunnel snapshot reflected counter")
    expectEqual(parsedTunnel.rejected, 2, "tunnel snapshot rejected counter")
    expectEqual(parsedTunnel.lastRejection, "lengthMismatch", "tunnel snapshot rejection kind")
    expect(parsedTunnel.readLoopActive && parsedTunnel.shouldRun,
           "tunnel snapshot run flags")
    let tunnelDictionary = parsedTunnel.dictionary()
    expect(tunnelDictionary["epoch"] as? UInt64 == 3, "tunnel dictionary epoch")
    expect(tunnelDictionary["received"] as? UInt64 == 42, "tunnel dictionary counter")
    expect(tunnelDictionary["interfaceAddress"] as? String == BridgeTransport.interfaceAddress,
           "tunnel dictionary address pair")
} else {
    expect(false, "tunnel snapshot parses the extension shape")
}
@MainActor func tunnelSnapshotRejects(_ object: [String: Any], _ name: String) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else {
        expect(false, name)
        return
    }
    expect(BridgeTunnelProviderSnapshot.parse(data) == nil, name)
}
tunnelSnapshotRejects(tunnelSnapshotFixture(schema: 2), "tunnel snapshot rejects an unknown schema")
tunnelSnapshotRejects(tunnelSnapshotFixture(epoch: 0), "tunnel snapshot rejects a zero epoch")
tunnelSnapshotRejects(tunnelSnapshotFixture(reflected: 50), "tunnel snapshot rejects reflected > received")
tunnelSnapshotRejects(tunnelSnapshotFixture(fragments: 3), "tunnel snapshot rejects fragments > rejected")
tunnelSnapshotRejects(tunnelSnapshotFixture(interfaceAddress: "10.0.0.2"),
                      "tunnel snapshot rejects a foreign interface address")
tunnelSnapshotRejects(tunnelSnapshotFixture(peerAddress: "10.0.0.1"),
                      "tunnel snapshot rejects a foreign peer address")
tunnelSnapshotRejects(tunnelSnapshotFixture(lastRejection: "has spaces"),
                      "tunnel snapshot rejects a malformed rejection name")
var oversizedTunnel = tunnelSnapshotFixture()
oversizedTunnel["padding"] = String(repeating: "x", count: 8_200)
tunnelSnapshotRejects(oversizedTunnel, "tunnel snapshot rejects an oversized payload")
var numericBoolTunnel = tunnelSnapshotFixture()
numericBoolTunnel["readLoopActive"] = 1
tunnelSnapshotRejects(numericBoolTunnel, "tunnel snapshot rejects a non-boolean flag")
var fractionalCounter = tunnelSnapshotFixture()
var fractionalReflector = fractionalCounter["reflector"] as? [String: Any] ?? [:]
fractionalReflector["received"] = 1.5
fractionalCounter["reflector"] = fractionalReflector
tunnelSnapshotRejects(fractionalCounter, "tunnel snapshot rejects a fractional counter")

let tunnelStore = BridgeTunnelSnapshotStore()
let storeT0 = Date(timeIntervalSince1970: 1_700_001_000)
let firstSequence = tunnelStore.beginRequest(hostPid: 55, generation: 21, at: storeT0)
guard let firstSnapshot = BridgeTunnelProviderSnapshot.parse(
    tunnelFixtureData,
    receivedAt: storeT0.addingTimeInterval(0.1)
) else {
    fatalError("tunnel fixture must parse")
}
expect(tunnelStore.record(.available(firstSnapshot), sequence: firstSequence,
                          at: storeT0.addingTimeInterval(0.2)),
       "tunnel store records the first snapshot")
expect(!tunnelStore.record(.timeout, sequence: firstSequence,
                           at: storeT0.addingTimeInterval(0.3)),
       "tunnel store rejects a duplicate sequence")
let secondSequence = tunnelStore.beginRequest(hostPid: 55, generation: 21,
                                             at: storeT0.addingTimeInterval(2))
expect(tunnelStore.record(.timeout, sequence: secondSequence,
                          at: storeT0.addingTimeInterval(2.5)),
       "tunnel store records a timeout")
let timeoutStatus = tunnelStore.status(at: storeT0.addingTimeInterval(3),
                                       processIdentifier: 55)
expectEqual(timeoutStatus.state, .timeout, "tunnel store reports the newest state")
expectEqual(timeoutStatus.samples, 2, "tunnel store counts samples")
expectEqual(timeoutStatus.snapshot?.epoch, 3, "tunnel store keeps the last-known snapshot")
expectEqual(timeoutStatus.ageMilliseconds, 500, "tunnel store reports sample age")
expect(!timeoutStatus.stale, "a fresh timeout is not stale")
expect(timeoutStatus.samplerIsCurrentProcess, "tunnel store sampler PID is current")
expectEqual(timeoutStatus.probeGeneration, 21, "tunnel store retains the probe generation")
expect(!tunnelStore.record(.available(firstSnapshot), sequence: firstSequence,
                           at: storeT0.addingTimeInterval(3.5)),
       "tunnel store ignores a late old-sequence result")
expect(!tunnelStore.record(.timeout, sequence: secondSequence + 100,
                           at: storeT0.addingTimeInterval(3.5)),
       "tunnel store ignores an unissued sequence")
let staleStatus = tunnelStore.status(at: storeT0.addingTimeInterval(20),
                                     processIdentifier: 99)
expect(staleStatus.stale, "tunnel status becomes stale with age")
expect(staleStatus.snapshotStale, "last-known snapshot becomes stale with age")
expectEqual(staleStatus.samplerHostPid, 55, "tunnel store retains the sampler PID")
expect(!staleStatus.samplerIsCurrentProcess, "another process is not the current sampler")
let tunnelStatusDictionary = timeoutStatus.dictionary()
expect(tunnelStatusDictionary["state"] as? String == "timeout",
       "tunnel status dictionary state")
expect(tunnelStatusDictionary["snapshot"] is [String: Any],
       "tunnel status dictionary embeds the last-known snapshot")
expect(tunnelStatusDictionary["payload"] == nil, "tunnel status dictionary has no payload")

// MARK: - Cached DDI byte-count measurement

let assetFixtureRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("floe-bridge-assets-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: assetFixtureRoot, withIntermediateDirectories: true)
try? Data(repeating: 0, count: 4_096).write(
    to: assetFixtureRoot.appendingPathComponent(BridgeDDIComponent.image.rawValue)
)
try? Data(repeating: 0, count: 128).write(
    to: assetFixtureRoot.appendingPathComponent(BridgeDDIComponent.buildManifest.rawValue)
)
try? Data(repeating: 0, count: 64).write(
    to: assetFixtureRoot.appendingPathComponent(BridgeDDIComponent.trustCache.rawValue)
)
try? Data(repeating: 0, count: 32).write(
    to: assetFixtureRoot.appendingPathComponent(BridgeDDIComponent.cryptexInfo.rawValue)
)
try? Data(repeating: 0, count: 16).write(
    to: assetFixtureRoot.appendingPathComponent(BridgeDDIComponent.rootHash.rawValue)
)
let measuredAssets = BridgeDDIAssetByteCounts.measure(
    directory: assetFixtureRoot,
    method: .cryptex
)
expectEqual(measuredAssets.image, 4_096, "asset measurement reads the image size")
expectEqual(measuredAssets.buildManifest, 128, "asset measurement reads the manifest size")
expectEqual(measuredAssets.trustCache, 64, "asset measurement reads the trustcache size")
expectEqual(measuredAssets.cryptexInfo, 32, "asset measurement reads the cryptex info size")
expectEqual(measuredAssets.rootHash, 16, "asset measurement reads the root hash size")
expectEqual(measuredAssets.total, 4_336, "asset measurement totals the components")
expect(measuredAssets.summary.contains("imageBytes=4096"),
       "asset summary contains only numeric sizes")
let measuredPersonalized = BridgeDDIAssetByteCounts.measure(
    directory: assetFixtureRoot,
    method: .personalized
)
expectEqual(measuredPersonalized.cryptexInfo, 0,
            "personalized measurement omits cryptex-only files")
expectEqual(measuredPersonalized.rootHash, 0,
            "personalized measurement omits the root hash")
let missingAssets = BridgeDDIAssetByteCounts.measure(
    directory: assetFixtureRoot.appendingPathComponent("missing", isDirectory: true),
    method: .cryptex
)
expectEqual(missingAssets.total, 0, "missing cached files measure as zero")
try? FileManager.default.removeItem(at: assetFixtureRoot)

// MARK: - Process/scene liveness freshness and bounded transitions

let livenessNow = Date()
let missingBeat = BridgeLivenessBeatStatus.mainThread(
    record: nil,
    now: livenessNow,
    currentProcessIdentifier: 77
)
expectEqual(missingBeat.freshness, .missing, "liveness missing record is missing")
expect(!missingBeat.present, "liveness missing record is not present")

let currentMainRecord: [String: Any] = [
    "count": 3,
    "lastBeatAt": BridgeClock.timestamp(livenessNow.addingTimeInterval(-1)),
    "processIdentifier": 77,
    "source": "main-runloop-timer",
]
let currentMainBeat = BridgeLivenessBeatStatus.mainThread(
    record: currentMainRecord,
    now: livenessNow,
    currentProcessIdentifier: 77
)
expect(currentMainBeat.isCurrentProcess, "current main beat PID is current")
expectEqual(currentMainBeat.count, 3, "current main beat count retained")
expectEqual(currentMainBeat.freshness, .current, "recent main beat is current")
expect((currentMainBeat.ageMilliseconds ?? 0) >= 900 &&
       (currentMainBeat.ageMilliseconds ?? 0) <= 1_100,
       "current main beat age is bounded")

let oldMainRecord: [String: Any] = [
    "count": 4,
    "lastBeatAt": BridgeClock.timestamp(livenessNow.addingTimeInterval(-30)),
    "processIdentifier": 77,
]
let oldMainBeat = BridgeLivenessBeatStatus.mainThread(
    record: oldMainRecord,
    now: livenessNow,
    currentProcessIdentifier: 77
)
expectEqual(oldMainBeat.freshness, .stale, "old main beat is stale")

let foreignBeat = BridgeLivenessBeatStatus.dispatch(
    record: [
        "count": 9,
        "lastBeatAt": BridgeClock.timestamp(livenessNow),
        "processIdentifier": 78,
    ],
    now: livenessNow,
    currentProcessIdentifier: 77
)
expect(!foreignBeat.isCurrentProcess, "foreign PID beat is not current")
expectEqual(foreignBeat.freshness, .stale, "foreign PID beat is always stale")

let malformedBeat = BridgeLivenessBeatStatus.mainThread(
    record: [
        "count": 1,
        "lastBeatAt": "not-a-timestamp",
        "processIdentifier": 77,
    ],
    now: livenessNow,
    currentProcessIdentifier: 77
)
expectEqual(malformedBeat.freshness, .unknown, "malformed beat timestamp is unknown")

let futureBeat = BridgeLivenessBeatStatus.mainThread(
    record: [
        "count": 1,
        "lastBeatAt": BridgeClock.timestamp(livenessNow.addingTimeInterval(60)),
        "processIdentifier": 77,
    ],
    now: livenessNow,
    currentProcessIdentifier: 77
)
expectEqual(futureBeat.freshness, .unknown, "far-future beat timestamp is unknown")

let toleratedFutureBeat = BridgeLivenessBeatStatus.mainThread(
    record: [
        "count": 1,
        "lastBeatAt": BridgeClock.timestamp(livenessNow.addingTimeInterval(2)),
        "processIdentifier": 77,
    ],
    now: livenessNow,
    currentProcessIdentifier: 77
)
expectEqual(toleratedFutureBeat.freshness, .current, "small clock skew is tolerated")
expect(toleratedFutureBeat.ageMilliseconds == 0, "small negative age clamps to zero")

let engineBeatRecord: [String: Any] = [
    "heartbeatCount": 9,
    "lastHeartbeatAt": BridgeClock.timestamp(livenessNow.addingTimeInterval(-1)),
    "processIdentifier": 77,
    "source": "BridgeCore test engine dispatch timer",
]
let currentEngineBeat = BridgeLivenessBeatStatus.engineHeartbeat(
    record: engineBeatRecord,
    now: livenessNow,
    currentProcessIdentifier: 77
)
expectEqual(currentEngineBeat.count, 9, "engine heartbeat count is read")
expectEqual(currentEngineBeat.freshness, .current, "current engine heartbeat is current")

var readySnapshot = BridgeSnapshot()
readySnapshot.hostPid = 77
readySnapshot.phase = .ready
readySnapshot.generation = 6
readySnapshot.serviceRunning = true
readySnapshot.oneShotDispatched = true
readySnapshot.dispatchedGeneration = 5
readySnapshot.engineEntryObserved = true
readySnapshot.engineRunning = true
readySnapshot.enginePid = 77

let dispatchRecord: [String: Any] = [
    "count": 4,
    "lastBeatAt": BridgeClock.timestamp(livenessNow.addingTimeInterval(-1)),
    "processIdentifier": 77,
    "source": "process-liveness-dispatch-timer",
]
let liveRecord: [String: Any] = [
    "schema": 1,
    "processIdentifier": 77,
    "applicationState": "active",
    "sceneState": "foregroundActive",
    "stateObservedAt": BridgeClock.timestamp(livenessNow.addingTimeInterval(-1)),
    "mainThreadBeat": currentMainRecord,
    "dispatchBeat": dispatchRecord,
]
let healthyLiveness = BridgeLivenessStatus.evaluate(
    snapshot: readySnapshot,
    liveness: liveRecord,
    engineHeartbeat: engineBeatRecord,
    now: livenessNow,
    currentProcessIdentifier: 77
)
expectEqual(healthyLiveness.health, .healthy, "ready snapshot with current beats is healthy")
expectEqual(healthyLiveness.healthReason, "all-heartbeats-current", "healthy reason")
expectEqual(healthyLiveness.applicationState, "active", "healthy liveness reads app state")
expectEqual(healthyLiveness.sceneState, "foregroundActive", "healthy liveness reads scene state")
expect(healthyLiveness.applicationStateIsCurrent, "app state is current with a current main beat")
expectEqual(healthyLiveness.processScheduling, .current, "dispatch current means process scheduling")
expectEqual(healthyLiveness.mainThreadResponsive, .current, "main beat current means responsive")

var staleEngineRecord = engineBeatRecord
staleEngineRecord["lastHeartbeatAt"] = BridgeClock.timestamp(livenessNow.addingTimeInterval(-30))
let staleEngineLiveness = BridgeLivenessStatus.evaluate(
    snapshot: readySnapshot,
    liveness: liveRecord,
    engineHeartbeat: staleEngineRecord,
    now: livenessNow,
    currentProcessIdentifier: 77
)
expectEqual(staleEngineLiveness.health, .readyUnconfirmed,
            "stale ready marker is not called healthy")
expect(staleEngineLiveness.healthReason.contains("engine-heartbeat-stale"),
       "stale engine heartbeat names its reason")

var staleMainRecord: [String: Any] = liveRecord
staleMainRecord["mainThreadBeat"] = oldMainRecord
let stalledMainLiveness = BridgeLivenessStatus.evaluate(
    snapshot: readySnapshot,
    liveness: staleMainRecord,
    engineHeartbeat: engineBeatRecord,
    now: livenessNow,
    currentProcessIdentifier: 77
)
expectEqual(stalledMainLiveness.health, .readyUnconfirmed,
            "stale main beat does not look healthy")
expect(stalledMainLiveness.healthReason.contains("main-thread-stale"),
       "stale main beat names its reason")
expectEqual(stalledMainLiveness.processScheduling, .current,
            "a stopped MainActor is distinguished from a stopped dispatch beat")
expectEqual(stalledMainLiveness.mainThreadResponsive, .stale,
            "stalled main beat is not responsive")
expect(!stalledMainLiveness.applicationStateIsCurrent,
       "stale main beat makes the last app state non-current")

let oldDispatchRecord: [String: Any] = [
    "count": 5,
    "lastBeatAt": BridgeClock.timestamp(livenessNow.addingTimeInterval(-30)),
    "processIdentifier": 77,
    "source": "process-liveness-dispatch-timer",
]
var suspendedRecord: [String: Any] = liveRecord
suspendedRecord["mainThreadBeat"] = oldMainRecord
suspendedRecord["dispatchBeat"] = oldDispatchRecord
let suspendedLiveness = BridgeLivenessStatus.evaluate(
    snapshot: readySnapshot,
    liveness: suspendedRecord,
    engineHeartbeat: staleEngineRecord,
    now: livenessNow,
    currentProcessIdentifier: 77
)
expectEqual(suspendedLiveness.mainThreadResponsive, .stale,
            "suspended main beat is stale")
expectEqual(suspendedLiveness.processScheduling, .stale,
            "suspended dispatch beat is stale")
expectEqual(suspendedLiveness.health, .readyUnconfirmed,
            "both stale beats keep a ready marker unconfirmed")

let missingLiveness = BridgeLivenessStatus.evaluate(
    snapshot: readySnapshot,
    liveness: nil,
    engineHeartbeat: engineBeatRecord,
    now: livenessNow,
    currentProcessIdentifier: 77
)
expectEqual(missingLiveness.health, .readyUnconfirmed, "missing liveness is not healthy")
expect(!missingLiveness.recordIsCurrentProcess, "missing liveness has no current owner")

var foreignLiveRecord: [String: Any] = liveRecord
foreignLiveRecord["processIdentifier"] = 78
let foreignLiveness = BridgeLivenessStatus.evaluate(
    snapshot: readySnapshot,
    liveness: foreignLiveRecord,
    engineHeartbeat: engineBeatRecord,
    now: livenessNow,
    currentProcessIdentifier: 77
)
expect(!foreignLiveness.recordIsCurrentProcess, "foreign liveness record is not current")
expectEqual(foreignLiveness.applicationState, "unknown", "foreign liveness app state is unknown")
expectEqual(foreignLiveness.health, .readyUnconfirmed, "foreign liveness cannot be healthy")

var failedSnapshot = readySnapshot
failedSnapshot.terminalFault = true
failedSnapshot.phase = .failed
let failedLiveness = BridgeLivenessStatus.evaluate(
    snapshot: failedSnapshot,
    liveness: liveRecord,
    engineHeartbeat: engineBeatRecord,
    now: livenessNow,
    currentProcessIdentifier: 77
)
expectEqual(failedLiveness.health, .failed, "terminal fault derives failed health")

var stoppedSnapshot = readySnapshot
stoppedSnapshot.phase = .stopped
stoppedSnapshot.serviceRunning = false
stoppedSnapshot.engineRunning = false
expectEqual(BridgeLivenessStatus.evaluate(
    snapshot: stoppedSnapshot,
    liveness: liveRecord,
    engineHeartbeat: staleEngineRecord,
    now: livenessNow,
    currentProcessIdentifier: 77
).health, .stopped, "stopped phase derives stopped health")

var startingSnapshot = readySnapshot
startingSnapshot.phase = .preparing
startingSnapshot.engineRunning = false
expectEqual(BridgeLivenessStatus.evaluate(
    snapshot: startingSnapshot,
    liveness: liveRecord,
    engineHeartbeat: nil,
    now: livenessNow,
    currentProcessIdentifier: 77
).health, .starting, "active preparation derives starting health")

expectEqual(BridgeLivenessStatus.evaluate(
    snapshot: BridgeSnapshot(),
    liveness: nil,
    engineHeartbeat: nil,
    now: livenessNow,
    currentProcessIdentifier: 77
).health, .idle, "idle snapshot derives idle health")

var transitionLog = BridgeLivenessTransitionLog()
for index in 1...30 {
    transitionLog.append(BridgeLivenessTransition(
        sequence: UInt64(index),
        at: BridgeClock.timestamp(livenessNow),
        processIdentifier: 77,
        source: "scene",
        name: "transition-\(index)",
        applicationState: "active",
        sceneState: "foregroundActive"
    ))
}
expectEqual(transitionLog.transitions.count, BridgeLivenessPolicy.maximumTransitions,
            "transition log is bounded")
expect(transitionLog.transitions.first?.sequence == 7,
       "transition log drops oldest entries")
expect(transitionLog.transitions.last?.sequence == 30,
       "transition log keeps the newest entry")
expectEqual(BridgeLivenessTransitionLog.parse(
    transitionLog.dictionaries,
    currentProcessIdentifier: 77
).count, BridgeLivenessPolicy.maximumTransitions, "transition parse keeps bounded current history")
expect(BridgeLivenessTransitionLog.parse(
    transitionLog.dictionaries,
    currentProcessIdentifier: 78
).isEmpty, "transition parse rejects another PID history")

var boundedRecord = liveRecord
boundedRecord["transitions"] = transitionLog.dictionaries
let boundedStatus = BridgeLivenessStatus.evaluate(
    snapshot: readySnapshot,
    liveness: boundedRecord,
    engineHeartbeat: engineBeatRecord,
    now: livenessNow,
    currentProcessIdentifier: 77
)
expectEqual(boundedStatus.transitions.count, BridgeLivenessPolicy.maximumTransitions,
            "liveness status carries bounded transitions")
let livenessDictionary = boundedStatus.dictionary()
expect(livenessDictionary["health"] as? String == "healthy",
       "liveness dictionary exposes health")
expect(livenessDictionary["mainThreadBeat"] is [String: Any],
       "liveness dictionary exposes the main beat")
expect(livenessDictionary["transitions"] is [[String: Any]],
       "liveness dictionary exposes transitions")

// Protected-data observations are a signal, not a lock-state claim.
let protectedDataRecord: [String: Any] = [
    "processIdentifier": 77,
    "initialAvailable": false,
    "currentAvailable": true,
    "observedAt": BridgeClock.timestamp(livenessNow),
    "lastEvent": "did-become-available",
    "lastEventAt": BridgeClock.timestamp(livenessNow.addingTimeInterval(-2)),
    "didBecomeAvailableCount": 1,
    "willBecomeUnavailableCount": 2,
]
let protectedDataStatus = BridgeProtectedDataStatus.parse(
    protectedDataRecord,
    currentProcessIdentifier: 77
)
expect(protectedDataStatus.observed, "protected-data observation is present")
expect(protectedDataStatus.isCurrentProcess, "protected-data observation PID is current")
expect(protectedDataStatus.initialAvailable == false, "protected-data initial boolean")
expect(protectedDataStatus.currentAvailable == true, "protected-data current boolean")
expectEqual(protectedDataStatus.didBecomeAvailableCount, 1,
            "protected-data available notification count")
expectEqual(protectedDataStatus.willBecomeUnavailableCount, 2,
            "protected-data unavailable notification count")
expect(protectedDataStatus.lastEvent == "did-become-available",
       "protected-data last event retained")
expect(protectedDataStatus.lastEventAt ==
       BridgeClock.timestamp(livenessNow.addingTimeInterval(-2)),
       "protected-data last event time retained")
let protectedDataDictionary = protectedDataStatus.dictionary()
expect(protectedDataDictionary["currentAvailable"] as? Bool == true,
       "protected-data dictionary exposes current boolean")
expect(protectedDataDictionary["note"] as? String == BridgeProtectedDataPolicy.note,
       "protected-data dictionary states it is not a lock-state claim")
let missingProtectedData = BridgeProtectedDataStatus.parse(
    nil,
    currentProcessIdentifier: 77
)
expect(!missingProtectedData.observed, "missing protected-data record is not observed")
expect(!missingProtectedData.isCurrentProcess, "missing protected-data record is not current")
let foreignProtectedData = BridgeProtectedDataStatus.parse(
    protectedDataRecord,
    currentProcessIdentifier: 78
)
expect(!foreignProtectedData.observed, "foreign protected-data record is not observed")
expect(!foreignProtectedData.isCurrentProcess, "foreign protected-data record is not current")
expect(foreignProtectedData.currentAvailable == nil,
       "foreign protected-data current boolean is not exposed")
var protectedLivenessRecord = liveRecord
protectedLivenessRecord["protectedData"] = protectedDataRecord
let protectedLiveness = BridgeLivenessStatus.evaluate(
    snapshot: readySnapshot,
    liveness: protectedLivenessRecord,
    engineHeartbeat: engineBeatRecord,
    now: livenessNow,
    currentProcessIdentifier: 77
)
expect(protectedLiveness.protectedData.isCurrentProcess,
       "liveness status carries current protected-data observations")
expect(protectedLiveness.protectedData.currentAvailable == true,
       "liveness status carries protected-data current boolean")
expect(protectedLiveness.dictionary()["protectedData"] is [String: Any],
       "liveness dictionary exposes protected-data observations")

// MARK: - Command generation fence

let generationCommand = BridgeCommandEnvelope(
    id: "gen-1",
    action: "status",
    pid: 99,
    token: "secret",
    expectedGeneration: 12
)
expectEqual(
    BridgeCommandPolicy.validate(
        generationCommand,
        lane: .host,
        expectedPid: 99,
        expectedToken: "secret",
        expectedGeneration: 12
    ),
    .accepted,
    "matching generation command accepted"
)
expectEqual(
    BridgeCommandPolicy.validate(
        generationCommand,
        lane: .host,
        expectedPid: 99,
        expectedToken: "secret",
        expectedGeneration: 13
    ),
    .generationMismatch,
    "stale generation command rejected"
)
expectEqual(
    BridgeCommandPolicy.validate(
        generationCommand,
        lane: .host,
        expectedPid: 99,
        expectedToken: "secret"
    ),
    .generationMismatch,
    "generation-fenced command without a caller generation rejected"
)
let legacyGenerationCommand = BridgeCommandEnvelope(
    id: "gen-legacy",
    action: "status",
    pid: 99,
    token: "secret"
)
expectEqual(
    BridgeCommandPolicy.validate(
        legacyGenerationCommand,
        lane: .host,
        expectedPid: 99,
        expectedToken: "secret",
        expectedGeneration: 12
    ),
    .accepted,
    "legacy command without a generation remains accepted"
)
let wrongTokenGenerationCommand = BridgeCommandEnvelope(
    id: "gen-bad-token",
    action: "status",
    pid: 99,
    token: "wrong",
    expectedGeneration: 12
)
expectEqual(
    BridgeCommandPolicy.validate(
        wrongTokenGenerationCommand,
        lane: .host,
        expectedPid: 99,
        expectedToken: "secret",
        expectedGeneration: 13
    ),
    .invalidToken,
    "token authentication precedes generation freshness"
)
let wrongPidGenerationCommand = BridgeCommandEnvelope(
    id: "gen-bad-pid",
    action: "status",
    pid: 98,
    token: "secret",
    expectedGeneration: 12
)
expectEqual(
    BridgeCommandPolicy.validate(
        wrongPidGenerationCommand,
        lane: .host,
        expectedPid: 99,
        expectedToken: "secret",
        expectedGeneration: 12
    ),
    .pidMismatch,
    "PID check precedes generation freshness"
)
let encodedGeneration = try! JSONEncoder().encode(generationCommand)
let decodedGeneration = try! JSONDecoder().decode(
    BridgeCommandEnvelope.self,
    from: encodedGeneration
)
expect(decodedGeneration.expectedGeneration == 12,
       "generation field survives command JSON round-trip")
let legacyGenerationData = Data(
    #"{"id":"legacy","action":"status","pid":99,"token":"secret"}"#.utf8
)
let decodedLegacyGeneration = try! JSONDecoder().decode(
    BridgeCommandEnvelope.self,
    from: legacyGenerationData
)
expect(decodedLegacyGeneration.expectedGeneration == nil,
       "legacy command JSON decodes without a generation")

// MARK: - Settings canary root and geometry policy

let settingsWindow = BridgeScreenRect(x: 0, y: 0, width: 390, height: 844)
let settingsInterior = BridgeSettingsTapPolicy.safeInterior(window: settingsWindow)
expectEqual(settingsInterior.minX, 16, "settings interior left margin")
expectEqual(settingsInterior.minY, 44, "settings interior top margin excludes the navigation bar")
expect(settingsInterior.maxY < settingsWindow.maxY - 60,
       "settings interior reserves the bottom overlay band")
let generalFrame = BridgeScreenRect(x: 16, y: 500, width: 358, height: 44)
let generalCandidate = BridgeSettingsCandidate(
    label: "General",
    frame: generalFrame,
    strategy: "cell"
)
let rootFacts = BridgeSettingsRootFacts(
    isForeground: true,
    hasRootNavigationTitle: true,
    hasSettingsSearchField: true,
    hasBackNavigationButton: false,
    destinationVisible: false
)
expect(BridgeSettingsTapPolicy.rootEvidence(rootFacts) == "navigation-title",
       "root navigation title is strong evidence")
expectEqual(
    BridgeSettingsTapPolicy.evaluate(
        facts: rootFacts,
        candidates: [generalCandidate],
        window: settingsWindow,
        overlays: [],
        scrollAttemptsUsed: 0
    ),
    .tap(candidateIndex: 0),
    "unique General inside the interior is tappable"
)
expectEqual(
    BridgeSettingsTapPolicy.evaluate(
        facts: rootFacts,
        candidates: [generalCandidate],
        window: settingsWindow,
        overlays: [BridgeScreenRect(x: 0, y: 480, width: 390, height: 80)],
        scrollAttemptsUsed: 0
    ),
    .scroll(direction: .up, attempt: 1),
    "a covered General row scrolls upward instead of tapping through an overlay"
)
let belowInterior = BridgeSettingsCandidate(
    label: "通用",
    frame: BridgeScreenRect(x: 16, y: 760, width: 358, height: 44),
    strategy: "staticText"
)
expectEqual(
    BridgeSettingsTapPolicy.evaluate(
        facts: rootFacts,
        candidates: [belowInterior],
        window: settingsWindow,
        overlays: [],
        scrollAttemptsUsed: 0
    ),
    .scroll(direction: .up, attempt: 1),
    "a row below the interior scrolls upward"
)
let aboveInterior = BridgeSettingsCandidate(
    label: "General",
    frame: BridgeScreenRect(x: 16, y: 0, width: 358, height: 44),
    strategy: "cell"
)
expectEqual(
    BridgeSettingsTapPolicy.evaluate(
        facts: rootFacts,
        candidates: [aboveInterior],
        window: settingsWindow,
        overlays: [],
        scrollAttemptsUsed: 0
    ),
    .scroll(direction: .down, attempt: 1),
    "a row above the interior scrolls downward"
)
expectEqual(
    BridgeSettingsTapPolicy.evaluate(
        facts: rootFacts,
        candidates: [belowInterior],
        window: settingsWindow,
        overlays: [],
        scrollAttemptsUsed: BridgeSettingsCanaryPolicy.maximumScrollAttempts
    ),
    .refuse(.targetNotReachable),
    "bounded scroll attempts end in refusal"
)
expectEqual(
    BridgeSettingsTapPolicy.evaluate(
        facts: rootFacts,
        candidates: [generalCandidate, belowInterior],
        window: settingsWindow,
        overlays: [],
        scrollAttemptsUsed: 0
    ),
    .refuse(.ambiguousTarget),
    "multiple General candidates are refused"
)
expectEqual(
    BridgeSettingsTapPolicy.evaluate(
        facts: rootFacts,
        candidates: [],
        window: settingsWindow,
        overlays: [],
        scrollAttemptsUsed: 0
    ),
    .refuse(.missingTarget),
    "missing General candidate is refused"
)
var notForegroundFacts = rootFacts
notForegroundFacts.isForeground = false
expectEqual(
    BridgeSettingsTapPolicy.evaluate(
        facts: notForegroundFacts,
        candidates: [generalCandidate],
        window: settingsWindow,
        overlays: [],
        scrollAttemptsUsed: 0
    ),
    .refuse(.notForeground),
    "background Settings is refused"
)
var destinationFacts = rootFacts
destinationFacts.destinationVisible = true
expectEqual(
    BridgeSettingsTapPolicy.evaluate(
        facts: destinationFacts,
        candidates: [generalCandidate],
        window: settingsWindow,
        overlays: [],
        scrollAttemptsUsed: 0
    ),
    .alreadyAtDestination,
    "an already-open destination is not tapped"
)
var pushedFacts = rootFacts
pushedFacts.hasRootNavigationTitle = false
pushedFacts.hasSettingsSearchField = false
pushedFacts.hasBackNavigationButton = true
expect(BridgeSettingsTapPolicy.rootEvidence(pushedFacts) == nil,
       "a pushed page has no confirmed root evidence")
expectEqual(
    BridgeSettingsTapPolicy.evaluate(
        facts: pushedFacts,
        candidates: [generalCandidate],
        window: settingsWindow,
        overlays: [],
        scrollAttemptsUsed: 0
    ),
    .refuse(.rootUnconfirmed),
    "a pushed page refuses to choose General"
)
var searchRootFacts = pushedFacts
searchRootFacts.hasBackNavigationButton = false
searchRootFacts.hasSettingsSearchField = true
expect(BridgeSettingsTapPolicy.rootEvidence(searchRootFacts) == "search-field-no-back",
       "search field without a back button confirms root")
var bareRootFacts = searchRootFacts
bareRootFacts.hasSettingsSearchField = false
expect(BridgeSettingsTapPolicy.rootEvidence(bareRootFacts) == "no-back-button",
       "no back button is the bounded root fallback")
expectEqual(
    BridgeSettingsTapPolicy.evaluate(
        facts: rootFacts,
        candidates: [generalCandidate],
        window: BridgeScreenRect(x: 0, y: 0, width: 100, height: 100),
        overlays: [],
        scrollAttemptsUsed: 0
    ),
    .refuse(.invalidWindow),
    "tiny or invalid window is refused"
)

// MARK: - Canary state machine, report bounds and readiness

let canaryPid: Int32 = 4321
let canaryGeneration: UInt64 = 11
let canaryDate = Date(timeIntervalSince1970: 1_700_000_000)
let canaryID = BridgeCanaryRun.makeRunID(
    ownerProcessIdentifier: canaryPid,
    ownerGeneration: canaryGeneration,
    at: canaryDate
)
let secondCanaryID = BridgeCanaryRun.makeRunID(
    ownerProcessIdentifier: canaryPid,
    ownerGeneration: canaryGeneration,
    at: canaryDate
)
expect(canaryID != secondCanaryID, "canary run IDs are unique per run")
expect(canaryID.hasPrefix("c-4321-11-"), "canary run ID carries owner and generation")

func canaryResult(
    _ run: BridgeCanaryRun,
    index: Int,
    status: String = "ok",
    details: [String: String] = [:],
    error: String? = nil,
    processIdentifier: Int32? = nil,
    generation: UInt64? = nil
) -> BridgeCommandResult {
    let step = run.report.steps[index]
    return BridgeCommandResult(
        id: step.commandID,
        action: step.action,
        status: status,
        authoredBy: "self-check",
        processIdentifier: processIdentifier ?? run.report.ownerProcessIdentifier,
        generation: generation ?? run.report.ownerGeneration,
        details: details,
        error: error
    )
}

func canaryStepDetails(_ action: String) -> [String: String] {
    switch action {
    case "screenshot":
        return [
            "screenshotFile": "screenshot-1.png",
            "screenshotBytes": "1234",
            "pixelWidth": "1206",
            "pixelHeight": "2622",
        ]
    case "open_settings":
        return ["foreground": "true"]
    case "tap_general":
        return [
            "destinationVerified": "true",
            "destinationLabel": "About",
            "tapPerformed": "true",
        ]
    case "home":
        return ["destinationVerified": "true"]
    default:
        return [:]
    }
}

func passCanaryStep(_ run: inout BridgeCanaryRun) -> Bool {
    guard let index = run.report.currentStepIndex ?? run.nextPendingIndex else { return false }
    let action = run.report.steps[index].action
    guard run.beginIssue(index: index), run.markAwaitingResult(index: index) else { return false }
    let result = canaryResult(run, index: index, details: canaryStepDetails(action))
    return run.recordResult(index: index, result: result, resultBytes: 100) == .passed
}

var canary = BridgeCanaryRun(
    runID: canaryID,
    ownerProcessIdentifier: canaryPid,
    ownerGeneration: canaryGeneration
)
expectEqual(canary.report.state, .pending, "canary starts pending")
expectEqual(canary.totalCount, BridgeCanarySequence.actions.count,
            "canary has the fixed step count")
expectEqual(Set(canary.report.steps.map { $0.commandID }).count,
            BridgeCanarySequence.actions.count, "canary command IDs are unique")
expect(canary.report.steps.first?.action == "status", "canary starts with status")
expect(canary.report.steps.last?.action == "status", "canary ends with status")
expect(canary.report.isWellFormed, "new canary report is well formed")
expect(canary.markRunning(), "canary enters running")
expect(canary.report.currentStepIndex == 0, "canary current step is first")
expect(canary.beginIssue(index: 0), "canary first step begins issue")
expect(canary.markAwaitingResult(index: 0), "canary first step awaits result")
expectEqual(canary.report.steps[0].state, .awaitingResult,
            "issued canary step is awaiting-result")
let firstCanaryDisposition = canary.recordResult(
    index: 0,
    result: canaryResult(canary, index: 0),
    resultBytes: 128
)
expectEqual(firstCanaryDisposition, .passed, "status canary step passes")
expectEqual(canary.report.steps[0].state, .passed, "passed step state retained")
expect(canary.report.steps[0].resultBytes == 128, "result byte count retained")
expect(canary.report.currentStepIndex == 1, "canary advances to the screenshot step")

var brokenCanary = BridgeCanaryRun(
    runID: canaryID + "-broken",
    ownerProcessIdentifier: canaryPid,
    ownerGeneration: canaryGeneration
)
expect(brokenCanary.markRunning(), "broken canary enters running")
expect(brokenCanary.beginIssue(index: 0), "broken canary issues status")
expect(brokenCanary.markAwaitingResult(index: 0), "broken canary awaits status")
_ = brokenCanary.recordResult(
    index: 0,
    result: canaryResult(brokenCanary, index: 0),
    resultBytes: 10
)
expect(brokenCanary.beginIssue(index: 1), "broken canary issues screenshot")
expect(brokenCanary.markAwaitingResult(index: 1), "broken canary awaits screenshot")
let brokenScreenshot = canaryResult(
    brokenCanary,
    index: 1,
    details: [
        "screenshotFile": "shot.png",
        "screenshotBytes": "0",
        "pixelWidth": "0",
        "pixelHeight": "0",
    ]
)
expectEqual(
    brokenCanary.recordResult(index: 1, result: brokenScreenshot, resultBytes: 30),
    .failed,
    "screenshot without bytes/dimensions fails"
)
expectEqual(brokenCanary.report.state, .partial,
            "failure after a pass is partial")
expectEqual(brokenCanary.report.steps[1].state, .failed, "failed step state retained")
expectEqual(brokenCanary.report.steps[2].state, .skipped,
            "remaining steps are skipped after failure")

var tapCanary = BridgeCanaryRun(
    runID: canaryID + "-tap",
    ownerProcessIdentifier: canaryPid,
    ownerGeneration: canaryGeneration
)
expect(tapCanary.markRunning(), "tap canary enters running")
expect(passCanaryStep(&tapCanary), "tap canary status passes")
expect(passCanaryStep(&tapCanary), "tap canary screenshot passes")
expect(passCanaryStep(&tapCanary), "tap canary open_settings passes")
guard let tapIndex = tapCanary.nextPendingIndex else {
    expect(false, "tap canary has a pending tap step")
    exit(1)
}
expectEqual(tapIndex, 3, "tap canary reaches the General step")
expect(tapCanary.beginIssue(index: tapIndex), "tap canary issues General")
expect(tapCanary.markAwaitingResult(index: tapIndex), "tap canary awaits General")
let unverifiedTap = canaryResult(
    tapCanary,
    index: tapIndex,
    details: [
        "destinationVerified": "false",
        "destinationLabel": "",
        "tapPerformed": "true",
    ]
)
expectEqual(
    tapCanary.recordResult(index: tapIndex, result: unverifiedTap, resultBytes: 80),
    .failed,
    "unverified General tap fails"
)
expectEqual(tapCanary.report.state, .partial,
            "unverified General tap is partial after earlier passes")

var unobservedCanary = BridgeCanaryRun(
    runID: canaryID + "-unobserved",
    ownerProcessIdentifier: canaryPid,
    ownerGeneration: canaryGeneration
)
expect(unobservedCanary.markRunning(), "unobserved canary enters running")
expect(unobservedCanary.beginIssue(index: 0), "unobserved canary issues")
expect(unobservedCanary.markAwaitingResult(index: 0), "unobserved canary awaits")
expect(unobservedCanary.recordUnobserved(
    index: 0,
    code: "result-timeout",
    message: "no result"
), "unobserved step is recorded")
expectEqual(unobservedCanary.report.steps[0].state, .unobserved,
            "timed-out step is unobserved, not passed or failed")
expectEqual(unobservedCanary.report.state, .failed,
            "timeout on the first step is failed")
expect(!unobservedCanary.beginIssue(index: 1),
       "a terminal canary cannot issue another command")

var cancelledCanary = BridgeCanaryRun(
    runID: canaryID + "-cancelled",
    ownerProcessIdentifier: canaryPid,
    ownerGeneration: canaryGeneration
)
expect(cancelledCanary.markRunning(), "cancelled canary enters running")
expect(passCanaryStep(&cancelledCanary), "cancelled canary status passes")
expect(cancelledCanary.beginIssue(index: 1), "cancelled canary issues screenshot")
expect(cancelledCanary.markAwaitingResult(index: 1), "cancelled canary awaits screenshot")
expect(cancelledCanary.cancel(code: "cancelled-by-stop", message: "stop"),
       "live canary cancels")
expectEqual(cancelledCanary.report.state, .cancelled, "cancelled canary state")
expectEqual(cancelledCanary.report.steps[1].state, .unobserved,
            "cancelled awaiting step is unobserved")
expect(cancelledCanary.report.steps[1].note?.contains("not replayed") == true,
       "cancelled awaiting step says it was not replayed")
expectEqual(cancelledCanary.report.steps[2].state, .skipped,
            "future canary steps are skipped after cancellation")
expectEqual(cancelledCanary.report.passedCount, 1,
            "cancelled canary preserves the passed step")

var ownershipCanary = BridgeCanaryRun(
    runID: canaryID + "-ownership",
    ownerProcessIdentifier: canaryPid,
    ownerGeneration: canaryGeneration
)
expect(ownershipCanary.markRunning(), "ownership canary enters running")
expect(ownershipCanary.beginIssue(index: 0), "ownership canary issues")
expect(ownershipCanary.markAwaitingResult(index: 0), "ownership canary awaits")
let foreignResult = canaryResult(
    ownershipCanary,
    index: 0,
    processIdentifier: canaryPid + 1
)
expectEqual(
    ownershipCanary.recordResult(index: 0, result: foreignResult, resultBytes: 20),
    .ownershipMismatch,
    "foreign-PID result is rejected"
)
expectEqual(ownershipCanary.report.steps[0].state, .unobserved,
            "foreign-PID result does not pass the step")
let staleGenerationResult = canaryResult(
    ownershipCanary,
    index: 0,
    generation: canaryGeneration + 1
)
expectEqual(
    ownershipCanary.recordResult(index: 0, result: staleGenerationResult, resultBytes: 20),
    .ignored,
    "a terminal canary ignores later results"
)

var wrongActionCanary = BridgeCanaryRun(
    runID: canaryID + "-wrong-action",
    ownerProcessIdentifier: canaryPid,
    ownerGeneration: canaryGeneration
)
expect(wrongActionCanary.markRunning(), "wrong-action canary enters running")
expect(wrongActionCanary.beginIssue(index: 0), "wrong-action canary issues status")
expect(wrongActionCanary.markAwaitingResult(index: 0), "wrong-action canary awaits status")
let wrongActionResult = BridgeCommandResult(
    id: wrongActionCanary.report.steps[0].commandID,
    action: "screenshot",
    status: "ok",
    authoredBy: "self-check",
    processIdentifier: canaryPid,
    generation: canaryGeneration,
    details: canaryStepDetails("screenshot"),
    error: nil
)
expectEqual(
    wrongActionCanary.recordResult(index: 0, result: wrongActionResult, resultBytes: 120),
    .ownershipMismatch,
    "correct command ID/PID/generation with a wrong action is rejected"
)
expectEqual(wrongActionCanary.report.steps[0].state, .unobserved,
            "wrong-action result does not pass the status step")
expect(wrongActionCanary.report.currentStepIndex == nil,
       "wrong-action result leaves no next step")
expect(wrongActionCanary.nextPendingIndex == nil,
       "wrong-action result does not leave a pending command")
expectEqual(wrongActionCanary.report.steps[1].state, .skipped,
            "wrong-action result skips later steps")
expectEqual(wrongActionCanary.report.passedCount, 0,
            "wrong-action result claims no passed step")
expectEqual(wrongActionCanary.report.state, .failed,
            "wrong-action result is a failure, not a pass")
expectEqual(wrongActionCanary.report.failureCode, "ownership-mismatch",
            "wrong-action result failure code")

var completedCanary = BridgeCanaryRun(
    runID: canaryID + "-complete",
    ownerProcessIdentifier: canaryPid,
    ownerGeneration: canaryGeneration
)
expect(completedCanary.markRunning(), "completed canary enters running")
for _ in BridgeCanarySequence.actions {
    expect(passCanaryStep(&completedCanary), "completed canary step passes")
}
expect(completedCanary.report.currentStepIndex == nil,
       "completed canary has no current step")
expectEqual(completedCanary.report.passedCount, BridgeCanarySequence.actions.count,
            "completed canary passes every step")
expect(completedCanary.complete(), "all-passed canary completes")
expectEqual(completedCanary.report.state, .completed, "completed canary state")
expect(!completedCanary.complete(), "completed canary cannot complete twice")

var failedRunCanary = BridgeCanaryRun(
    runID: canaryID + "-failed-run",
    ownerProcessIdentifier: canaryPid,
    ownerGeneration: canaryGeneration
)
expect(failedRunCanary.failRun(code: "entry-timeout", message: "no entry"),
       "pre-step failure is recorded")
expectEqual(failedRunCanary.report.state, .failed, "pre-step failure is failed")
expectEqual(failedRunCanary.report.steps[0].state, .skipped,
            "pre-step failure skips all steps")

let canaryReportURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("floe-canary-report-\(UUID().uuidString).json")
expect(BridgeCanaryReportStore.write(completedCanary.report, to: canaryReportURL),
       "completed canary report writes")
if let loadedReport = BridgeCanaryReportStore.read(from: canaryReportURL) {
    expectEqual(loadedReport.state, .completed, "canary report round-trips state")
    expectEqual(loadedReport.ownerProcessIdentifier, canaryPid,
                "canary report round-trips owner PID")
    expectEqual(loadedReport.ownerGeneration, canaryGeneration,
                "canary report round-trips owner generation")
    expectEqual(loadedReport.steps.count, BridgeCanarySequence.actions.count,
                "canary report round-trips steps")
    expect(loadedReport.isWellFormed, "loaded canary report is well formed")
} else {
    expect(false, "completed canary report reads")
}
var malformedReport = completedCanary.report
malformedReport.steps.append(BridgeCanaryStep(
    index: 99,
    action: "status",
    commandID: "extra"
))
expect(!malformedReport.isWellFormed, "extra canary step is not well formed")
expect(!BridgeCanaryReportStore.write(malformedReport, to: canaryReportURL),
       "malformed canary report is not written")
try? FileManager.default.removeItem(at: canaryReportURL)

// Canary readiness: the real entry marker must match this PID and dispatch.
var readinessSnapshot = BridgeSnapshot()
readinessSnapshot.hostPid = canaryPid
readinessSnapshot.phase = .ready
readinessSnapshot.generation = 21
readinessSnapshot.serviceRunning = true
readinessSnapshot.oneShotDispatched = true
readinessSnapshot.dispatchedGeneration = 20
readinessSnapshot.engineEntryObserved = true
readinessSnapshot.engineRunning = true
readinessSnapshot.enginePid = canaryPid
let readyMarker: [String: Any] = [
    "ready": true,
    "processIdentifier": canaryPid,
    "testBundleIdentifier": BridgeBuild.hostBundleIdentifier,
    "dispatchedGeneration": UInt64(20),
]
expectEqual(
    BridgeCanaryReadiness.evaluate(
        snapshot: readinessSnapshot,
        readyMarker: readyMarker,
        expectedGeneration: 21,
        expectedProcessIdentifier: canaryPid
    ),
    .ready,
    "canary is ready only with a matching live entry"
)
expectEqual(
    BridgeCanaryReadiness.evaluate(
        snapshot: readinessSnapshot,
        readyMarker: readyMarker,
        expectedGeneration: 22,
        expectedProcessIdentifier: canaryPid
    ),
    .fenced,
    "canary generation change fences readiness"
)
var wrongPidMarker = readyMarker
wrongPidMarker["processIdentifier"] = canaryPid + 1
expectEqual(
    BridgeCanaryReadiness.evaluate(
        snapshot: readinessSnapshot,
        readyMarker: wrongPidMarker,
        expectedGeneration: 21,
        expectedProcessIdentifier: canaryPid
    ),
    .waiting(reason: "ready-marker-pid"),
    "canary ignores another PID's ready marker"
)
var wrongDispatchMarker = readyMarker
wrongDispatchMarker["dispatchedGeneration"] = UInt64(19)
expectEqual(
    BridgeCanaryReadiness.evaluate(
        snapshot: readinessSnapshot,
        readyMarker: wrongDispatchMarker,
        expectedGeneration: 21,
        expectedProcessIdentifier: canaryPid
    ),
    .waiting(reason: "ready-marker-dispatch"),
    "canary ignores a different dispatch generation"
)
expectEqual(
    BridgeCanaryReadiness.evaluate(
        snapshot: readinessSnapshot,
        readyMarker: nil,
        expectedGeneration: 21,
        expectedProcessIdentifier: canaryPid
    ),
    .waiting(reason: "ready-marker-missing"),
    "canary waits without a ready marker"
)
var startingReadiness = readinessSnapshot
startingReadiness.phase = .preparing
startingReadiness.engineRunning = false
expectEqual(
    BridgeCanaryReadiness.evaluate(
        snapshot: startingReadiness,
        readyMarker: readyMarker,
        expectedGeneration: 21,
        expectedProcessIdentifier: canaryPid
    ),
    .waiting(reason: "phase-preparing"),
    "canary waits during preparation"
)
var failedReadiness = readinessSnapshot
failedReadiness.terminalFault = true
failedReadiness.terminalFaultCode = "engine-halted"
failedReadiness.terminalFaultMessage = "halted"
expectEqual(
    BridgeCanaryReadiness.evaluate(
        snapshot: failedReadiness,
        readyMarker: readyMarker,
        expectedGeneration: 21,
        expectedProcessIdentifier: canaryPid
    ),
    .failed(code: "engine-halted", message: "halted"),
    "canary reports a terminal engine fault"
)
var notRunningReadiness = readinessSnapshot
notRunningReadiness.engineRunning = false
expectEqual(
    BridgeCanaryReadiness.evaluate(
        snapshot: notRunningReadiness,
        readyMarker: readyMarker,
        expectedGeneration: 21,
        expectedProcessIdentifier: canaryPid
    ),
    .waiting(reason: "engine-entry-not-live"),
    "canary does not borrow a stopped engine"
)

// MARK: - Final pre-SDK mutation admission

var mutationCalls = 0
let staleAdmission = BridgeControlMutationAdmission.admit(
    expectedGeneration: 7,
    currentGeneration: 8,
    engineAcceptsCommands: true,
    requiresForeground: true,
    expectedForeground: true
) {
    mutationCalls += 1
}
expectEqual(staleAdmission, .staleGeneration,
            "stale generation refuses the mutation admission")
expectEqual(mutationCalls, 0,
            "stale generation never invokes the mutation closure")

let stoppedAdmission = BridgeControlMutationAdmission.admit(
    expectedGeneration: 7,
    currentGeneration: 7,
    engineAcceptsCommands: false,
    requiresForeground: true,
    expectedForeground: true
) {
    mutationCalls += 1
}
expectEqual(stoppedAdmission, .engineNotReady,
            "stopped engine refuses the mutation admission")
expectEqual(mutationCalls, 0,
            "stopped engine never invokes the mutation closure")

let backgroundAdmission = BridgeControlMutationAdmission.admit(
    expectedGeneration: 7,
    currentGeneration: 7,
    engineAcceptsCommands: true,
    requiresForeground: true,
    expectedForeground: false
) {
    mutationCalls += 1
}
expectEqual(backgroundAdmission, .targetNotForeground,
            "post-snapshot foreground change refuses the mutation admission")
expectEqual(mutationCalls, 0,
            "post-snapshot foreground change never invokes the mutation closure")

let admitted = BridgeControlMutationAdmission.admit(
    expectedGeneration: 7,
    currentGeneration: 7,
    engineAcceptsCommands: true,
    requiresForeground: true,
    expectedForeground: true
) {
    mutationCalls += 1
}
expectEqual(admitted, .allowed, "current lifecycle admits the mutation")
expectEqual(mutationCalls, 1, "allowed admission invokes the mutation exactly once")

let activationAdmission = BridgeControlMutationAdmission.admit(
    expectedGeneration: 7,
    currentGeneration: 7,
    engineAcceptsCommands: true,
    requiresForeground: false,
    expectedForeground: false
) {
    mutationCalls += 1
}
expectEqual(activationAdmission, .allowed,
            "activation admission permits an intentional foreground transition")
expectEqual(mutationCalls, 2,
            "activation admission invokes its mutation exactly once")

// MARK: - Generic automation typed parameters

let legacyEnvelopeJSON = Data(#"{"id":"legacy-typed","action":"status","pid":1999,"token":"x"}"#.utf8)
if let legacyTyped = try? JSONDecoder().decode(BridgeCommandEnvelope.self,
                                              from: legacyEnvelopeJSON) {
    expect(legacyTyped.parameters == nil,
           "legacy command envelope has no typed parameters")
} else {
    expect(false, "legacy command envelope decodes")
}

let typedTap = BridgeControlParameters(
    bundleIdentifier: "com.apple.Preferences",
    identifier: "floe.controlTest.textField"
)
if let data = try? JSONEncoder().encode(typedTap),
   let decoded = try? JSONDecoder().decode(BridgeControlParameters.self, from: data) {
    expectEqual(decoded, typedTap, "typed parameters round trip")
} else {
    expect(false, "typed parameters round trip")
}
if let unknown = try? JSONDecoder().decode(
    BridgeControlParameters.self,
    from: Data(#"{"bundleIdentifier":"com.apple.Preferences","surprise":1}"#.utf8)
) {
    expectEqual(unknown.unknownKeys, ["surprise"],
                "typed parameters record an unknown field")
} else {
    expect(false, "typed parameters decode an unknown field for policy refusal")
}

func parameterCode(_ result: Result<BridgeControlParameters, BridgeControlParameterError>) -> String {
    if case .failure(let error) = result { return error.code }
    return "ok"
}

expectEqual(parameterCode(BridgeControlArguments.validate(
    action: BridgeControlAction.activateApp, parameters: nil
)), "parameters_required", "activate requires typed parameters")
expectEqual(parameterCode(BridgeControlArguments.validate(
    action: BridgeControlAction.activateApp,
    parameters: BridgeControlParameters(bundleIdentifier: "com.apple.Preferences")
)), "ok", "activate accepts a valid bundle identifier")
expectEqual(parameterCode(BridgeControlArguments.validate(
    action: BridgeControlAction.activateApp,
    parameters: BridgeControlParameters(bundleIdentifier: "../not-an-app")
)), "invalid_bundle_identifier", "activate rejects a non-bundle identifier")

let validTapParameters = BridgeControlParameters(
    bundleIdentifier: "com.apple.Preferences",
    normalizedX: 0.5, normalizedY: 0.25
)
let validTapDecision = BridgeControlArguments.validate(
    action: BridgeControlAction.tap, parameters: validTapParameters
)
if case .success(let normalizedTap) = validTapDecision {
    expectEqual(normalizedTap.normalizedX, 0.5, "tap keeps normalized x")
    expectEqual(normalizedTap.normalizedY, 0.25, "tap keeps normalized y")
} else {
    expect(false, "tap accepts normalized coordinates")
}
expectEqual(parameterCode(BridgeControlArguments.validate(
    action: BridgeControlAction.tap,
    parameters: BridgeControlParameters(bundleIdentifier: "com.apple.Preferences",
                                        identifier: "id", normalizedX: 0.5, normalizedY: 0.5)
)), "ambiguous_arguments", "tap rejects identifier plus coordinates")
expectEqual(parameterCode(BridgeControlArguments.validate(
    action: BridgeControlAction.tap,
    parameters: BridgeControlParameters(bundleIdentifier: "com.apple.Preferences",
                                        normalizedX: 0.5)
)), "ambiguous_arguments", "tap rejects a partial coordinate")
expectEqual(parameterCode(BridgeControlArguments.validate(
    action: BridgeControlAction.tap,
    parameters: BridgeControlParameters(bundleIdentifier: "com.apple.Preferences",
                                        normalizedX: 1.5, normalizedY: 0.5)
)), "invalid_coordinates", "tap rejects an out-of-range coordinate")
expectEqual(parameterCode(BridgeControlArguments.validate(
    action: BridgeControlAction.tap,
    parameters: BridgeControlParameters(bundleIdentifier: "com.apple.Preferences",
                                        normalizedX: .nan, normalizedY: 0.5)
)), "invalid_coordinates", "tap rejects a non-finite coordinate")
expectEqual(parameterCode(BridgeControlArguments.validate(
    action: BridgeControlAction.tap,
    parameters: BridgeControlParameters(bundleIdentifier: "com.apple.springboard",
                                        identifier: "home")
)), "forbidden_target", "tap refuses SpringBoard")

let swipeWithoutDuration = BridgeControlParameters(
    bundleIdentifier: "com.apple.Preferences",
    startNormalizedX: 0.5, startNormalizedY: 0.8,
    endNormalizedX: 0.5, endNormalizedY: 0.2
)
if case .success(let normalizedSwipe) = BridgeControlArguments.validate(
    action: BridgeControlAction.swipe, parameters: swipeWithoutDuration
) {
    expectEqual(normalizedSwipe.durationMilliseconds, 300,
                "swipe fills the bounded default duration")
} else {
    expect(false, "swipe accepts normalized start/end")
}
expectEqual(parameterCode(BridgeControlArguments.validate(
    action: BridgeControlAction.swipe,
    parameters: BridgeControlParameters(
        bundleIdentifier: "com.apple.Preferences",
        startNormalizedX: 0.5, startNormalizedY: 0.5,
        endNormalizedX: 0.5, endNormalizedY: 0.5,
        durationMilliseconds: 300
    )
)), "invalid_coordinates", "swipe rejects a zero-distance gesture")
expectEqual(parameterCode(BridgeControlArguments.validate(
    action: BridgeControlAction.swipe,
    parameters: BridgeControlParameters(
        bundleIdentifier: "com.apple.Preferences",
        startNormalizedX: 0.5, startNormalizedY: 0.8,
        endNormalizedX: 0.5, endNormalizedY: 0.2,
        durationMilliseconds: 20
    )
)), "invalid_duration", "swipe rejects an out-of-range duration")

expectEqual(parameterCode(BridgeControlArguments.validate(
    action: BridgeControlAction.typeText,
    parameters: BridgeControlParameters(
        bundleIdentifier: "com.apple.Preferences",
        text: String(repeating: "x", count: 4_097)
    )
)), "invalid_text", "type_text rejects more than 4096 UTF-8 bytes")
expectEqual(parameterCode(BridgeControlArguments.validate(
    action: BridgeControlAction.typeText,
    parameters: BridgeControlParameters(
        bundleIdentifier: "com.apple.Preferences",
        text: "a\u{0}b"
    )
)), "invalid_text", "type_text rejects NUL")

let inspectDefaults = BridgeControlArguments.validate(
    action: BridgeControlAction.inspectUI,
    parameters: BridgeControlParameters(bundleIdentifier: "com.apple.Preferences")
)
if case .success(let normalizedInspect) = inspectDefaults {
    expectEqual(normalizedInspect.maxDepth, 40, "inspect fills default depth")
    expectEqual(normalizedInspect.maxNodes, 400, "inspect fills default nodes")
    expectEqual(normalizedInspect.maxStringBytes, 512, "inspect fills default string bytes")
    expectEqual(normalizedInspect.maxTotalBytes, 65_536, "inspect fills default total bytes")
} else {
    expect(false, "inspect accepts default bounds")
}
expectEqual(parameterCode(BridgeControlArguments.validate(
    action: BridgeControlAction.inspectUI,
    parameters: BridgeControlParameters(bundleIdentifier: "com.apple.Preferences",
                                        maxNodes: 801)
)), "invalid_bounds", "inspect rejects an out-of-range node cap")
expectEqual(parameterCode(BridgeControlArguments.validate(
    action: BridgeControlAction.activateApp,
    parameters: BridgeControlParameters(bundleIdentifier: "com.apple.Preferences",
                                        maxNodes: 10)
)), "parameters_not_applicable", "activate rejects an inapplicable field")
expectEqual(parameterCode(BridgeControlArguments.validate(
    action: "status",
    parameters: BridgeControlParameters(bundleIdentifier: "com.apple.Preferences")
)), "parameters_not_applicable", "legacy action rejects typed parameters")

let tapDigestA = BridgeControlArguments.contentDigest(
    action: BridgeControlAction.tap, parameters: validTapParameters
)
let tapDigestB = BridgeControlArguments.contentDigest(
    action: BridgeControlAction.tap, parameters: validTapParameters
)
let tapDigestChanged = BridgeControlArguments.contentDigest(
    action: BridgeControlAction.tap,
    parameters: BridgeControlParameters(bundleIdentifier: "com.apple.Preferences",
                                        normalizedX: 0.6, normalizedY: 0.25)
)
expectEqual(tapDigestA, tapDigestB, "same normalized tap arguments have the same digest")
expect(tapDigestA != tapDigestChanged, "changed tap coordinates change the digest")

let textOne = BridgeControlParameters(bundleIdentifier: "com.apple.Preferences",
                                      text: "secret-one")
let textTwo = BridgeControlParameters(bundleIdentifier: "com.apple.Preferences",
                                      text: "secret-two")
let textContentOne = BridgeControlArguments.contentDigest(
    action: BridgeControlAction.typeText, parameters: textOne
)
let textContentTwo = BridgeControlArguments.contentDigest(
    action: BridgeControlAction.typeText, parameters: textTwo
)
let textResultOne = BridgeControlArguments.resultDigest(
    action: BridgeControlAction.typeText, parameters: textOne
)
let textResultTwo = BridgeControlArguments.resultDigest(
    action: BridgeControlAction.typeText, parameters: textTwo
)
expect(textContentOne != textContentTwo,
       "different text is a different private content digest")
expectEqual(textResultOne, textResultTwo,
            "text result digest exposes only a same-length byte count")
expect(!textResultOne.contains("secret"),
       "text result digest never contains the input text")
expect(textOne.containsSensitiveInput, "text parameters are marked sensitive")
if let textSummary = textOne.summaryJSON() {
    expect(!textSummary.contains("secret"), "text summary never contains raw text")
    expect(textSummary.contains("textUTF8Bytes"), "text summary carries only the byte count")
} else {
    expect(false, "text summary is available")
}
if let tapSummary = validTapParameters.summaryJSON() {
    expect(tapSummary.contains("normalizedX"), "tap summary carries the normalized coordinates")
} else {
    expect(false, "tap summary is available")
}

var typedLedger = BridgeLANCommandLedger(maxRecords: 8, commandTTL: 60)
let typedRequest = BridgeLANControlRequest(
    id: "tap-typed-1", lane: .engine, action: BridgeControlAction.tap,
    pid: 1999, generation: 3, session: testSession,
    parameters: validTapParameters
)
if case .accepted = typedLedger.submit(typedRequest) {
    expect(true, "typed ledger accepts the first tap")
} else {
    expect(false, "typed ledger accepts the first tap")
}
let changedTapRequest = BridgeLANControlRequest(
    id: "tap-typed-1", lane: .engine, action: BridgeControlAction.tap,
    pid: 1999, generation: 3, session: testSession,
    parameters: BridgeControlParameters(bundleIdentifier: "com.apple.Preferences",
                                        normalizedX: 0.6, normalizedY: 0.25)
)
if case .replayed = typedLedger.submit(changedTapRequest) {
    expect(true, "same command ID with changed coordinates is not a duplicate")
} else {
    expect(false, "same command ID with changed coordinates is refused")
}
let typedSameRequest = BridgeLANControlRequest(
    id: "tap-typed-1", lane: .engine, action: BridgeControlAction.tap,
    pid: 1999, generation: 3, session: testSession,
    parameters: validTapParameters
)
if case .duplicate = typedLedger.submit(typedSameRequest) {
    expect(true, "same command ID with identical typed arguments is a duplicate")
} else {
    expect(false, "same command ID with identical typed arguments is a duplicate")
}

if let typedRecord = typedLedger.record(id: "tap-typed-1") {
    expectEqual(typedRecord.resultDigest,
                BridgeControlArguments.resultDigest(action: BridgeControlAction.tap,
                                                    parameters: validTapParameters),
                "typed ledger retains the non-secret result digest")
    expectEqual(typedRecord.contentDigest,
                BridgeControlArguments.contentDigest(action: BridgeControlAction.tap,
                                                     parameters: validTapParameters),
                "typed ledger retains the private content digest")
}
var textLedger = BridgeLANCommandLedger(maxRecords: 8, commandTTL: 60)
let firstTextRequest = BridgeLANControlRequest(
    id: "text-typed-1", lane: .engine, action: BridgeControlAction.typeText,
    pid: 1999, generation: 3, session: testSession,
    parameters: BridgeControlParameters(bundleIdentifier: "com.apple.Preferences",
                                        text: "alpha")
)
if case .accepted = textLedger.submit(firstTextRequest) {
    expect(true, "text ledger accepts the first text command")
} else {
    expect(false, "text ledger accepts the first text command")
}
let secondTextRequest = BridgeLANControlRequest(
    id: "text-typed-1", lane: .engine, action: BridgeControlAction.typeText,
    pid: 1999, generation: 3, session: testSession,
    parameters: BridgeControlParameters(bundleIdentifier: "com.apple.Preferences",
                                        text: "bravo")
)
if case .replayed = textLedger.submit(secondTextRequest) {
    expect(true, "same command ID with different text is not a duplicate")
} else {
    expect(false, "same command ID with different text is refused")
}
if let textRecord = textLedger.record(id: "text-typed-1") {
    expect(!textRecord.contentDigest.contains("alpha"),
           "private text digest never contains the raw text")
}

let typedControlJSON: [String: Any] = [
    "v": 1,
    "id": "inspect-typed-1",
    "lane": "engine",
    "action": "inspect_ui",
    "pid": 1999,
    "generation": 3,
    "session": testSession,
    "params": ["bundleIdentifier": "com.apple.Preferences"],
]
if let data = try? JSONSerialization.data(withJSONObject: typedControlJSON),
   let decoded = try? BridgeLANRequestDecoder.control(data) {
    expectEqual(decoded.parameters?.maxDepth, 40,
                "LAN decoder normalizes inspect defaults")
} else {
    expect(false, "LAN decoder accepts typed params")
}
var unknownParameterJSON = typedControlJSON
unknownParameterJSON["params"] = [
    "bundleIdentifier": "com.apple.Preferences",
    "surprise": true,
]
if let data = try? JSONSerialization.data(withJSONObject: unknownParameterJSON) {
    do {
        _ = try BridgeLANRequestDecoder.control(data)
        expect(false, "LAN decoder refuses unknown typed fields")
    } catch let error as BridgeLANRequestError {
        expectEqual(error.code, "unknown_parameters",
                    "LAN decoder unknown typed field code")
    } catch {
        expect(false, "LAN decoder unknown typed field failure type")
    }
}
var missingParameterJSON = typedControlJSON
missingParameterJSON["action"] = "activate_app"
missingParameterJSON["params"] = ["bundleIdentifier": "com.apple.Preferences"]
missingParameterJSON.removeValue(forKey: "params")
if let data = try? JSONSerialization.data(withJSONObject: missingParameterJSON) {
    do {
        _ = try BridgeLANRequestDecoder.control(data)
        expect(false, "LAN decoder requires typed fields for a generic action")
    } catch let error as BridgeLANRequestError {
        expectEqual(error.code, "parameters_required",
                    "LAN decoder required-parameters code")
    } catch {
        expect(false, "LAN decoder required-parameters failure type")
    }
}
var legacyWithParameters = typedControlJSON
legacyWithParameters["action"] = "status"
if let data = try? JSONSerialization.data(withJSONObject: legacyWithParameters) {
    do {
        _ = try BridgeLANRequestDecoder.control(data)
        expect(false, "LAN decoder refuses params on a legacy action")
    } catch let error as BridgeLANRequestError {
        expectEqual(error.code, "parameters_not_applicable",
                    "LAN decoder legacy-parameter refusal code")
    } catch {
        expect(false, "LAN decoder legacy-parameter failure type")
    }
}
var unknownTopLevel = typedControlJSON
unknownTopLevel["surprise"] = true
if let data = try? JSONSerialization.data(withJSONObject: unknownTopLevel) {
    do {
        _ = try BridgeLANRequestDecoder.control(data)
        expect(false, "LAN decoder refuses an unknown top-level field")
    } catch let error as BridgeLANRequestError {
        expectEqual(error.code, "bad_request",
                    "LAN decoder unknown top-level field code")
    } catch {
        expect(false, "LAN decoder top-level failure type")
    }
}

let typedEngineEnvelope = BridgeCommandEnvelope(
    id: "tap-engine-1", action: BridgeControlAction.tap, pid: 1999,
    token: installLike, parameters: validTapParameters,
    expectedGeneration: 3
)
expectEqual(BridgeCommandPolicy.validate(
    typedEngineEnvelope, lane: .engine, expectedPid: 1999,
    expectedToken: installLike, expectedGeneration: 3
), .accepted, "engine policy accepts typed tap arguments")
let missingTypedEnvelope = BridgeCommandEnvelope(
    id: "tap-engine-2", action: BridgeControlAction.tap, pid: 1999,
    token: installLike, expectedGeneration: 3
)
expectEqual(BridgeCommandPolicy.validate(
    missingTypedEnvelope, lane: .engine, expectedPid: 1999,
    expectedToken: installLike, expectedGeneration: 3
), .invalidParameters("parameters_required"),
   "engine policy refuses a generic action without typed arguments")
let legacyTypedEnvelope = BridgeCommandEnvelope(
    id: "status-engine-typed", action: "status", pid: 1999,
    token: installLike, parameters: validTapParameters,
    expectedGeneration: 3
)
expectEqual(BridgeCommandPolicy.validate(
    legacyTypedEnvelope, lane: .engine, expectedPid: 1999,
    expectedToken: installLike, expectedGeneration: 3
), .invalidParameters("parameters_not_applicable"),
   "engine policy refuses typed arguments on a legacy action")

// JSON escapes can expand a valid 4 KiB UTF-8 input to 24 KiB. The transport
// and file envelope must preserve that complete input rather than reject it
// after parameter validation succeeds.
let escapedMaximumText = String(repeating: "\u{0001}", count: 4_096)
let escapedMaximumRequest: [String: Any] = [
    "v": 1, "id": "escaped-maximum-text", "lane": "engine",
    "action": "type_text", "pid": 1999, "generation": 3,
    "session": String(repeating: "a", count: 32),
    "params": ["bundleIdentifier": "com.example.fixture", "text": escapedMaximumText],
]
do {
    let data = try JSONSerialization.data(withJSONObject: escapedMaximumRequest)
    expect(data.count > 16_384 && data.count < 32_768,
           "maximum escaped text exercises the serialized transport boundary")
    let decoded = try BridgeLANRequestDecoder.control(data)
    expectEqual(decoded.parameters?.text, escapedMaximumText,
                "maximum escaped text survives the LAN request decoder")
} catch {
    expect(false, "maximum escaped text survives the LAN request decoder")
}

// MARK: - Read-input-control repair checks

@MainActor
final class SelfCheckChildCounter {
    private(set) var childCountReads = 0
    private(set) var childAccesses = 0

    func noteChildCountRead() { childCountReads += 1 }
    func noteChildAccess() { childAccesses += 1 }
}

@MainActor
final class SelfCheckUINode: BridgeUIElementNode {
    let uiElementTypeName: String
    let uiElementTypeRawValue: Int
    let uiIdentifier: String
    let uiLabel: String
    let uiValue: String?
    let uiPlaceholderValue: String?
    let uiFrameDescription: String
    let uiIsEnabled: Bool
    let uiIsSelected: Bool
    let uiHasFocus: Bool
    let uiIsSecureTextField: Bool
    let children: [SelfCheckUINode]
    let counter: SelfCheckChildCounter?

    init(uiElementTypeName: String,
         uiElementTypeRawValue: Int,
         uiIdentifier: String = "",
         uiLabel: String = "",
         uiValue: String? = nil,
         uiPlaceholderValue: String? = nil,
         uiFrameDescription: String = "0,0,402,874",
         uiIsEnabled: Bool = true,
         uiIsSelected: Bool = false,
         uiHasFocus: Bool = false,
         uiIsSecureTextField: Bool = false,
         uiChildren: [SelfCheckUINode] = [],
         counter: SelfCheckChildCounter? = nil) {
        self.uiElementTypeName = uiElementTypeName
        self.uiElementTypeRawValue = uiElementTypeRawValue
        self.uiIdentifier = uiIdentifier
        self.uiLabel = uiLabel
        self.uiValue = uiValue
        self.uiPlaceholderValue = uiPlaceholderValue
        self.uiFrameDescription = uiFrameDescription
        self.uiIsEnabled = uiIsEnabled
        self.uiIsSelected = uiIsSelected
        self.uiHasFocus = uiHasFocus
        self.uiIsSecureTextField = uiIsSecureTextField
        self.children = uiChildren
        self.counter = counter
    }

    var uiChildCount: Int {
        counter?.noteChildCountRead()
        return children.count
    }

    func uiChild(at index: Int) -> SelfCheckUINode? {
        counter?.noteChildAccess()
        guard children.indices.contains(index) else { return nil }
        return children[index]
    }
}

func uiJSON(_ text: String) -> [String: Any]? {
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any] else { return nil }
    return dictionary
}

let deepSearchField = SelfCheckUINode(
    uiElementTypeName: "SearchField",
    uiElementTypeRawValue: 46,
    uiLabel: "搜索",
    uiValue: "",
    uiPlaceholderValue: "搜索",
    uiFrameDescription: "20,100,362,36"
)
var deepChain = deepSearchField
for _ in 0..<30 {
    deepChain = SelfCheckUINode(
        uiElementTypeName: "Other",
        uiElementTypeRawValue: 1,
        uiFrameDescription: "0,0,402,874",
        uiChildren: [deepChain]
    )
}
let deepSettingsRoot = SelfCheckUINode(
    uiElementTypeName: "Application",
    uiElementTypeRawValue: 1,
    uiFrameDescription: "0,0,402,874",
    uiChildren: [deepChain]
)
let deepRender = BridgeUITreeRenderer.render(root: deepSettingsRoot)
expect(!deepRender.statistics.truncatedDepth,
       "deep Settings-shaped tree fits the default depth")
expect(deepRender.statistics.maxDepthReached >= 30,
       "deep tree reports the real reached depth",
       "reached=\(deepRender.statistics.maxDepthReached)")
expectEqual(deepRender.statistics.returnedNodeCount, 32,
            "deep tree returns every real node")
expect(deepRender.json.contains("搜索"),
       "deep tree reaches the usable search control")

let shallowRender = BridgeUITreeRenderer.render(
    root: deepSettingsRoot,
    limits: BridgeUITreeLimits(maxDepth: 10)
)
expect(shallowRender.statistics.truncatedDepth,
       "depth cap reports truncation")
expect(!shallowRender.json.contains("搜索"),
       "depth cap does not fabricate deep controls")
expect(shallowRender.statistics.maxDepthReached <= 10,
       "depth cap never reports a deeper node")

let nodeCappedRender = BridgeUITreeRenderer.render(
    root: deepSettingsRoot,
    limits: BridgeUITreeLimits(maxNodes: 5)
)
expect(nodeCappedRender.statistics.truncatedNodes,
       "node cap reports truncation")
expectEqual(nodeCappedRender.statistics.returnedNodeCount, 5,
            "node cap bounds returned nodes")

let tooLongLabel = String(repeating: "a", count: 200)
let longLabelRender = BridgeUITreeRenderer.render(
    root: SelfCheckUINode(
        uiElementTypeName: "StaticText",
        uiElementTypeRawValue: 48,
        uiLabel: tooLongLabel,
        uiFrameDescription: "0,0,10,10"
    ),
    limits: BridgeUITreeLimits(maxStringBytes: 32)
)
expectEqual(longLabelRender.statistics.truncatedStrings, 1,
            "per-string cap reports one truncation")
if let object = uiJSON(longLabelRender.json),
   let label = object["label"] as? String {
    expect(label.utf8.count <= 32, "per-string cap bounds the label bytes")
} else {
    expect(false, "per-string cap output parses")
}

let byteCappedRender = BridgeUITreeRenderer.render(
    root: deepSettingsRoot,
    limits: BridgeUITreeLimits(maxTotalBytes: 1_024)
)
expect(byteCappedRender.statistics.truncatedBytes,
       "serialized byte cap reports truncation")
expect(byteCappedRender.utf8Bytes <= 1_024,
       "serialized byte cap keeps the response within bounds",
       "bytes=\(byteCappedRender.utf8Bytes)")

let secureRender = BridgeUITreeRenderer.render(
    root: SelfCheckUINode(
        uiElementTypeName: "SecureTextField",
        uiElementTypeRawValue: 47,
        uiValue: "top-secret-value",
        uiFrameDescription: "20,200,362,36",
        uiIsSecureTextField: true
    )
)
expect(!secureRender.json.contains("top-secret-value"),
       "secure value is never rendered")
expectEqual(secureRender.statistics.secureValueRedactions, 1,
            "secure value redaction is counted")
if let object = uiJSON(secureRender.json),
   let value = object["value"] as? String {
    expectEqual(value, "<redacted>", "secure value is explicitly redacted")
} else {
    expect(false, "secure redaction output parses")
}

// The production traversal must be lazy: the renderer asks for a child only
// after the same depth/node/byte budget admits it. These counters stand in for
// the adapter wrapper construction; an eager `children.map` would touch every
// descendant before the limits ran.
let deepTraversalCounter = SelfCheckChildCounter()
let deepTraversalLeaf = SelfCheckUINode(
    uiElementTypeName: "StaticText",
    uiElementTypeRawValue: 48,
    counter: deepTraversalCounter
)
var deepTraversalChain = deepTraversalLeaf
for _ in 0..<100 {
    deepTraversalChain = SelfCheckUINode(
        uiElementTypeName: "Other",
        uiElementTypeRawValue: 1,
        uiChildren: [deepTraversalChain],
        counter: deepTraversalCounter
    )
}
let deepTraversalRoot = SelfCheckUINode(
    uiElementTypeName: "Application",
    uiElementTypeRawValue: 1,
    uiChildren: [deepTraversalChain],
    counter: deepTraversalCounter
)
let deepTraversalRender = BridgeUITreeRenderer.render(
    root: deepTraversalRoot,
    limits: BridgeUITreeLimits(maxDepth: 8, maxNodes: 100, maxTotalBytes: 65_536)
)
expect(deepTraversalRender.statistics.truncatedDepth,
       "deep traversal reports its depth truncation")
expect(deepTraversalCounter.childAccesses <= 9,
       "depth cap bounds adapter child construction accesses=\(deepTraversalCounter.childAccesses)",
       "accesses=\(deepTraversalCounter.childAccesses)")
expect(deepTraversalCounter.childCountReads <= 10,
       "depth cap bounds child-count reads=\(deepTraversalCounter.childCountReads)",
       "reads=\(deepTraversalCounter.childCountReads)")

let wideTraversalCounter = SelfCheckChildCounter()
var wideLeaves: [SelfCheckUINode] = []
for index in 0..<1_000 {
    wideLeaves.append(SelfCheckUINode(
        uiElementTypeName: "Button",
        uiElementTypeRawValue: 9,
        uiLabel: "row-\(index)",
        counter: wideTraversalCounter
    ))
}
let wideTraversalRoot = SelfCheckUINode(
    uiElementTypeName: "Application",
    uiElementTypeRawValue: 1,
    uiChildren: wideLeaves,
    counter: wideTraversalCounter
)
let wideTraversalRender = BridgeUITreeRenderer.render(
    root: wideTraversalRoot,
    limits: BridgeUITreeLimits(maxDepth: 40, maxNodes: 20, maxTotalBytes: 65_536)
)
expect(wideTraversalRender.statistics.truncatedNodes,
       "wide traversal reports its node truncation")
expectEqual(wideTraversalRender.statistics.returnedNodeCount, 20,
            "wide traversal returns exactly the node cap")
expect(wideTraversalCounter.childAccesses <= 19,
       "node cap bounds adapter child construction accesses=\(wideTraversalCounter.childAccesses)",
       "accesses=\(wideTraversalCounter.childAccesses)")
expect(wideTraversalCounter.childCountReads <= 20,
       "node cap bounds child-count reads=\(wideTraversalCounter.childCountReads)",
       "reads=\(wideTraversalCounter.childCountReads)")

let byteTraversalCounter = SelfCheckChildCounter()
var byteChildren: [SelfCheckUINode] = []
for _ in 0..<200 {
    byteChildren.append(SelfCheckUINode(
        uiElementTypeName: "StaticText",
        uiElementTypeRawValue: 48,
        uiLabel: String(repeating: "x", count: 200),
        counter: byteTraversalCounter
    ))
}
let byteTraversalRoot = SelfCheckUINode(
    uiElementTypeName: "Application",
    uiElementTypeRawValue: 1,
    uiChildren: byteChildren,
    counter: byteTraversalCounter
)
let byteTraversalRender = BridgeUITreeRenderer.render(
    root: byteTraversalRoot,
    limits: BridgeUITreeLimits(maxDepth: 40, maxNodes: 400,
                               maxStringBytes: 512, maxTotalBytes: 1_024)
)
expect(byteTraversalRender.statistics.truncatedBytes,
       "byte-capped traversal reports its byte truncation")
expect(byteTraversalCounter.childAccesses < 200,
       "byte cap stops adapter child construction early accesses=\(byteTraversalCounter.childAccesses)",
       "accesses=\(byteTraversalCounter.childAccesses)")

// Explicit text-field selection.
let appUIFrame = BridgeUIRect(x: 0, y: 0, width: 402, height: 874)
let searchCandidate = BridgeUIEditableField(
    identifier: "settings.search",
    label: "搜索",
    placeholder: "搜索",
    elementType: "SearchField",
    elementTypeRawValue: 46,
    isSecure: false,
    isEditable: true,
    frame: BridgeUIRect(x: 20, y: 100, width: 362, height: 36)
)
let passwordCandidate = BridgeUIEditableField(
    identifier: "settings.password",
    label: "Password",
    placeholder: "Password",
    elementType: "SecureTextField",
    elementTypeRawValue: 47,
    isSecure: true,
    isEditable: true,
    frame: BridgeUIRect(x: 20, y: 200, width: 362, height: 36)
)
let nonEditableCandidate = BridgeUIEditableField(
    identifier: "settings.cell",
    label: "Wi-Fi",
    placeholder: "",
    elementType: "Cell",
    elementTypeRawValue: 75,
    isSecure: false,
    isEditable: false,
    frame: BridgeUIRect(x: 0, y: 300, width: 402, height: 44)
)
let textCandidates = [searchCandidate, passwordCandidate, nonEditableCandidate]

func targetFailure(_ target: BridgeUITextTarget,
                   fields: [BridgeUIEditableField] = textCandidates) -> BridgeUITextTargetError? {
    if case .failure(let error) = BridgeUITextTargetSelector.select(
        target: target, fields: fields, appFrame: appUIFrame
    ) {
        return error
    }
    return nil
}

if case .success(let byIdentifier) = BridgeUITextTargetSelector.select(
    target: .identifier("settings.search"),
    fields: textCandidates,
    appFrame: appUIFrame
) {
    expectEqual(byIdentifier.strategy, "identifier",
                "identifier selection reports its strategy")
    expectEqual(byIdentifier.field.identifier, "settings.search",
                "identifier selection returns the exact field")
} else {
    expect(false, "unique identifier selects one field")
}
expectEqual(targetFailure(.identifier("missing"))?.code, "target_missing",
            "missing identifier is refused")
expectEqual(targetFailure(.identifier("settings.password"))?.code,
            "secure_input_refused", "secure identifier is refused")
expectEqual(targetFailure(.identifier("settings.cell"))?.code,
            "target_not_editable", "non-editable identifier is refused")

if case .success(let byLabel) = BridgeUITextTargetSelector.select(
    target: .label("搜索"), fields: textCandidates, appFrame: appUIFrame
) {
    expectEqual(byLabel.field.identifier, "settings.search",
                "unique label selects the field")
} else {
    expect(false, "unique label selects one field")
}
if case .success(let byPlaceholder) = BridgeUITextTargetSelector.select(
    target: .placeholder("搜索"), fields: textCandidates, appFrame: appUIFrame
) {
    expectEqual(byPlaceholder.field.identifier, "settings.search",
                "unique placeholder selects the field")
} else {
    expect(false, "unique placeholder selects one field")
}
expectEqual(targetFailure(.label("Password"))?.code,
            "secure_input_refused", "secure label is refused")
expectEqual(targetFailure(.label("搜索"), fields: [searchCandidate, searchCandidate])?.code,
            "ambiguous_target", "duplicate label is ambiguous")
expectEqual(targetFailure(.point(normalizedX: 0.5, normalizedY: 0.13))?.code,
            nil, "point inside one editable field is accepted")
expectEqual(targetFailure(.point(normalizedX: 0.5, normalizedY: 0.25))?.code,
            "secure_input_refused", "point inside a secure field is refused")
expectEqual(targetFailure(.point(normalizedX: 0.5, normalizedY: 0.9))?.code,
            "target_missing", "point outside all fields is refused")
let overlappingLeft = BridgeUIEditableField(
    identifier: "left", label: "Left", placeholder: "",
    elementType: "TextField", elementTypeRawValue: 45,
    isSecure: false, isEditable: true,
    frame: BridgeUIRect(x: 0, y: 100, width: 300, height: 50)
)
let overlappingRight = BridgeUIEditableField(
    identifier: "right", label: "Right", placeholder: "",
    elementType: "TextField", elementTypeRawValue: 45,
    isSecure: false, isEditable: true,
    frame: BridgeUIRect(x: 200, y: 100, width: 200, height: 50)
)
expectEqual(targetFailure(.point(normalizedX: 0.62, normalizedY: 0.14),
                          fields: [overlappingLeft, overlappingRight])?.code,
            "ambiguous_target", "distinct overlapping fields are ambiguous")
let nestedOuter = BridgeUIEditableField(
    identifier: "outer", label: "Outer", placeholder: "",
    elementType: "TextField", elementTypeRawValue: 45,
    isSecure: false, isEditable: true,
    frame: BridgeUIRect(x: 20, y: 100, width: 362, height: 36)
)
let nestedInner = BridgeUIEditableField(
    identifier: "inner", label: "Outer", placeholder: "",
    elementType: "TextView", elementTypeRawValue: 52,
    isSecure: false, isEditable: true,
    frame: BridgeUIRect(x: 20, y: 100, width: 362, height: 36)
)
if case .success(let nestedSelection) = BridgeUITextTargetSelector.select(
    target: .point(normalizedX: 0.5, normalizedY: 0.13),
    fields: [nestedOuter, nestedInner],
    appFrame: appUIFrame
) {
    expectEqual(nestedSelection.field.elementType, "TextField",
                "identical nested field frames collapse to the outer text field")
} else {
    expect(false, "identical nested field frames collapse")
}
let zeroFrame = BridgeUIEditableField(
    identifier: "zero", label: "Zero", placeholder: "",
    elementType: "TextField", elementTypeRawValue: 45,
    isSecure: false, isEditable: true,
    frame: BridgeUIRect(x: 0, y: 0, width: 0, height: 0)
)
expectEqual(targetFailure(.identifier("zero"), fields: [zeroFrame])?.code,
            "target_not_reachable", "zero-frame field is unreachable")

// The selector schema is closed and rejects ambiguous combinations before the
// file channel or SDK ever sees them.
expectEqual(parameterCode(BridgeControlArguments.validate(
    action: BridgeControlAction.typeText,
    parameters: BridgeControlParameters(bundleIdentifier: "com.apple.Preferences",
                                        label: "搜索", text: "x")
)), "ok", "type_text accepts one label selector")
expectEqual(parameterCode(BridgeControlArguments.validate(
    action: BridgeControlAction.typeText,
    parameters: BridgeControlParameters(bundleIdentifier: "com.apple.Preferences",
                                        identifier: "a", label: "b", text: "x")
)), "ambiguous_arguments", "type_text refuses two selectors")
expectEqual(parameterCode(BridgeControlArguments.validate(
    action: BridgeControlAction.typeText,
    parameters: BridgeControlParameters(bundleIdentifier: "com.apple.Preferences",
                                        normalizedX: 0.5, text: "x")
)), "ambiguous_arguments", "type_text refuses a partial point")
expectEqual(parameterCode(BridgeControlArguments.validate(
    action: BridgeControlAction.typeText,
    parameters: BridgeControlParameters(bundleIdentifier: "com.apple.Preferences",
                                        label: String(repeating: "a", count: 513), text: "x")
)), "invalid_selector", "type_text refuses an oversized label")
expectEqual(parameterCode(BridgeControlArguments.validate(
    action: BridgeControlAction.typeText,
    parameters: BridgeControlParameters(bundleIdentifier: "com.apple.Preferences",
                                        text: "x")
)), "ok", "type_text keeps the selectorless focused-field path")
let labeledParameters = BridgeControlParameters(
    bundleIdentifier: "com.apple.Preferences", label: "搜索", text: "secret-typed"
)
if let target = labeledParameters.textTarget,
   case .label(let value) = target {
    expectEqual(value, "搜索", "validated parameters expose the label target")
} else {
    expect(false, "validated parameters expose the label target")
}
if let summary = labeledParameters.summaryJSON() {
    expect(summary.contains("\"label\":\"搜索\""),
           "parameter summary carries the selector")
    expect(!summary.contains("secret-typed"),
           "parameter summary never carries raw text")
} else {
    expect(false, "labeled parameter summary is available")
}
expect(
    BridgeControlArguments.contentDigest(action: BridgeControlAction.typeText,
                                          parameters: labeledParameters) !=
    BridgeControlArguments.contentDigest(
        action: BridgeControlAction.typeText,
        parameters: BridgeControlParameters(
            bundleIdentifier: "com.apple.Preferences", label: "Wi-Fi",
            text: "secret-typed"
        )
    ),
    "changing the field selector changes the private content digest"
)

// Append-only value evidence: a normal return is not enough, and an unchanged
// value must not pass through exact/suffix matching.
let unchangedAlreadyMatching = BridgeTextValueAssessor.assess(
    beforeValue: "Floe",
    beforeTrusted: true,
    request: "Floe",
    afterValue: "Floe"
)
expectEqual(unchangedAlreadyMatching.observation, "unchanged",
            "unchanged already-matching value is not an append")
expect(!unchangedAlreadyMatching.appendVerified,
       "unchanged already-matching value never verifies typing")
expect(unchangedAlreadyMatching.valueMatchesRequest,
       "unchanged value is only weaker request-match evidence")

let emptyBaseAppend = BridgeTextValueAssessor.assess(
    beforeValue: "",
    beforeTrusted: true,
    request: "Floe",
    afterValue: "Floe"
)
expect(emptyBaseAppend.appendVerified,
       "trusted empty base plus exact request verifies the append")
expectEqual(emptyBaseAppend.observation, "empty-base-append-verified",
            "empty-base append observation is explicit")

let nonEmptyAppend = BridgeTextValueAssessor.assess(
    beforeValue: "Hello",
    beforeTrusted: true,
    request: "Floe",
    afterValue: "HelloFloe"
)
expect(nonEmptyAppend.appendVerified,
       "trusted nonempty base plus expected append verifies typing")
expectEqual(nonEmptyAppend.observation, "append-verified",
            "nonempty append observation is explicit")

let untrustedBefore = BridgeTextValueAssessor.assess(
    beforeValue: nil,
    beforeTrusted: false,
    request: "Floe",
    afterValue: "Floe"
)
expect(!untrustedBefore.appendVerified,
       "request match without a trustworthy before value is not verified")
expectEqual(untrustedBefore.observation, "matches-request-before-unavailable",
            "untrusted before value is labeled as weaker evidence")

let suffixCoincidence = BridgeTextValueAssessor.assess(
    beforeValue: "abc",
    beforeTrusted: true,
    request: "Floe",
    afterValue: "abcFloeFloe"
)
expect(!suffixCoincidence.appendVerified,
       "suffix-only coincidence is not a verified append")
expectEqual(suffixCoincidence.observation, "suffix-coincidence",
            "suffix-only evidence is labeled explicitly")

let replacementOrMatch = BridgeTextValueAssessor.assess(
    beforeValue: "abc",
    beforeTrusted: true,
    request: "Floe",
    afterValue: "Floe"
)
expect(!replacementOrMatch.appendVerified,
       "request-equal replacement is not a verified append")
expectEqual(replacementOrMatch.observation, "replacement-or-request-match",
            "request-equal replacement is weaker evidence")

// Scoped XCTest issue capture and call-outcome classification. These are the
// same types the embedded engine and the native XCTest record-hook probe use.
let issueCapture = BridgeEngineIssueCapture()
let firstScope = issueCapture.begin()
issueCapture.noteIssue()
let firstCount = issueCapture.end(firstScope)
expectEqual(firstCount, 1, "issue capture counts one active scope")
expectEqual(issueCapture.end(firstScope), 0,
            "an ended issue scope cannot be counted twice")

let outerScope = issueCapture.begin()
let innerScope = issueCapture.begin()
issueCapture.noteIssue()
let innerCount = issueCapture.end(innerScope)
let outerCount = issueCapture.end(outerScope)
expectEqual(innerCount, 1, "nested inner issue scope counts")
expectEqual(outerCount, 1, "nested outer issue scope counts inclusively")

let cleanReturn = BridgeSDKCallOutcome(entered: true, returned: true)
expectEqual(cleanReturn.classification, "returned-clean",
            "clean return classification")
expectEqual(cleanReturn.textDispatchClaim(actualValueVerified: false), "unknown",
            "clean return alone is not a text dispatch proof")
expect(!cleanReturn.focusClaim(probeMatched: false, actualValueVerified: false),
       "clean return alone is not a focus proof")
expectEqual(cleanReturn.mutationDispatchClaim(), "true",
            "clean return is the tap/swipe event signal")

let returnedWithIssue = BridgeSDKCallOutcome(
    entered: true, returned: true, recordedIssueCount: 1
)
expectEqual(returnedWithIssue.classification, "returned-with-issue",
            "returned-with-issue classification")
expectEqual(returnedWithIssue.textDispatchClaim(actualValueVerified: false), "unknown",
            "returned-with-issue without value proof is unknown dispatch")
expectEqual(returnedWithIssue.mutationDispatchClaim(), "unknown",
            "returned-with-issue is unknown for tap/swipe")
expect(returnedWithIssue.textDispatchClaim(actualValueVerified: true) == "true",
       "independent value equality can prove an effect despite an issue")

let focusRefused = BridgeSDKCallOutcome(
    entered: true, returned: false, focusRefused: true
)
expectEqual(focusRefused.classification, "focus-refused",
            "focus refusal classification")
expectEqual(focusRefused.textDispatchClaim(actualValueVerified: false), "false",
            "SDK focus refusal proves no text dispatch")

let thrownCall = BridgeSDKCallOutcome(entered: true, returned: false)
expectEqual(thrownCall.classification, "threw", "thrown call classification")
expectEqual(thrownCall.textDispatchClaim(actualValueVerified: false), "unknown",
            "thrown text call is unknown")
expectEqual(thrownCall.mutationDispatchClaim(), "unknown",
            "thrown tap/swipe is unknown")

// Home evidence classification: departure and a real SpringBoard foreground
// are distinct facts.
let homeFromCalculator = BridgeHomeEvidence.assess(BridgeHomeObservation(
    sourceBundleIdentifier: "com.apple.calculator",
    sourceStateBefore: "runningForeground",
    sourceStateAfter: "runningBackground",
    springboardStateBefore: "runningBackground",
    springboardStateAfter: "runningForeground",
    hostStateBefore: "active",
    hostStateAfter: "background",
    pressReturned: true
))
expect(homeFromCalculator.actualHomeObserved,
       "Calculator departure + SpringBoard foreground verifies Home")
expectEqual(homeFromCalculator.homeEvidence,
            "springboard-foreground-after-source-departure",
            "Home evidence names the actual observation")
expect(homeFromCalculator.destinationVerified,
       "verified Home is a real destination observation")
expectEqual(homeFromCalculator.status, "ok", "verified Home status is ok")

let departureOnly = BridgeHomeEvidence.assess(BridgeHomeObservation(
    sourceBundleIdentifier: "com.apple.calculator",
    sourceStateBefore: "runningForeground",
    sourceStateAfter: "runningBackground",
    springboardStateBefore: "runningBackground",
    springboardStateAfter: "unknown",
    hostStateBefore: "active",
    hostStateAfter: "active",
    pressReturned: true
))
expect(!departureOnly.actualHomeObserved,
       "source departure alone is not a Home claim")
expectEqual(departureOnly.homeEvidence, "source-left-foreground-only",
            "departure-only evidence is labeled honestly")
expectEqual(departureOnly.status, "unverified",
            "departure-only Home is unverified")

let laggingSource = BridgeHomeEvidence.assess(BridgeHomeObservation(
    sourceBundleIdentifier: "com.apple.Preferences",
    sourceStateBefore: "runningForeground",
    sourceStateAfter: "runningForeground",
    springboardStateBefore: "runningBackground",
    springboardStateAfter: "runningForeground",
    hostStateBefore: "active",
    hostStateAfter: "background",
    pressReturned: true
))
expect(laggingSource.actualHomeObserved,
       "SpringBoard transition verifies Home even when the source state lags")
expect(!laggingSource.sourceLeftForeground,
       "lagging source departure remains a separate false fact")
expectEqual(laggingSource.homeEvidence, "springboard-foreground-transition",
            "lagging-source Home evidence names the actual observation")

let sourceStillForeground = BridgeHomeEvidence.assess(BridgeHomeObservation(
    sourceBundleIdentifier: "com.apple.Preferences",
    sourceStateBefore: "runningForeground",
    sourceStateAfter: "runningForeground",
    springboardStateBefore: "runningForeground",
    springboardStateAfter: "runningForeground",
    hostStateBefore: "active",
    hostStateAfter: "background",
    pressReturned: true
))
expect(!sourceStillForeground.actualHomeObserved,
       "an unmoved source plus unchanged SpringBoard is not claimed as Home")
expectEqual(sourceStillForeground.homeEvidence, "source-still-foreground",
            "unmoved source evidence is labeled")

let homeUnknownSource = BridgeHomeEvidence.assess(BridgeHomeObservation(
    sourceBundleIdentifier: nil,
    sourceStateBefore: "unknown",
    sourceStateAfter: "unknown",
    springboardStateBefore: "runningBackground",
    springboardStateAfter: "runningForeground",
    hostStateBefore: "active",
    hostStateAfter: "background",
    pressReturned: true
))
expect(homeUnknownSource.actualHomeObserved,
       "SpringBoard foreground verifies Home without a source app")
expectEqual(homeUnknownSource.homeEvidence,
            "springboard-foreground-transition",
            "unknown-source Home evidence names the SpringBoard transition")

let failedHome = BridgeHomeEvidence.assess(BridgeHomeObservation(
    sourceBundleIdentifier: "com.apple.calculator",
    sourceStateBefore: "runningForeground",
    sourceStateAfter: "runningForeground",
    springboardStateBefore: "runningBackground",
    springboardStateAfter: "runningBackground",
    hostStateBefore: "active",
    hostStateAfter: "active",
    pressReturned: false
))
expectEqual(failedHome.status, "error", "failed press without observation is an error")
expectEqual(failedHome.homeEvidence, "press-not-returned",
            "failed press is not labeled as a departure")

let failedButObserved = BridgeHomeEvidence.assess(BridgeHomeObservation(
    sourceBundleIdentifier: "com.apple.calculator",
    sourceStateBefore: "runningForeground",
    sourceStateAfter: "runningBackground",
    springboardStateBefore: "runningBackground",
    springboardStateAfter: "runningForeground",
    hostStateBefore: "active",
    hostStateAfter: "background",
    pressReturned: false
))
expect(failedButObserved.actualHomeObserved,
       "a raised press call can still be verified by actual state")
expectEqual(failedButObserved.status, "ok",
            "observed Home is not reported as canceled")

// A maximum escaped text plus the largest selector label must still fit the
// shared 32 KiB request ceiling and survive the LAN decoder.
let escapedWithLabel: [String: Any] = [
    "v": 1, "id": "escaped-with-label", "lane": "engine",
    "action": "type_text", "pid": 1999, "generation": 3,
    "session": String(repeating: "b", count: 32),
    "params": [
        "bundleIdentifier": "com.example.fixture",
        "label": String(repeating: "a", count: 512),
        "text": String(repeating: "\u{0001}", count: 4_096),
    ],
]
do {
    let data = try JSONSerialization.data(withJSONObject: escapedWithLabel)
    expect(data.count < 32_768,
           "maximum escaped text plus a selector stays under the transport ceiling",
           "bytes=\(data.count)")
    let decoded = try BridgeLANRequestDecoder.control(data)
    expectEqual(decoded.parameters?.label?.utf8.count, 512,
                "selector label survives the LAN request decoder")
    expectEqual(decoded.parameters?.text?.utf8.count, 4_096,
                "maximum text survives the selector request decoder")
} catch {
    expect(false, "maximum text with a selector survives the LAN request decoder")
}

// exit() bypasses top-level defer, so remove the real filesystem fixture here.
try? FileManager.default.removeItem(at: ddiFixtureRoot)

print(failures == 0 ? "SELF-CHECK PASS checks=\(checks)" : "SELF-CHECK FAIL checks=\(checks) failures=\(failures)")
exit(failures == 0 ? 0 : 1)
