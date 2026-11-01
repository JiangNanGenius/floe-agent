import CryptoKit
import Foundation

import BridgeCore
import BridgeHost
struct TestCase {
    let name: String
    let body: () async throws -> Void
}

func allTests() -> [TestCase] {
    [
        TestCase(name: "envelopeKnownVector", body: envelopeKnownVector),
        TestCase(name: "envelopeStrictRejection", body: envelopeStrictRejection),
        TestCase(name: "dualStackSchemaAndResources", body: dualStackSchemaAndResources),
        TestCase(name: "lanDefaultOffAndPlainForbidden", body: lanDefaultOffAndPlainForbidden),
        TestCase(name: "pairPlainRPCAndOwnerOnlyWrites", body: pairPlainRPCAndOwnerOnlyWrites),
        TestCase(name: "pairDenyAndTimeoutCooldown", body: pairDenyAndTimeoutCooldown),
        TestCase(name: "pairSlotsIndependent", body: pairSlotsIndependent),
        TestCase(name: "x25519KnownClient", body: x25519KnownClient),
        TestCase(name: "replaySkewFloodAndUnknownKey", body: replaySkewFloodAndUnknownKey),
        TestCase(name: "idleExpiryAndRevocation", body: idleExpiryAndRevocation),
        TestCase(name: "nonceDurabilityAndFailClosed", body: nonceDurabilityAndFailClosed),
        TestCase(name: "durableAuthorizationAndRevocation", body: durableAuthorizationAndRevocation),
        TestCase(name: "logsAndStreamTickets", body: logsAndStreamTickets),
        TestCase(name: "streamUnavailableAndRevocation", body: streamUnavailableAndRevocation),
        TestCase(name: "streamBufferBound", body: streamBufferBound),
        TestCase(name: "engineReadinessAndSensitiveInput", body: engineReadinessAndSensitiveInput),
        TestCase(name: "engineSurvivesStopAndRegistersOnce", body: engineSurvivesStopAndRegistersOnce),
        TestCase(name: "registrySingleRegistration", body: registrySingleRegistration),
        TestCase(name: "operationExactlyOnceAndUnknown", body: operationExactlyOnceAndUnknown),
        TestCase(name: "queueBoundAndCancel", body: queueBoundAndCancel),
        TestCase(name: "executionTimeoutNeverReplays", body: executionTimeoutNeverReplays),
        TestCase(name: "coordinatorTimeoutBeforeDispatch", body: coordinatorTimeoutBeforeDispatch),
        TestCase(name: "cooperativeStagesFenced", body: cooperativeStagesFenced),
        TestCase(name: "commitGateHeldResponseAndPartialStop", body: commitGateHeldResponseAndPartialStop),
        TestCase(name: "responseLimit", body: responseLimit),
        TestCase(name: "largeResultFirstReturnNotCached", body: largeResultFirstReturnNotCached),
        TestCase(name: "httpParserLimits", body: httpParserLimits),
        TestCase(name: "stopClosesTicketsAndConnections", body: stopClosesTicketsAndConnections),
        TestCase(name: "configStopAndHostSnapshot", body: configStopAndHostSnapshot)
    ]
}

// MARK: - Envelope

func envelopeKnownVector() throws {
    // Vector generated independently with Python's hashlib/hmac using the
    // pinned v1 construction, not this implementation.
    let key = Data((0..<32).map(UInt8.init))
    let nonce = Data((0..<16).map(UInt8.init))
    let timestamp = 1_700_000_000
    let plaintext = Data(#"{"id":1,"jsonrpc":"2.0","method":"device_info"}"#.utf8)
    let request = BridgeRPCEnvelope.sealRequest(plaintext, key: key, nonce: nonce, timestamp: timestamp)
    let object = request.objectValue!
    try expectEqual(object["tok"]?.stringValue, "630dcd29", "token id")
    try expectEqual(object["ct"]?.stringValue,
                    "LBWCQvXPN3n1VJyojcZyCT+qamW0x3ZEeZftn9zQ5NohSRVhTnMrexYNVUnnbeo=",
                    "request ciphertext")
    try expectEqual(object["tag"]?.stringValue,
                    "59519f46ceec95fbc41aad96b85098cae37fc8e91f4f63b5228bcc672fb0d0fe",
                    "request tag")
    let parsed = try BridgeRPCEnvelope.parse(request)
    let opened = try BridgeRPCEnvelope.open(parsed, key: key)
    try expectEqual(opened, plaintext, "request plaintext")
    try expectEqual(BridgeRPCEnvelope.tokenID(for: key), "630dcd29", "token id helper")

    let responsePlaintext = Data(#"{"id":1,"jsonrpc":"2.0","result":{"ok":true}}"#.utf8)
    let sealed = try expectNotNil(
        BridgeRPCEnvelope.sealResponse(responsePlaintext, key: key, nonce: nonce,
                                       nonceHex: BridgeRPCEnvelope.hexLowercase(nonce)),
        "sealed response"
    )
    let responseObject = try BridgeRPCJSON.decode(sealed)
    try expectEqual(responseObject.objectValue?["ct"]?.stringValue,
                    "LWca1EWiHk4JimI4eCduEwxp3qSclaRMXU5BQkcw6Yo8vWPtRDu1cZH3okaD",
                    "response ciphertext")
    try expectEqual(responseObject.objectValue?["tag"]?.stringValue,
                    "d8c8bbce687a80a243893a2507821623f37b76d0abd24246c2e301a2b211fbc1",
                    "response tag")
    let reopened = try BridgeRPCEnvelope.openResponse(
        responseObject, key: key, expectedNonceHex: BridgeRPCEnvelope.hexLowercase(nonce)
    )
    try expectEqual(reopened, responsePlaintext, "response plaintext")
}

func envelopeStrictRejection() throws {
    let key = Data(repeating: 7, count: 32)
    let nonce = Data(repeating: 9, count: 16)
    let good = BridgeRPCEnvelope.sealRequest(Data("{}".utf8), key: key, nonce: nonce,
                                             timestamp: 1_700_000_000)
    var object = good.objectValue!
    object["tok"] = .string("630DCD29")
    do {
        _ = try BridgeRPCEnvelope.parse(.object(object))
        throw TestFailure("uppercase token was accepted")
    } catch is BridgeRPCEnvelope.Failure {}
    object = good.objectValue!
    object["ts"] = .double(1_700_000_000.5)
    do {
        _ = try BridgeRPCEnvelope.parse(.object(object))
        throw TestFailure("fractional timestamp was accepted")
    } catch is BridgeRPCEnvelope.Failure {}
    object = good.objectValue!
    object["ct"] = .string("!!!!")
    do {
        _ = try BridgeRPCEnvelope.parse(.object(object))
        throw TestFailure("bad base64 was accepted")
    } catch is BridgeRPCEnvelope.Failure {}
    object = good.objectValue!
    object["tag"] = .string(String(repeating: "0", count: 64))
    let parsed = try BridgeRPCEnvelope.parse(.object(object))
    do {
        _ = try BridgeRPCEnvelope.open(parsed, key: key)
        throw TestFailure("bad tag was accepted")
    } catch let failure as BridgeRPCEnvelope.Failure {
        try expectEqual(failure.code, "auth_failed", "bad tag code")
    }
}

// MARK: - Transport / schema / LAN

func dualStackSchemaAndResources() async throws {
    try expectEqual(BridgeRPCService.Configuration().requestedPort, 8200,
                    "product default port is 8200")
    let fixture = ServerFixture()
    let port = try fixture.start()
    defer { fixture.stop() }

    let v4 = try RawHTTP.request(host: "127.0.0.1", port: port, method: "GET", path: "/schema")
    try expectEqual(v4.status, 200, "IPv4 schema status")
    let schema = try BridgeRPCJSON.decode(v4.body).objectValue!
    let methods = schema["methods"]?.arrayValue ?? []
    try expectEqual(methods.count, 33, "33 pinned methods")
    let names = Set(methods.compactMap { $0.objectValue?["name"]?.stringValue })
    for required in ["config", "stream_ticket", "device_info", "page_source", "screen_text",
                     "screenshot", "tap", "type", "clear_text", "drag", "launch_app"] {
        try expect(names.contains(required), "method \(required) present")
    }
    let typeParams = methods.first { $0.objectValue?["name"]?.stringValue == "type" }?
        .objectValue?["params"]?.arrayValue ?? []
    try expect(typeParams.contains { $0.objectValue?["name"]?.stringValue == "text"
        && $0.objectValue?["required"]?.boolValue == true }, "type.text required")
    let capabilities = schema["capability_tags"]?.arrayValue?.compactMap(\.stringValue) ?? []
    try expect(capabilities.contains("envelope_v1"), "envelope capability")
    try expect(!capabilities.contains("device_info"), "unregistered engine method not advertised")
    try expect(!capabilities.contains("stream"), "no stream advertised without a source")

    let v6 = try RawHTTP.request(host: "::1", port: port, method: "GET", path: "/schema")
    try expectEqual(v6.status, 200, "IPv6 schema status")
    let halfClosed = try RawHTTP.request(host: "127.0.0.1", port: port, method: "GET",
                                         path: "/schema", halfClose: true)
    try expectEqual(halfClosed.status, 200, "request followed by write-half-close is served")

    let info = try RawHTTP.request(host: "127.0.0.1", port: port, method: "GET", path: "/")
    try expectEqual(info.status, 200, "root info status")
    let infoObject = try BridgeRPCJSON.decode(info.body).objectValue!
    try expectEqual(infoObject["engine"]?.stringValue, "not_registered", "engine state")
    try expectEqual(infoObject["lan_enabled"]?.boolValue, false, "LAN default off")

    let skill = try RawHTTP.request(host: "127.0.0.1", port: port, method: "GET", path: "/skill")
    try expectEqual(skill.status, 200, "skill status")
    try expectContains(String(decoding: skill.body, as: UTF8.self), "ENDPOINTS", "skill resource")
    let skillAlias = try RawHTTP.request(host: "127.0.0.1", port: port, method: "GET", path: "/skill.md")
    try expectEqual(skillAlias.status, 200, "skill.md alias")

    let remote = try RawHTTP.request(host: "127.0.0.1", port: port, method: "GET", path: "/remote")
    try expectEqual(remote.status, 200, "injected remote page")
    try expectContains(String(decoding: remote.body, as: UTF8.self), "<title>Bridge", "remote page body")
    try expectEqual(remote.headers["x-frame-options"], "DENY", "remote cannot be framed")
    try expectEqual(remote.headers["referrer-policy"], "no-referrer", "remote does not leak its URL")
    try expectEqual(remote.headers["cache-control"], "no-store", "remote response is not cached")
    try expectEqual(remote.headers["x-content-type-options"], "nosniff", "remote content type enforced")

    let missing = ServerFixture(resources: BridgeRPCEmptyResources())
    let missingPort = try missing.start()
    defer { missing.stop() }
    let noSkill = try RawHTTP.request(host: "127.0.0.1", port: missingPort, method: "GET", path: "/skill")
    try expectEqual(noSkill.status, 503, "missing skill explicit")
    let noRemote = try RawHTTP.request(host: "127.0.0.1", port: missingPort, method: "GET", path: "/remote")
    try expectEqual(noRemote.status, 503, "missing remote explicit")
}

func lanDefaultOffAndPlainForbidden() async throws {
    let fixture = ServerFixture()
    let port = try fixture.start()
    defer { fixture.stop() }
    try expectEqual(fixture.server.snapshot.lanEnabled, false, "LAN default off")
    try expectEqual(fixture.server.snapshot.lanIPv4Ready, false, "no LAN socket by default")

    let addresses = lanIPv4Addresses()
    guard let lan = addresses.first else {
        throw TestFailure("environment has no normal-LAN IPv4 interface for the LAN test")
    }
    // Before enabling LAN there must be no wildcard listener on this port.
    do {
        _ = try RawHTTP.request(host: lan, port: port, method: "GET", path: "/schema")
        throw TestFailure("LAN connected while LAN was disabled")
    } catch is HTTPClientError {}

    let lanPeer = BridgeRPCNetworkPeer.classify(fakeIPv4Sockaddr(lan))
    try expectEqual(lanPeer.via, .lan, "LAN address classified as LAN")
    try expectEqual(lanPeer.isLoopback, false, "LAN address not loopback")
    try expect(!lanPeer.allowsPlainPairing, "LAN peer cannot use plain pairing")
    let loopPeer = BridgeRPCNetworkPeer.classify(fakeIPv4Sockaddr("127.0.0.1"))
    try expect(loopPeer.allowsPlainPairing, "loopback peer allows plain pairing")
    let loop6 = BridgeRPCNetworkPeer.classify(fakeIPv6Sockaddr("::1"))
    try expect(loop6.isLoopback, "IPv6 ::1 classified loopback")
    try expectEqual(BridgeRPCNetworkPeer.via(for: "awdl0"), .nearby, "AWDL classified nearby")
    try expectEqual(BridgeRPCNetworkPeer.via(for: "pdp_ip0"), .cellular, "cellular classified")
    try expectEqual(BridgeRPCNetworkPeer.via(for: "utun4"), .vpn, "VPN classified")

    try fixture.server.setLANEnabled(true, bonjour: false)
    try expect(fixture.server.snapshot.lanIPv4Ready, "LAN IPv4 listener ready")
    let loopback = try RawHTTP.request(host: "127.0.0.1", port: port, method: "GET", path: "/schema")
    try expectEqual(loopback.status, 200, "loopback remains ready with LAN")

    let lanSchema = try RawHTTP.request(host: lan, port: port, method: "GET", path: "/schema")
    try expectEqual(lanSchema.status, 200, "LAN schema over a normal LAN address")
    if let lan6 = lanIPv6Addresses().first {
        let lan6Schema = try RawHTTP.request(host: lan6, port: port, method: "GET", path: "/schema")
        try expectEqual(lan6Schema.status, 200, "LAN IPv6 schema over a normal LAN address")
    }

    let plainBody = BridgeRPCJSONValue.object([
        "client_name": .string("lan-plain"),
        "plain": .bool(true),
    ]).canonicalData()
    let realPlain = try RawHTTP.request(host: lan, port: port, method: "POST",
                                        path: "/pair",
                                        extraHeaders: ["X-Forwarded-For": "127.0.0.1",
                                                       "X-Real-IP": "::1"],
                                        body: plainBody)
    try expectEqual(realPlain.status, 403, "real LAN plain pairing denied despite spoofed headers")
    let realPlainError = try BridgeRPCJSON.decode(realPlain.body).objectValue?["error"]?.objectValue
    try expectEqual(realPlainError?["code"]?.stringValue, "plain_forbidden",
                    "real LAN plain code")
    if let lan6 = lanIPv6Addresses().first {
        let realPlain6 = try RawHTTP.request(host: lan6, port: port, method: "POST",
                                             path: "/pair", body: plainBody)
        try expectEqual(realPlain6.status, 403, "real IPv6 LAN plain pairing denied")
    }
    let request = BridgeRPCHTTPRequest(
        method: "POST",
        path: "/pair",
        pathOnly: "/pair",
        query: "",
        headers: [:],
        body: plainBody
    )
    let result = await fixture.service.handle(request, peer: lanPeer)
    guard case .response(let response) = result else {
        throw TestFailure("LAN plain pair did not return an HTTP response")
    }
    try expectEqual(response.status, 403, "plain LAN denied")
    let error = try BridgeRPCJSON.decode(response.body).objectValue?["error"]?.objectValue
    try expectEqual(error?["code"]?.stringValue, "plain_forbidden", "plain forbidden code")
    try expectEqual(fixture.store.count(), 0, "no client minted for denied plain LAN")
    try fixture.server.setLANEnabled(false, bonjour: false)
    try expectEqual(fixture.server.snapshot.lanEnabled, false, "LAN can be disabled")
    let afterDisable = try RawHTTP.request(host: "127.0.0.1", port: port, method: "GET",
                                           path: "/schema")
    try expectEqual(afterDisable.status, 200, "loopback survives LAN disable")
}

// MARK: - Pairing / auth

func pairPlainRPCAndOwnerOnlyWrites() async throws {
    let fixture = ServerFixture()
    let port = try fixture.start()
    defer { fixture.stop() }
    let paired = try BridgeTestClient.pairPlain(host: "127.0.0.1", port: port, name: "unit-client")
    try expectEqual(fixture.store.count(), 1, "one client stored")
    let stored = fixture.store.stored(clientID: paired.session.tokenID)
    try expect(stored?.keyHex == BridgeRPCEnvelope.hexLowercase(paired.session.key),
               "key stored under token id")

    let config = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                           port: port, method: "config")
    let configResult = try expectNotNil(BridgeTestClient.resultObject(config), "config result")
    try expectEqual(configResult["port"]?.intValue, Int(port), "config port")
    try expectEqual(configResult["lan_enabled"]?.boolValue, false, "config LAN false")
    let clients = configResult["clients"]?.arrayValue ?? []
    try expectEqual(clients.count, 1, "one client in config")
    let clientObject = clients.first?.objectValue
    try expectEqual(clientObject?["client_id"]?.stringValue, paired.session.tokenID, "client id")
    try expectEqual(clientObject?["sensitive_input_granted"]?.boolValue, false,
                    "sensitive input default off")
    try expect(configResult["engine"]?.objectValue?["state"]?.stringValue == "not_registered",
               "engine not registered")

    let engineError = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                                port: port, method: "device_info")
    try expectEqual(BridgeTestClient.errorCode(engineError), -32010, "engine not ready code")
    let denied = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                           port: port, method: "config",
                                           params: .object(["allow_remote_access": .bool(true)]))
    try expectEqual(BridgeTestClient.errorCode(denied), -32012, "config escalation denied")
    let revokeAttempt = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                                  port: port, method: "config",
                                                  params: .object(["clear_sessions": .bool(true)]))
    try expectEqual(BridgeTestClient.errorCode(revokeAttempt), -32012,
                    "RPC session revocation denied to clients")

    let approvals = SDKCounter()
    let fresh = ServerFixture(approval: { _ in
        approvals.increment()
        return .approve
    })
    let freshPort = try fresh.start()
    defer { fresh.stop() }
    let firstFresh = try BridgeTestClient.pairPlain(host: "127.0.0.1", port: freshPort,
                                                    name: "same-name")
    let secondFresh = try BridgeTestClient.pairPlain(host: "127.0.0.1", port: freshPort,
                                                     name: "same-name")
    try expectEqual(approvals.count(), 2, "every fresh pairing asks the owner")
    try expect(firstFresh.session.tokenID != secondFresh.session.tokenID,
               "each fresh pairing mints a new key")

    let logs = fixture.transportLog().joined(separator: "\n")
    try expect(!logs.contains(BridgeRPCEnvelope.hexLowercase(paired.session.key)),
               "raw key absent from transport logs")
    try expect(!logs.contains("unit-client"), "client name absent from transport logs")

    _ = fixture.authority.revoke(clientID: paired.session.tokenID)
    do {
        _ = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                      port: port, method: "config")
        throw TestFailure("revoked client still authenticated")
    } catch let error as TestFailure {
        try expectContains(error.message, "rpc transport 401", "revoked client receives 401")
    }
}

func pairDenyAndTimeoutCooldown() async throws {
    let fixture = ServerFixture(approval: { _ in .deny })
    let port = try fixture.start()
    defer { fixture.stop() }
    let body = BridgeRPCJSONValue.object([
        "client_name": .string("denied"),
        "plain": .bool(true),
    ]).canonicalData()
    let denied = try RawHTTP.request(host: "127.0.0.1", port: port, method: "POST",
                                     path: "/pair", body: body)
    try expectEqual(denied.status, 403, "deny status")
    try expectEqual(fixture.store.count(), 0, "deny stores no key")

    let timeoutLimits = BridgeRPCLimits(approvalTimeout: 0.25, pairCooldown: 0.3)
    let timeoutFixture = ServerFixture(limits: timeoutLimits, approval: { _ in
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        return .approve
    })
    let timeoutPort = try timeoutFixture.start()
    defer { timeoutFixture.stop() }
    let timedOut = try RawHTTP.request(host: "127.0.0.1", port: timeoutPort, method: "POST",
                                      path: "/pair", body: body)
    try expectEqual(timedOut.status, 403, "timeout denied")
    let cooled = try RawHTTP.request(host: "127.0.0.1", port: timeoutPort, method: "POST",
                                     path: "/pair", body: body)
    try expectEqual(cooled.status, 429, "cooldown after refusal")
    let cooledError = try BridgeRPCJSON.decode(cooled.body).objectValue?["error"]?.objectValue
    try expectEqual(cooledError?["code"]?.stringValue, "pair_cooldown", "cooldown code")
    try await Task.sleep(nanoseconds: 350_000_000)
    timeoutFixture.authority.setApprovalHandler { _ in .approve }
    let approved = try RawHTTP.request(host: "127.0.0.1", port: timeoutPort, method: "POST",
                                       path: "/pair", body: body)
    try expectEqual(approved.status, 200, "pairing works after cooldown")

    let noHandler = ServerFixture(approval: nil)
    let noHandlerPort = try noHandler.start()
    defer { noHandler.stop() }
    let failedCallback = try RawHTTP.request(host: "127.0.0.1", port: noHandlerPort,
                                             method: "POST", path: "/pair", body: body)
    try expectEqual(failedCallback.status, 403, "missing approval callback denies")
    let stillServing = try RawHTTP.request(host: "127.0.0.1", port: noHandlerPort,
                                           method: "GET", path: "/schema")
    try expectEqual(stillServing.status, 200, "denied callback leaves the service usable")
}

func pairSlotsIndependent() async throws {
    let gate = ApprovalGate()
    let limits = BridgeRPCLimits(approvalTimeout: 5, pairCooldown: 0.1)
    let authority = BridgeRPCAuthority(store: MemoryClientStore(), limits: limits,
                                       approvalHandler: gate.handler)
    let localPeer = BridgeRPCPeerInfo(address: "127.0.0.1", via: .local, isLoopback: true)
    let lanPeer = BridgeRPCPeerInfo(address: "192.168.1.20", via: .lan, isLoopback: false)

    async let localOutcome = authority.requestPairing(clientName: "local", peer: localPeer,
                                                      fingerprint: nil)
    async let lanOutcome = authority.requestPairing(clientName: "lan", peer: lanPeer,
                                                    fingerprint: nil)
    _ = await waitUntil(timeout: 3) { gate.pendingCount() == 2 }
    try expectEqual(gate.pendingCount(), 2, "local and LAN slots both pending")
    let busy = await authority.requestPairing(clientName: "third", peer: localPeer,
                                              fingerprint: nil)
    if case .busy = busy {
        // expected
    } else {
        throw TestFailure("third local pairing was not busy: \(busy)")
    }
    gate.finishAll(.approve)
    let local = await localOutcome
    let lan = await lanOutcome
    guard case .approved = local, case .approved = lan else {
        throw TestFailure("one of the independent pair slots was not approved")
    }
}

func x25519KnownClient() async throws {
    let fixture = ServerFixture()
    let port = try fixture.start()
    defer { fixture.stop() }
    guard let lan = lanIPv4Addresses().first else {
        throw TestFailure("environment has no normal-LAN IPv4 interface for X25519 test")
    }
    try fixture.server.setLANEnabled(true, bonjour: false)
    let paired = try BridgeTestClient.pairX25519(host: lan, port: port, name: "x25519-client")
    try expectEqual(fixture.store.count(), 1, "X25519 client stored")

    let config = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                           port: port, method: "config")
    try expect(BridgeTestClient.resultObject(config) != nil, "X25519 key opens RPC")

    let wrappedAgain = try BridgeTestClient.pairX25519(host: lan, port: port, name: "x25519-2")
    try expect(wrappedAgain.session.tokenID != paired.session.tokenID,
               "X25519 pairing mints a fresh client each time")
    if let lan6 = lanIPv6Addresses().first {
        let paired6 = try BridgeTestClient.pairX25519(host: lan6, port: port,
                                                      name: "x25519-ipv6")
        let config6 = try BridgeTestClient.call(session: paired6.session, host: "::1",
                                                port: port, method: "config")
        try expect(BridgeTestClient.resultObject(config6) != nil,
                   "IPv6 LAN X25519 key opens RPC")
    }

    let lanPeer = BridgeRPCPeerInfo(address: "192.168.1.20", via: .lan, isLoopback: false)
    let clientPrivate = Curve25519.KeyAgreement.PrivateKey()
    let clientPublic = clientPrivate.publicKey.rawRepresentation
    let pairBody = BridgeRPCJSONValue.object([
        "client_name": .string("lan-x25519"),
        "pub": .string(clientPublic.base64EncodedString()),
    ]).canonicalData()
    let pairRequest = BridgeRPCHTTPRequest(
        method: "POST", path: "/pair", pathOnly: "/pair", query: "",
        headers: [:], body: pairBody
    )
    let result = await fixture.service.handle(pairRequest, peer: lanPeer)
    guard case .response(let response) = result, response.status == 200,
          let pairObject = try BridgeRPCJSON.decode(response.body).objectValue,
          let devicePublicBase64 = pairObject["pub"]?.stringValue,
          let devicePublicData = Data(base64Encoded: devicePublicBase64),
          let tokenCiphertext = pairObject["token_ct"]?.stringValue.flatMap({
              BridgeRPCEnvelope.strictHex($0, byteCount: 32)
          }) else {
        throw TestFailure("synthetic LAN X25519 pairing failed")
    }
    let devicePublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: devicePublicData)
    let shared = try clientPrivate.sharedSecretFromKeyAgreement(with: devicePublic)
    let sharedData = shared.withUnsafeBytes { Data($0) }
    let lanKey = try expectNotNil(BridgeRPCEnvelope.unwrapKey(
        tokenCiphertext: tokenCiphertext,
        sharedSecret: sharedData,
        clientPublicKey: clientPublic,
        devicePublicKey: devicePublicData
    ), "LAN X25519 unwrap")
    let lanSession = RPCSession(key: lanKey,
                                tokenID: pairObject["tok"]?.stringValue ?? "",
                                clientName: "lan-x25519")
    let lanConfig = try BridgeTestClient.call(session: lanSession, host: "127.0.0.1",
                                              port: port, method: "config")
    try expect(BridgeTestClient.resultObject(lanConfig) != nil,
               "synthetic LAN X25519 key opens RPC")
}

func replaySkewFloodAndUnknownKey() throws {
    let fixture = ServerFixture()
    let port = try fixture.start()
    defer { fixture.stop() }
    let paired = try BridgeTestClient.pairPlain(host: "127.0.0.1", port: port, name: "replay")

    let nonce = BridgeRPCEnvelope.randomBytes(16)!
    let ts = Int(Date().timeIntervalSince1970)
    let request = BridgeRPCRequest(method: "config", params: .object([:]), id: .int(7))
    let envelope = BridgeRPCEnvelope.sealRequest(request.encodedData(), key: paired.session.key,
                                                 nonce: nonce, timestamp: ts)
    let first = try RawHTTP.request(host: "127.0.0.1", port: port, method: "POST",
                                    path: "/rpc", body: envelope.canonicalData())
    try expectEqual(first.status, 200, "first envelope accepted")
    let second = try RawHTTP.request(host: "127.0.0.1", port: port, method: "POST",
                                     path: "/rpc", body: envelope.canonicalData())
    try expectEqual(second.status, 401, "replay refused")
    let replayError = try BridgeRPCJSON.decode(second.body).objectValue?["error"]?.objectValue
    try expectEqual(replayError?["code"]?.stringValue, "nonce_replayed", "replay code")

    let skew = BridgeRPCEnvelope.sealRequest(request.encodedData(), key: paired.session.key,
                                             nonce: BridgeRPCEnvelope.randomBytes(16)!,
                                             timestamp: ts - 121)
    let skewResponse = try RawHTTP.request(host: "127.0.0.1", port: port, method: "POST",
                                           path: "/rpc", body: skew.canonicalData())
    try expectEqual(skewResponse.status, 401, "skew refused")
    let skewError = try BridgeRPCJSON.decode(skewResponse.body).objectValue?["error"]?.objectValue
    try expectEqual(skewError?["code"]?.stringValue, "ts_skew", "skew code")

    let unknownKey = BridgeRPCEnvelope.randomBytes(32)!
    let unknown = BridgeRPCEnvelope.sealRequest(request.encodedData(), key: unknownKey,
                                                 nonce: BridgeRPCEnvelope.randomBytes(16)!,
                                                 timestamp: ts)
    let unknownResponse = try RawHTTP.request(host: "127.0.0.1", port: port, method: "POST",
                                              path: "/rpc", body: unknown.canonicalData())
    try expectEqual(unknownResponse.status, 401, "unknown key refused")
    let unknownError = try BridgeRPCJSON.decode(unknownResponse.body).objectValue?["error"]?.objectValue
    try expectEqual(unknownError?["code"]?.stringValue, "auth_failed", "unknown key code")
    let revokedRequest = BridgeRPCEnvelope.sealRequest(
        request.encodedData(), key: paired.session.key,
        nonce: BridgeRPCEnvelope.randomBytes(16)!,
        timestamp: ts
    )
    _ = fixture.authority.revoke(clientID: paired.session.tokenID)
    let revokedResponse = try RawHTTP.request(host: "127.0.0.1", port: port, method: "POST",
                                              path: "/rpc", body: revokedRequest.canonicalData())
    let revokedError = try BridgeRPCJSON.decode(revokedResponse.body).objectValue?["error"]?.objectValue
    try expectEqual(revokedError?["code"]?.stringValue, "auth_failed", "revoked code")
    try expectEqual(unknownError?["message"]?.stringValue,
                    revokedError?["message"]?.stringValue ?? "", "unknown/expired wording differs")

    let floodLimits = BridgeRPCLimits(nonceCapacityPerClient: 2)
    let floodFixture = ServerFixture(limits: floodLimits)
    let floodPort = try floodFixture.start()
    defer { floodFixture.stop() }
    let floodPair = try BridgeTestClient.pairPlain(host: "127.0.0.1", port: floodPort,
                                                   name: "flood")
    for index in 0..<2 {
        _ = try BridgeTestClient.call(session: floodPair.session, host: "127.0.0.1",
                                      port: floodPort, method: "config", id: .int(index))
    }
    let floodRequest = BridgeRPCRequest(method: "config", params: .object([:]), id: .int(9))
    let floodEnvelope = BridgeRPCEnvelope.sealRequest(
        floodRequest.encodedData(),
        key: floodPair.session.key,
        nonce: BridgeRPCEnvelope.randomBytes(16)!,
        timestamp: Int(Date().timeIntervalSince1970)
    )
    let flooded = try RawHTTP.request(host: "127.0.0.1", port: floodPort, method: "POST",
                                      path: "/rpc", body: floodEnvelope.canonicalData())
    try expectEqual(flooded.status, 401, "nonce flood refused")
    let floodError = try BridgeRPCJSON.decode(flooded.body).objectValue?["error"]?.objectValue
    try expectEqual(floodError?["code"]?.stringValue, "nonce_flood", "nonce flood code")
}

func idleExpiryAndRevocation() async throws {
    let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let store = MemoryClientStore()
    let authority = BridgeRPCAuthority(store: store, limits: .default,
                                       approvalHandler: { _ in .approve },
                                       now: { clock.now() })
    let peer = BridgeRPCPeerInfo(address: "127.0.0.1", via: .local, isLoopback: true)
    let outcome = await authority.requestPairing(clientName: "idle", peer: peer, fingerprint: nil)
    guard case .approved(let grant) = outcome else { throw TestFailure("idle pair failed") }
    try expectEqual(store.count(), 1, "idle client stored")

    let request = BridgeRPCRequest(method: "config", params: .object([:]), id: .int(1))
    let envelope = BridgeRPCEnvelope.sealRequest(
        request.encodedData(), key: grant.key,
        nonce: BridgeRPCEnvelope.randomBytes(16)!,
        timestamp: Int(clock.now().timeIntervalSince1970)
    )
    let opened = try authority.openEnvelope(envelope, peer: peer)
    try expect(opened.isCurrent(), "fresh request current")
    clock.advance(31 * 24 * 60 * 60)
    let expiredEnvelope = BridgeRPCEnvelope.sealRequest(
        request.encodedData(), key: grant.key,
        nonce: BridgeRPCEnvelope.randomBytes(16)!,
        timestamp: Int(clock.now().timeIntervalSince1970)
    )
    do {
        _ = try authority.openEnvelope(expiredEnvelope, peer: peer)
        throw TestFailure("expired client still authenticated")
    } catch let failure as BridgeRPCEnvelope.Failure {
        try expectEqual(failure.code, "auth_failed", "expired auth code")
    }
    try expectEqual(authority.clientMetadata().count, 0, "expired client absent from metadata")
    try expectEqual(authority.pruneExpired(), 1, "expired client pruned")
    try expectEqual(store.count(), 0, "expired client removed from secure storage")
}

final class SDKCounter: @unchecked Sendable {
    private let lock = BridgeRPCLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    func count() -> Int { lock.withLock { value } }
}

func nonceDurabilityAndFailClosed() async throws {
    let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let store = MemoryClientStore()
    let limits = BridgeRPCLimits(approvalTimeout: 1, pairCooldown: 0.1)
    let authority = BridgeRPCAuthority(store: store, limits: limits,
                                       approvalHandler: { _ in .approve },
                                       now: { clock.now() })
    let peer = BridgeRPCPeerInfo(address: "127.0.0.1", via: .local, isLoopback: true)
    let outcome = await authority.requestPairing(clientName: "nonce", peer: peer, fingerprint: nil)
    guard case .approved(let grant) = outcome else { throw TestFailure("nonce pair failed") }
    let request = BridgeRPCRequest(method: "config", params: .object([:]), id: .int(1))
    let nonce = BridgeRPCEnvelope.randomBytes(16)!
    let envelope = BridgeRPCEnvelope.sealRequest(
        request.encodedData(), key: grant.key, nonce: nonce,
        timestamp: Int(clock.now().timeIntervalSince1970)
    )
    _ = try authority.openEnvelope(envelope, peer: peer)
    try expectEqual(store.nonceCount(), 1, "nonce persisted before acceptance")

    let reloaded = BridgeRPCAuthority(store: store, limits: limits,
                                      approvalHandler: { _ in .deny },
                                      now: { clock.now() })
    do {
        _ = try reloaded.openEnvelope(envelope, peer: peer)
        throw TestFailure("replayed ciphertext was accepted after reload")
    } catch let failure as BridgeRPCEnvelope.Failure {
        try expectEqual(failure.code, "nonce_replayed", "reload replay code")
    }

    let failingStore = MemoryClientStore()
    let failingAuthority = BridgeRPCAuthority(store: failingStore, limits: limits,
                                              approvalHandler: { _ in .approve },
                                              now: { clock.now() })
    let failingOutcome = await failingAuthority.requestPairing(
        clientName: "failing", peer: peer, fingerprint: nil
    )
    guard case .approved(let failingGrant) = failingOutcome else {
        throw TestFailure("failing-store pair failed")
    }
    let secondEnvelope = BridgeRPCEnvelope.sealRequest(
        request.encodedData(), key: failingGrant.key,
        nonce: BridgeRPCEnvelope.randomBytes(16)!,
        timestamp: Int(clock.now().timeIntervalSince1970)
    )
    failingStore.failSaveNonces = true
    do {
        _ = try failingAuthority.openEnvelope(secondEnvelope, peer: peer)
        throw TestFailure("request was accepted when the nonce could not be persisted")
    } catch let failure as BridgeRPCEnvelope.Failure {
        try expectEqual(failure.code, "auth_unavailable", "nonce persistence fail-closed")
    }
    try expectEqual(failingAuthority.clientMetadata().count, 1, "client remains but request refused")
    failingStore.failSaveNonces = false
    let recovered = BridgeRPCAuthority(store: failingStore, limits: limits,
                                       approvalHandler: { _ in .deny },
                                       now: { clock.now() })
    _ = try recovered.openEnvelope(secondEnvelope, peer: peer)
    try expectEqual(failingStore.nonceCount(), 1, "recovered request persisted its nonce")

    let unreadableStore = MemoryClientStore()
    unreadableStore.failLoadNonces = true
    let unreadable = BridgeRPCAuthority(store: unreadableStore, limits: limits,
                                       approvalHandler: { _ in .approve },
                                       now: { clock.now() })
    let unreadableOutcome = await unreadable.requestPairing(
        clientName: "unreadable", peer: peer, fingerprint: nil
    )
    guard case .approved(let unreadableGrant) = unreadableOutcome else {
        throw TestFailure("unreadable-nonce pair failed")
    }
    let unreadableEnvelope = BridgeRPCEnvelope.sealRequest(
        request.encodedData(), key: unreadableGrant.key,
        nonce: BridgeRPCEnvelope.randomBytes(16)!,
        timestamp: Int(clock.now().timeIntervalSince1970)
    )
    do {
        _ = try unreadable.openEnvelope(unreadableEnvelope, peer: peer)
        throw TestFailure("request was accepted with an unreadable nonce store")
    } catch let failure as BridgeRPCEnvelope.Failure {
        try expectEqual(failure.code, "auth_unavailable",
                        "unreadable nonce store fails closed")
    }
}

func durableAuthorizationAndRevocation() async throws {
    let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let store = MemoryClientStore()
    let limits = BridgeRPCLimits(approvalTimeout: 1, pairCooldown: 0.1)
    let authority = BridgeRPCAuthority(store: store, limits: limits,
                                       approvalHandler: { _ in .approve },
                                       now: { clock.now() })
    let peer = BridgeRPCPeerInfo(address: "127.0.0.1", via: .local, isLoopback: true)
    let outcome = await authority.requestPairing(clientName: "durable", peer: peer, fingerprint: nil)
    guard case .approved(let grant) = outcome else { throw TestFailure("durable pair failed") }
    let request = BridgeRPCRequest(method: "config", params: .object([:]), id: .int(1))
    func envelope(_ key: Data) -> BridgeRPCJSONValue {
        BridgeRPCEnvelope.sealRequest(
            request.encodedData(), key: key,
            nonce: BridgeRPCEnvelope.randomBytes(16)!,
            timestamp: Int(clock.now().timeIntervalSince1970)
        )
    }

    store.failUpsert = true
    try expect(!authority.setSensitiveInput(clientID: grant.clientID, granted: true),
               "grant fails when the durable write fails")
    try expect(!authority.sensitiveInputGranted(clientID: grant.clientID),
               "failed grant is not visible")
    store.failUpsert = false
    try expect(authority.setSensitiveInput(clientID: grant.clientID, granted: true),
               "grant succeeds after storage recovers")
    let reloaded = BridgeRPCAuthority(store: store, limits: limits,
                                      approvalHandler: { _ in .deny },
                                      now: { clock.now() })
    try expect(reloaded.sensitiveInputGranted(clientID: grant.clientID),
               "grant is durable across reload")

    store.failRemove = true
    try expect(!authority.revoke(clientID: grant.clientID), "revoke reports storage failure")
    _ = try authority.openEnvelope(envelope(grant.key), peer: peer)
    try expectEqual(store.count(), 1, "failed revoke did not remove the key")
    store.failRemove = false
    try expect(authority.revoke(clientID: grant.clientID), "revoke succeeds after storage recovers")
    try expectEqual(store.count(), 0, "successful revoke removed the key")
    do {
        _ = try authority.openEnvelope(envelope(grant.key), peer: peer)
        throw TestFailure("revoked client still authenticated")
    } catch let failure as BridgeRPCEnvelope.Failure {
        try expectEqual(failure.code, "auth_failed", "revoked auth code")
    }

    let secondOutcome = await authority.requestPairing(clientName: "all", peer: peer, fingerprint: nil)
    guard case .approved = secondOutcome else { throw TestFailure("second pair failed") }
    store.failRemoveAll = true
    try expect(!authority.revokeAll(), "revokeAll reports storage failure")
    try expectEqual(store.count(), 1, "failed revokeAll retained the key")
    store.failRemoveAll = false
    try expect(authority.revokeAll(), "revokeAll succeeds after storage recovers")
    try expectEqual(store.count(), 0, "revokeAll removed every key")

    // A concurrent grant holds the authority lock across its durable write.
    // Revoke must wait and win afterwards; the older upsert cannot resurrect it.
    let thirdOutcome = await authority.requestPairing(clientName: "race", peer: peer, fingerprint: nil)
    guard case .approved(let third) = thirdOutcome else { throw TestFailure("race pair failed") }
    let entered = DispatchSemaphore(value: 0)
    let block = DispatchSemaphore(value: 0)
    store.upsertEntered = entered
    store.upsertBlock = block
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        _ = authority.setSensitiveInput(clientID: third.clientID, granted: true)
        group.leave()
    }
    _ = waitSemaphore(entered, timeout: 2)
    group.enter()
    DispatchQueue.global().async {
        _ = authority.revoke(clientID: third.clientID)
        group.leave()
    }
    blockingSleep(0.1)
    block.signal()
    _ = waitGroup(group, timeout: 5)
    store.upsertEntered = nil
    store.upsertBlock = nil
    try expectEqual(authority.clientMetadata().count, 0, "revoke won the grant/revoke race")
    try expectEqual(store.count(), 0, "late grant upsert did not resurrect the revoked key")
    let afterRace = BridgeRPCAuthority(store: store, limits: limits,
                                       approvalHandler: { _ in .deny },
                                       now: { clock.now() })
    try expectEqual(afterRace.clientMetadata().count, 0, "reload sees no resurrected key")
}

func coordinatorTimeoutBeforeDispatch() async throws {
    let limits = BridgeRPCLimits(maxQueuedAutomationCalls: 4, executionTimeout: 0.15)
    let coordinator = BridgeRPCExecutionCoordinator(limits: limits)
    let gate = AsyncGate()
    let sdk = SDKCounter()
    let executor = FakeExecutor(readiness: .ready(generation: 1),
                                supportedMethods: ["device_info"],
                                autoAuthorize: false) { _, permit in
        await gate.wait()
        guard permit.authorizeDispatch() else { return .failure(.fenced) }
        sdk.increment()
        return .success(.object(["ok": .bool(true)]))
    }
    let fence = BridgeRPCExecutionFence(clientID: "c", authEpoch: 1, clientRevision: 1,
                                        engineGeneration: 1, serviceEpoch: 1)
    let firstInvocation = BridgeRPCInvocation(operationID: "slow-1", clientID: "c",
                                              method: "device_info", params: .object([:]),
                                              sensitiveInputGranted: false, receivedAt: Date())
    let firstTask = Task {
        await coordinator.submit(invocation: firstInvocation, paramsDigest: "s1",
                                 executor: executor, fence: fence, isCurrent: { true })
    }
    _ = await waitUntil(timeout: 1) { executor.count() == 1 }
    let first = await firstTask.value
    if case .failure(let error) = first.outcome {
        try expectEqual(error.code, -32017, "pre-dispatch timeout is not an unknown effect")
    } else {
        throw TestFailure("pre-dispatch timeout did not fail: \(first.outcome)")
    }
    try expect(!first.dispatched, "timed-out request never reached SDK")

    let secondInvocation = BridgeRPCInvocation(operationID: "slow-2", clientID: "c",
                                               method: "device_info", params: .object([:]),
                                               sensitiveInputGranted: false, receivedAt: Date())
    let secondTask = Task {
        await coordinator.submit(invocation: secondInvocation, paramsDigest: "s2",
                                 executor: executor, fence: fence, isCurrent: { true })
    }
    try await Task.sleep(nanoseconds: 120_000_000)
    try expectEqual(await coordinator.queuedCount(), 1,
                    "second request waits behind the still-running first operation")
    try expectEqual(executor.count(), 1, "second operation did not enter the executor")
    try expectEqual(sdk.count(), 0, "no SDK dispatch before the gate opens")
    gate.releaseAll()
    let second = await secondTask.value
    if case .success = second.outcome {} else {
        throw TestFailure("second operation did not complete after slot release: \(second.outcome)")
    }
    try expectEqual(sdk.count(), 1, "only the authorized second operation touched the SDK")
    try expectEqual(executor.count(), 2, "executor entries are serialized")
}

// A collect/scroll/input operation can contain several SDK steps. Finishing an
// entered step is permitted, but Stop, expiry or revocation must fence the next.
func cooperativeStagesFenced() async throws {
    for mode in ["timeout", "stop", "revoke"] {
        let coordinator = BridgeRPCExecutionCoordinator(limits: BridgeRPCLimits(
            executionTimeout: mode == "timeout" ? 0.15 : 5
        ))
        let gate = AsyncGate()
        let sdk = SDKCounter()
        let completed = SDKCounter()
        let revoked = SDKCounter()
        let executor = FakeExecutor(readiness: .ready(generation: 1),
                                    supportedMethods: ["collect"],
                                    autoAuthorize: false) { _, permit in
            defer { completed.increment() }
            guard permit.authorizeDispatch() else { return .failure(.fenced) }
            sdk.increment()
            await gate.wait()
            guard permit.canContinueExecution, permit.authorizeDispatch() else {
                return .sideEffectUnknown(code: "cancelled", message: "Remaining steps cancelled.")
            }
            sdk.increment()
            return .success(.object(["ok": .bool(true)]))
        }
        let invocation = BridgeRPCInvocation(operationID: "stages-" + mode, clientID: "c",
                                               method: "collect", params: .object([:]),
                                               sensitiveInputGranted: false, receivedAt: Date())
        let fence = BridgeRPCExecutionFence(clientID: "c", authEpoch: 1, clientRevision: 1,
                                            engineGeneration: 1, serviceEpoch: 1)
        let operation = Task {
            await coordinator.submit(invocation: invocation, paramsDigest: mode,
                                     executor: executor, fence: fence,
                                     isCurrent: { revoked.count() == 0 })
        }
        let entered = await waitUntil(timeout: 1) { sdk.count() == 1 }
        guard entered else {
            gate.releaseAll()
            _ = await operation.value
            throw TestFailure("\(mode): first SDK step never entered")
        }
        if mode == "timeout" { _ = await operation.value }
        if mode == "stop" { await coordinator.cancelQueued() }
        if mode == "revoke" { revoked.increment() }
        gate.releaseAll()
        let result = await operation.value
        let finished = await waitUntil(timeout: 1) { completed.count() == 1 }
        try expect(finished, "\(mode): actual executor finished before releasing its lifetime")
        try expectEqual(sdk.count(), 1, "\(mode): second SDK step was fenced")
        try expect(result.dispatched, "\(mode): first effect remains acknowledged")
        if case .success = result.outcome {
            throw TestFailure("\(mode): cancelled multi-step operation reported success")
        }
    }
}

func commitGateHeldResponseAndPartialStop() async throws {
    let fixture = ServerFixture()
    let port = try fixture.start()
    let executor = FakeExecutor(readiness: .ready(generation: 1),
                                supportedMethods: ["device_info"]) { _ in
        .success(.object(["data": .string(String(repeating: "A", count: 1_000_000))]))
    }
    let registration = fixture.registry.register(owner: "commit", executor: executor)
    guard case .registered(let generation) = registration else { throw TestFailure("commit engine") }
    executor.setReadiness(.ready(generation: generation))
    let paired = try BridgeTestClient.pairPlain(host: "127.0.0.1", port: port, name: "commit")

    // Direct final-commit token: revoke between seal and send must suppress the
    // first byte entirely.
    let request = BridgeRPCRequest(method: "config", params: .object([:]), id: .int(11))
    let envelope = BridgeRPCEnvelope.sealRequest(
        request.encodedData(), key: paired.session.key,
        nonce: BridgeRPCEnvelope.randomBytes(16)!,
        timestamp: Int(Date().timeIntervalSince1970)
    )
    let httpRequest = BridgeRPCHTTPRequest(
        method: "POST", path: "/rpc", pathOnly: "/rpc", query: "",
        headers: [:], body: envelope.canonicalData()
    )
    let direct = await fixture.service.handle(
        httpRequest,
        peer: BridgeRPCPeerInfo(address: "127.0.0.1", via: .local, isLoopback: true)
    )
    guard case .response(let sealedResponse) = direct,
          let token = sealedResponse.commitToken else {
        throw TestFailure("sealed response had no commit token")
    }
    _ = fixture.authority.revoke(clientID: paired.session.tokenID)
    var sent = false
    let committed = fixture.service.commitResponse(token) {
        sent = true
        return true
    }
    try expect(!committed, "revoked token cannot commit")
    try expect(!sent, "revoked response sent no first byte")

    // Held-response/revoke over a real socket: the request has been sealed but
    // the first byte is held behind the deterministic seam. Revocation closes
    // the tagged socket, so the client receives no response.
    let second = try BridgeTestClient.pairPlain(host: "127.0.0.1", port: port, name: "held")
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    fixture.server.setBeforeResponseCommitHandler {
        entered.signal()
        release.wait()
    }
    let heldTask = Task { () -> RawHTTPResponse? in
        let rpc = BridgeRPCRequest(method: "device_info", params: .object([:]), id: .int(12))
        let requestEnvelope = BridgeRPCEnvelope.sealRequest(
            rpc.encodedData(), key: second.session.key,
            nonce: BridgeRPCEnvelope.randomBytes(16)!,
            timestamp: Int(Date().timeIntervalSince1970)
        )
        return try? RawHTTP.request(host: "127.0.0.1", port: port, method: "POST",
                                    path: "/rpc", body: requestEnvelope.canonicalData())
    }
    _ = waitSemaphore(entered, timeout: 3)
    _ = fixture.authority.revoke(clientID: second.session.tokenID)
    release.signal()
    let held = await heldTask.value
    fixture.server.setBeforeResponseCommitHandler(nil)
    try expect(held == nil, "held response was not delivered after revocation")

    // Partial-write/stop: the first header byte is committed, then Stop closes
    // the socket before the rest of the large body can be written.
    let third = try BridgeTestClient.pairPlain(host: "127.0.0.1", port: port, name: "partial")
    let afterFirst = DispatchSemaphore(value: 0)
    let releasePartial = DispatchSemaphore(value: 0)
    fixture.server.setAfterFirstByteCommitHandler {
        afterFirst.signal()
        releasePartial.wait()
    }
    let partialTask = Task { () -> RawHTTPResponse? in
        let rpc = BridgeRPCRequest(method: "device_info", params: .object([:]), id: .int(13))
        let requestEnvelope = BridgeRPCEnvelope.sealRequest(
            rpc.encodedData(), key: third.session.key,
            nonce: BridgeRPCEnvelope.randomBytes(16)!,
            timestamp: Int(Date().timeIntervalSince1970)
        )
        return try? RawHTTP.request(host: "127.0.0.1", port: port, method: "POST",
                                    path: "/rpc", body: requestEnvelope.canonicalData())
    }
    _ = waitSemaphore(afterFirst, timeout: 3)
    fixture.stop()
    releasePartial.signal()
    let partial = await partialTask.value
    fixture.server.setAfterFirstByteCommitHandler(nil)
    if let partial {
        try expect(partial.raw.count < 1_024, "stop left only a partial response")
    }
    fixture.stop()
}

// MARK: - Logs / streams

func logsAndStreamTickets() async throws {
    let stream = TestStreamSource(contentType: "text/plain")
    let fixture = ServerFixture(logs: TestLogs(), streamSource: stream)
    let port = try fixture.start()
    defer { fixture.stop() }
    let paired = try BridgeTestClient.pairPlain(host: "127.0.0.1", port: port, name: "logs")
    let ticketResult = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                                 port: port, method: "stream_ticket")
    let ticketObject = try expectNotNil(BridgeTestClient.resultObject(ticketResult), "ticket result")
    let ticket = try expectNotNil(ticketObject["ticket"]?.stringValue, "ticket")
    try expect((ticketObject["expires_in"]?.intValue ?? 0) > 0, "ticket expiry")

    let logs = try RawHTTP.request(host: "127.0.0.1", port: port, method: "GET",
                                   path: "/logs?ticket=\(ticket)")
    try expectEqual(logs.status, 200, "logs with ticket")
    try expectContains(String(decoding: logs.body, as: UTF8.self), "log line one", "log content")
    let reused = try RawHTTP.request(host: "127.0.0.1", port: port, method: "GET",
                                     path: "/logs?ticket=\(ticket)")
    try expectEqual(reused.status, 401, "ticket single use")

    let noTicket = try RawHTTP.request(host: "127.0.0.1", port: port, method: "GET", path: "/logs")
    try expectEqual(noTicket.status, 401, "logs require ticket")

    let filesTicket = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                                port: port, method: "stream_ticket")
    let filesKey = try expectNotNil(BridgeTestClient.resultObject(filesTicket)?["ticket"]?.stringValue,
                                    "files ticket")
    let files = try RawHTTP.request(host: "127.0.0.1", port: port, method: "GET",
                                    path: "/logs/files?ticket=\(filesKey)")
    try expectEqual(files.status, 200, "log files")
    let history = try RawHTTP.request(host: "127.0.0.1", port: port, method: "GET",
                                      path: "/logs/history?date=2026-11-01&ticket=\(filesKey)")
    try expectEqual(history.status, 401, "single-use ticket already consumed")
    let newTicket = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                              port: port, method: "stream_ticket")
    let newKey = try expectNotNil(BridgeTestClient.resultObject(newTicket)?["ticket"]?.stringValue,
                                  "history ticket")
    let historyOk = try RawHTTP.request(host: "127.0.0.1", port: port, method: "GET",
                                        path: "/logs/history?date=2026-11-01&ticket=\(newKey)")
    try expectEqual(historyOk.status, 200, "log history")
    let badDate = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                            port: port, method: "stream_ticket")
    let badKey = try expectNotNil(BridgeTestClient.resultObject(badDate)?["ticket"]?.stringValue,
                                  "bad date ticket")
    let bad = try RawHTTP.request(host: "127.0.0.1", port: port, method: "GET",
                                  path: "/logs/history?date=11-01-2026&ticket=\(badKey)")
    try expectEqual(bad.status, 400, "bad date rejected")
}

func streamUnavailableAndRevocation() async throws {
    let noStream = ServerFixture(streamSource: nil)
    let noPort = try noStream.start()
    defer { noStream.stop() }
    let paired = try BridgeTestClient.pairPlain(host: "127.0.0.1", port: noPort, name: "nostream")
    let ticketError = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                                port: noPort, method: "stream_ticket")
    try expectEqual(BridgeTestClient.errorCode(ticketError), -32011,
                    "stream_ticket unavailable without source")
    let stream = try RawHTTP.request(host: "127.0.0.1", port: noPort, method: "GET", path: "/stream")
    try expectEqual(stream.status, 503, "stream unavailable")
    let streamError = try BridgeRPCJSON.decode(stream.body).objectValue?["error"]?.objectValue
    try expectEqual(streamError?["code"]?.stringValue, "stream_unavailable", "stream code")

    let source = TestStreamSource(contentType: "text/plain")
    let fixture = ServerFixture(streamSource: source)
    let port = try fixture.start()
    defer { fixture.stop() }
    let client = try BridgeTestClient.pairPlain(host: "127.0.0.1", port: port, name: "streamer")
    let ticketCall = try BridgeTestClient.call(session: client.session, host: "127.0.0.1",
                                               port: port, method: "stream_ticket")
    let ticket = try expectNotNil(BridgeTestClient.resultObject(ticketCall)?["ticket"]?.stringValue,
                                  "stream ticket")
    let task = Task { () -> RawHTTPResponse? in
        try? RawHTTP.request(host: "127.0.0.1", port: port, method: "GET",
                             path: "/stream?ticket=\(ticket)")
    }
    let opened = await waitUntil(timeout: 3) { source.opens == 1 }
    try expect(opened, "stream source opened")
    try await Task.sleep(nanoseconds: 150_000_000)
    _ = fixture.authority.revoke(clientID: client.session.tokenID)
    let response = await task.value
    let streamResponse = try expectNotNil(response, "stream response")
    try expectEqual(streamResponse.status, 200, "stream status")
    try expectEqual(streamResponse.headers["x-bridge-stream"], "1", "stream marker")
    try expectContains(String(decoding: streamResponse.body, as: UTF8.self), "first-frame",
                       "stream body")

    let revokedTicketCall = try BridgeTestClient.pairPlain(host: "127.0.0.1", port: port,
                                                           name: "streamer2")
    let newTicket = try BridgeTestClient.call(session: revokedTicketCall.session,
                                              host: "127.0.0.1", port: port,
                                              method: "stream_ticket")
    let ticketValue = try expectNotNil(BridgeTestClient.resultObject(newTicket)?["ticket"]?.stringValue,
                                       "revocation ticket")
    _ = fixture.authority.revoke(clientID: revokedTicketCall.session.tokenID)
    let afterRevoke = try RawHTTP.request(host: "127.0.0.1", port: port, method: "GET",
                                          path: "/stream?ticket=\(ticketValue)")
    try expectEqual(afterRevoke.status, 401, "ticket revoked with client")
}

func streamBufferBound() async throws {
    let channel = BridgeRPCStreamChannel(bufferBytes: 8)
    try expect(channel.yield(Data(repeating: 1, count: 6)), "first chunk fits")
    try expect(!channel.yield(Data(repeating: 2, count: 6)), "second chunk exceeds buffer")
    var iterator = channel.sequence.makeAsyncIterator()
    let first = await iterator.next()
    try expectEqual(first?.count, 6, "first chunk delivered")
    try expect(channel.yield(Data(repeating: 3, count: 6)), "space available after consumption")
    let second = await iterator.next()
    try expectEqual(second?.count, 6, "second chunk delivered after consumption")
    channel.finish()
    let end = await iterator.next()
    try expect(end == nil, "stream finished")
}

// MARK: - Engine

func engineReadinessAndSensitiveInput() async throws {
    let fixture = ServerFixture()
    let port = try fixture.start()
    defer { fixture.stop() }
    let executor = FakeExecutor(readiness: .notReady(reason: "warming"),
                                supportedMethods: ["device_info", "type", "screenshot"]) { invocation in
        let secure = invocation.params.objectValue?["secure"]?.boolValue ?? false
        if secure && !invocation.sensitiveInputGranted {
            return .failure(.permissionDenied)
        }
        return .success(.object(["method": .string(invocation.method),
                                 "sensitive": .bool(invocation.sensitiveInputGranted)]))
    }
    let registration = fixture.registry.register(owner: "test-engine", executor: executor)
    guard case .registered(let generation) = registration else {
        throw TestFailure("engine registration failed: \(registration)")
    }
    try expect(generation > 0, "engine generation")
    let paired = try BridgeTestClient.pairPlain(host: "127.0.0.1", port: port, name: "engine")

    let warming = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                            port: port, method: "device_info")
    try expectEqual(BridgeTestClient.errorCode(warming), -32010, "warming not ready")
    executor.setReadiness(.ready(generation: generation))
    let info = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                         port: port, method: "device_info")
    try expectEqual(BridgeTestClient.resultObject(info)?["method"]?.stringValue, "device_info",
                    "engine result")
    let schemaResponse = try RawHTTP.request(host: "127.0.0.1", port: port, method: "GET",
                                             path: "/schema")
    let schema = try BridgeRPCJSON.decode(schemaResponse.body).objectValue!
    let advertised = schema["capability_tags"]?.arrayValue?.compactMap(\.stringValue) ?? []
    try expect(advertised.contains("device_info"), "registered method advertised")
    try expect(advertised.contains("type"), "ordinary input capability advertised")
    try expect(!advertised.contains("page_source"), "unregistered method not advertised")
    let unavailable = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                                port: port, method: "page_source")
    try expectEqual(BridgeTestClient.errorCode(unavailable), -32011, "method not available")
    let unknownMethod = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                                  port: port, method: "not_a_bridge_method")
    try expectEqual(BridgeTestClient.errorCode(unknownMethod), -32601,
                    "unknown method is JSON-RPC method not found")
    let reset = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                          port: port, method: "reset")
    try expectEqual(BridgeTestClient.errorCode(reset), -32011,
                    "reset does not bootstrap an unregistered method")
    try expectEqual(fixture.registry.registrationCount, 1,
                    "reset did not register another engine")
    // Ordinary input is available by default; the service must not treat every
    // type/clear_text as a password entry.
    let ordinary = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                             port: port, method: "type",
                                             params: .object(["text": .string("ordinary")]))
    try expectEqual(BridgeTestClient.resultObject(ordinary)?["sensitive"]?.boolValue, false,
                    "ordinary type dispatches without a secure-field grant")
    let secureDenied = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                                 port: port, method: "type",
                                                 params: .object(["text": .string("secret"),
                                                                  "secure": .bool(true)]))
    try expectEqual(BridgeTestClient.errorCode(secureDenied), -32012,
                    "executor refuses third-party secure field without grant")
    _ = fixture.authority.setSensitiveInput(clientID: paired.session.tokenID, granted: true)
    let secureAllowed = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                                  port: port, method: "type",
                                                  params: .object(["text": .string("secret"),
                                                                   "secure": .bool(true)]))
    try expectEqual(BridgeTestClient.resultObject(secureAllowed)?["sensitive"]?.boolValue, true,
                    "owner grant reaches executor for a secure field")

    let second = try BridgeTestClient.pairPlain(host: "127.0.0.1", port: port, name: "engine2")
    let selfGrant = try BridgeTestClient.call(session: second.session, host: "127.0.0.1",
                                              port: port, method: "type",
                                              params: .object(["text": .string("x"),
                                                               "secure": .bool(true),
                                                               "sensitive_input_granted": .bool(true),
                                                               "sensitive_input": .bool(true)]))
    try expectEqual(BridgeTestClient.errorCode(selfGrant), -32012,
                    "payload cannot self-grant a secure-field permission")
    let selfGrantOrdinary = try BridgeTestClient.call(session: second.session, host: "127.0.0.1",
                                                      port: port, method: "type",
                                                      params: .object(["text": .string("x"),
                                                                       "sensitive_input_granted": .bool(true)]))
    try expectEqual(BridgeTestClient.resultObject(selfGrantOrdinary)?["sensitive"]?.boolValue, false,
                    "payload flag is ignored for ordinary input")
}

func engineSurvivesStopAndRegistersOnce() async throws {
    let service = BridgeRPCHostService(
        configuration: .init(requestedPort: 0),
        store: MemoryClientStore(),
        resources: TestResources(),
        logs: TestLogs(),
        registry: BridgeRPCEngineRegistry()
    )
    let executor = FakeExecutor(readiness: .ready(generation: 1),
                                supportedMethods: ["device_info"]) { _ in
        .success(.object(["ok": .bool(true)]))
    }
    service.setApprovalHandler { _ in .approve }
    let registration = service.engineRegistry.register(owner: "app-engine", executor: executor)
    guard case .registered(let generation) = registration else {
        throw TestFailure("host engine registration failed: \(registration)")
    }
    try expectEqual(service.engineRegistry.registrationCount, 1, "one registration")
    try service.start()
    defer { service.stop() }
    try expect(service.snapshot().loopbackReady, "loopback ready")
    try expect(service.snapshot().isReady, "listeners and engine ready")
    guard let port = service.snapshot().port else { throw TestFailure("host has no port") }
    let paired = try BridgeTestClient.pairPlain(host: "127.0.0.1", port: port, name: "host")
    try expectEqual(service.snapshot().clients.count, 1, "owner snapshot lists the paired client")
    try expect(service.grantSensitiveInput(clientID: paired.session.tokenID, granted: true),
               "owner snapshot grant succeeds")
    try expectEqual(service.snapshot().clients.first?.sensitiveInputGranted, true,
                    "owner snapshot reflects the grant")
    let info = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                         port: port, method: "device_info")
    try expect(BridgeTestClient.resultObject(info) != nil, "engine call before stop")
    service.stop()
    try expect(!service.snapshot().isReady, "not ready after stop")
    try expect(service.engineRegistry.snapshot().readiness.isReady, "engine survives service stop")
    try expectEqual(service.engineRegistry.snapshot().generation ?? 0, generation,
                    "engine generation unchanged")
    let again = service.engineRegistry.register(owner: "app-engine", executor: executor)
    guard case .alreadyRegistered(let sameGeneration) = again else {
        throw TestFailure("same-owner registration was not idempotent: \(again)")
    }
    try expectEqual(sameGeneration, generation, "register once is idempotent")
    let other = FakeExecutor(readiness: .ready(generation: 99),
                             supportedMethods: ["device_info"]) { _ in
        .failure(.serverError("must not be used"))
    }
    let rejected = service.engineRegistry.register(owner: "other-engine", executor: other)
    guard case .rejected = rejected else {
        throw TestFailure("a second engine owner was accepted: \(rejected)")
    }
    try expectEqual(service.engineRegistry.snapshot().generation ?? 0, generation,
                    "rejected registration did not bump generation")
    try expectEqual(service.engineRegistry.snapshot().owner, "app-engine",
                    "rejected registration did not replace the engine")
    try expectEqual(service.engineRegistry.registrationCount, 1, "no double bootstrap")
    try service.start()
    guard let secondPort = service.snapshot().port else { throw TestFailure("no restart port") }
    let info2 = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                          port: secondPort, method: "device_info")
    try expect(BridgeTestClient.resultObject(info2) != nil, "engine call after restart")
    try expect(service.revoke(clientID: paired.session.tokenID), "owner revoke succeeds")
    try expectEqual(service.snapshot().clients.count, 0, "owner snapshot drops the revoked client")
}

func operationExactlyOnceAndUnknown() async throws {
    let limits = BridgeRPCLimits(maxQueuedAutomationCalls: 4, executionTimeout: 2)
    let coordinator = BridgeRPCExecutionCoordinator(limits: limits)
    let executor = FakeExecutor(readiness: .ready(generation: 1),
                                supportedMethods: ["device_info"]) { invocation in
        .success(.object(["count": .int(1), "operation": .string(invocation.operationID)]))
    }
    let fence = BridgeRPCExecutionFence(clientID: "c", authEpoch: 1, clientRevision: 1,
                                        engineGeneration: 1, serviceEpoch: 1)
    let invocation = BridgeRPCInvocation(operationID: "op-1", clientID: "c",
                                         method: "device_info", params: .object([:]),
                                         sensitiveInputGranted: false, receivedAt: Date())
    let first = await coordinator.submit(invocation: invocation, paramsDigest: "d1",
                                         executor: executor, fence: fence,
                                         isCurrent: { true })
    let second = await coordinator.submit(invocation: invocation, paramsDigest: "d1",
                                          executor: executor, fence: fence,
                                          isCurrent: { true })
    try expectEqual(executor.count(), 1, "duplicate operation not re-executed")
    try expect(second.duplicate, "duplicate flagged")
    try expectEqual(first.outcome, second.outcome, "duplicate result matches")
    let conflict = await coordinator.submit(invocation: invocation, paramsDigest: "different",
                                            executor: executor, fence: fence,
                                            isCurrent: { true })
    if case .failure(let error) = conflict.outcome {
        try expectEqual(error.code, -32015, "operation id conflict")
    } else {
        throw TestFailure("operation id conflict did not fail")
    }

    let unknownExecutor = FakeExecutor(readiness: .ready(generation: 1),
                                       supportedMethods: ["device_info"]) { _ in
        .sideEffectUnknown(code: "unknown_effect", message: "may have happened")
    }
    let unknownInvocation = BridgeRPCInvocation(operationID: "op-unknown", clientID: "c",
                                                method: "device_info", params: .object([:]),
                                                sensitiveInputGranted: false, receivedAt: Date())
    _ = await coordinator.submit(invocation: unknownInvocation, paramsDigest: "u",
                                 executor: unknownExecutor, fence: fence,
                                 isCurrent: { true })
    let retry = await coordinator.submit(invocation: unknownInvocation, paramsDigest: "u",
                                         executor: unknownExecutor, fence: fence,
                                         isCurrent: { true })
    try expectEqual(unknownExecutor.count(), 1, "unknown effect not replayed")
    if case .failure(let error) = retry.outcome {
        try expectEqual(error.code, -32013, "unknown outcome on retry")
    } else {
        throw TestFailure("unknown retry did not fail")
    }
}

final class AsyncGate: @unchecked Sendable {
    private let lock = BridgeRPCLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var open = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if open { continuation.resume() } else { continuations.append(continuation) }
            }
        }
    }

    func releaseAll() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            open = true
            let values = continuations
            continuations.removeAll()
            return values
        }
        for continuation in waiting { continuation.resume() }
    }
}

func queueBoundAndCancel() async throws {
    let limits = BridgeRPCLimits(maxQueuedAutomationCalls: 2, executionTimeout: 5)
    let coordinator = BridgeRPCExecutionCoordinator(limits: limits)
    let gate = AsyncGate()
    let executor = FakeExecutor(readiness: .ready(generation: 1),
                                supportedMethods: ["device_info"]) { _ in
        await gate.wait()
        return .success(.object(["ok": .bool(true)]))
    }
    let fence = BridgeRPCExecutionFence(clientID: "c", authEpoch: 1, clientRevision: 1,
                                        engineGeneration: 1, serviceEpoch: 1)
    func invocation(_ id: String) -> BridgeRPCInvocation {
        BridgeRPCInvocation(operationID: id, clientID: "c", method: "device_info",
                            params: .object([:]), sensitiveInputGranted: false,
                            receivedAt: Date())
    }

    let active = Task {
        await coordinator.submit(invocation: invocation("active"), paramsDigest: "a",
                                 executor: executor, fence: fence, isCurrent: { true })
    }
    _ = await waitUntil(timeout: 2) { executor.count() == 1 }
    let queued1 = Task {
        await coordinator.submit(invocation: invocation("q1"), paramsDigest: "q1",
                                 executor: executor, fence: fence, isCurrent: { true })
    }
    let queued2 = Task {
        await coordinator.submit(invocation: invocation("q2"), paramsDigest: "q2",
                                 executor: executor, fence: fence, isCurrent: { true })
    }
    var queuedNow = 0
    for _ in 0..<200 {
        queuedNow = await coordinator.queuedCount()
        if queuedNow == 2 { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try expectEqual(queuedNow, 2, "two calls waiting in the bounded queue")
    let overflow = await coordinator.submit(invocation: invocation("q3"), paramsDigest: "q3",
                                            executor: executor, fence: fence,
                                            isCurrent: { true })
    if case .failure(let error) = overflow.outcome {
        try expectEqual(error.code, -32016, "queue full code")
    } else {
        throw TestFailure("queue overflow was not refused")
    }
    await coordinator.cancelQueued()
    let q1 = await queued1.value
    let q2 = await queued2.value
    for result in [q1, q2] {
        if case .failure(let error) = result.outcome {
            try expectEqual(error.code, -32019, "queued call cancelled")
        } else {
            throw TestFailure("queued call was not cancelled")
        }
        try expect(!result.dispatched, "cancelled queued call never dispatched")
    }
    try expectEqual(executor.count(), 1, "only the active call dispatched")
    gate.releaseAll()
    let activeResult = await active.value
    if case .success = activeResult.outcome {} else {
        throw TestFailure("active call did not complete")
    }
}

func executionTimeoutNeverReplays() async throws {
    let limits = BridgeRPCLimits(maxQueuedAutomationCalls: 4, executionTimeout: 0.8)
    let coordinator = BridgeRPCExecutionCoordinator(limits: limits)
    let executor = FakeExecutor(readiness: .ready(generation: 1),
                                supportedMethods: ["device_info"]) { _ in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return .success(.object(["late": .bool(true)]))
    }
    let fence = BridgeRPCExecutionFence(clientID: "c", authEpoch: 1, clientRevision: 1,
                                        engineGeneration: 1, serviceEpoch: 1)
    let invocation = BridgeRPCInvocation(operationID: "timeout-op", clientID: "c",
                                         method: "device_info", params: .object([:]),
                                         sensitiveInputGranted: false, receivedAt: Date())
    let start = Date()
    let firstTask = Task {
        await coordinator.submit(invocation: invocation, paramsDigest: "t",
                                 executor: executor, fence: fence, isCurrent: { true })
    }
    let dispatched = await waitUntil(timeout: 0.6) { executor.sdkCount() == 1 }
    try expect(dispatched, "test executor reached authorized dispatch before timeout")
    let first = await firstTask.value
    let elapsed = Date().timeIntervalSince(start)
    try expect(elapsed < 1.2, "timeout returned promptly")
    if case .sideEffectUnknown(let code, _) = first.outcome {
        try expectEqual(code, "execution_timeout", "timeout unknown reason")
    } else if case .failure(let error) = first.outcome {
        try expectEqual(error.code, -32013, "timeout unknown code: got \(error.code) \(error.message)")
    } else {
        throw TestFailure("timeout did not return unknown: \(first.outcome)")
    }
    try expect(first.dispatched, "operation had dispatched")
    let retry = await coordinator.submit(invocation: invocation, paramsDigest: "t",
                                         executor: executor, fence: fence,
                                         isCurrent: { true })
    if case .failure(let error) = retry.outcome {
        try expectEqual(error.code, -32013, "timeout retry remains unknown")
    }
    try expectEqual(executor.count(), 1, "timeout not replayed")
    try await Task.sleep(nanoseconds: 800_000_000)
    let after = await coordinator.submit(invocation: invocation, paramsDigest: "t",
                                         executor: executor, fence: fence,
                                         isCurrent: { true })
    if case .failure(let error) = after.outcome {
        try expectEqual(error.code, -32013, "late completion never becomes a replay success")
    }
    try expectEqual(executor.count(), 1, "late completion did not re-execute")
}

func responseLimit() async throws {
    var limits = TestLimits.standard
    limits.maxJSONResponseBytes = 64 * 1_024
    let fixture = ServerFixture(limits: limits)
    let port = try fixture.start()
    defer { fixture.stop() }
    let executor = FakeExecutor(readiness: .ready(generation: 1),
                                supportedMethods: ["screenshot"]) { _ in
        .success(.object(["data": .string(String(repeating: "A", count: 200_000))]))
    }
    let registration = fixture.registry.register(owner: "big", executor: executor)
    guard case .registered(let generation) = registration else {
        throw TestFailure("response-limit registration failed")
    }
    executor.setReadiness(.ready(generation: generation))
    let paired = try BridgeTestClient.pairPlain(host: "127.0.0.1", port: port, name: "big")
    let request = BridgeRPCRequest(method: "screenshot", params: .object([:]), id: .int(1))
    let nonce = BridgeRPCEnvelope.randomBytes(16)!
    let envelope = BridgeRPCEnvelope.sealRequest(
        request.encodedData(), key: paired.session.key, nonce: nonce,
        timestamp: Int(Date().timeIntervalSince1970)
    )
    let http = try RawHTTP.request(host: "127.0.0.1", port: port, method: "POST",
                                   path: "/rpc", body: envelope.canonicalData())
    if http.status != 200 {
        throw TestFailure("response-limit transport status \(http.status) body=\(String(decoding: http.body.prefix(300), as: UTF8.self))")
    }
    let envelopeValue = try BridgeRPCJSON.decode(http.body)
    let plaintext = try BridgeRPCEnvelope.openResponse(
        envelopeValue, key: paired.session.key,
        expectedNonceHex: BridgeRPCEnvelope.hexLowercase(nonce)
    )
    let call = BridgeRPCJSONValue.object([
        "response": try BridgeRPCJSON.decode(plaintext),
        "raw": .null,
    ])
    let response = try BridgeRPCJSON.decode(plaintext)
    let errorCode = response.objectValue?["error"]?.objectValue?["code"]?.intValue
    try expectEqual(errorCode, -32018, "oversize result refused; bytes=\(http.raw.count) logs=\(fixture.transportLog())")
    try expect(call.canonicalData().count < 64 * 1_024, "bounded fallback body")
}

func registrySingleRegistration() throws {
    let registry = BridgeRPCEngineRegistry()
    let first = FakeExecutor(readiness: .ready(generation: 1),
                             supportedMethods: ["device_info"]) { _ in
        .success(.object(["ok": .bool(true)]))
    }
    let firstResult = registry.register(owner: "first", executor: first)
    guard case .registered(let generation) = firstResult else {
        throw TestFailure("first registration failed")
    }
    let same = registry.register(owner: "first", executor: first)
    guard case .alreadyRegistered(let sameGeneration) = same, sameGeneration == generation else {
        throw TestFailure("same owner registration was not idempotent")
    }
    let other = registry.register(owner: "second", executor: first)
    guard case .rejected = other else {
        throw TestFailure("second owner was accepted")
    }
    try expectEqual(registry.registrationCount, 1, "only one actual registration")
    try expectEqual(registry.rejectedRegistrationCount, 1, "rejected attempt counted")
    try expect(registry.unregister(owner: "first"), "owner can unregister its engine")
    guard case .notRegistered = registry.snapshot().readiness else {
        throw TestFailure("unregistered snapshot still ready")
    }
    let afterUnregister = registry.register(owner: "third", executor: first)
    guard case .rejected = afterUnregister else {
        throw TestFailure("process allowed a second engine after unregister")
    }
}

func largeResultFirstReturnNotCached() async throws {
    var limits = TestLimits.standard
    limits.maxJSONResponseBytes = 4 * 1_024 * 1_024
    limits.maxSingleOperationResultBytes = 1 * 1_024 * 1_024
    let fixture = ServerFixture(limits: limits)
    let port = try fixture.start()
    defer { fixture.stop() }
    let payload = String(repeating: "B", count: 1_500_000)
    let executor = FakeExecutor(readiness: .ready(generation: 1),
                                supportedMethods: ["screenshot"]) { _ in
        .success(.object(["data": .string(payload), "bytes": .int(payload.utf8.count)]))
    }
    let registration = fixture.registry.register(owner: "large", executor: executor)
    guard case .registered(let generation) = registration else { throw TestFailure("large engine") }
    executor.setReadiness(.ready(generation: generation))
    let paired = try BridgeTestClient.pairPlain(host: "127.0.0.1", port: port, name: "large")
    let first = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                          port: port, method: "screenshot",
                                          operationID: "large-shot-1")
    try expectEqual(BridgeTestClient.resultObject(first)?["bytes"]?.intValue,
                    payload.utf8.count, "first large result is returned normally")
    let retry = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                          port: port, method: "screenshot",
                                          operationID: "large-shot-1")
    try expectEqual(BridgeTestClient.errorCode(retry), -32020,
                    "oversize retained result is not re-executed")
    try expectEqual(executor.count(), 1, "large result was not replayed")
}

// MARK: - HTTP framing

func httpParserLimits() throws {
    let limits = BridgeRPCLimits()
    let valid = Data("GET /schema HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
    guard case .complete = BridgeRPCHTTPParser.inspect(valid, limits: limits) else {
        throw TestFailure("valid request rejected")
    }
    let missingHost = Data("GET /schema HTTP/1.1\r\n\r\n".utf8)
    guard case .invalid(let status, let code, _) = BridgeRPCHTTPParser.inspect(missingHost, limits: limits) else {
        throw TestFailure("missing Host accepted")
    }
    try expectEqual(status, 400, "missing Host status")
    try expectEqual(code, "missing_host", "missing Host code")

    let duplicate = Data("GET /schema HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n".utf8)
    guard case .invalid(_, let duplicateCode, _) = BridgeRPCHTTPParser.inspect(duplicate, limits: limits) else {
        throw TestFailure("duplicate Content-Length accepted")
    }
    try expectEqual(duplicateCode, "duplicate_content_length", "duplicate CL code")

    let transfer = Data("POST /rpc HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
    guard case .invalid(_, let transferCode, _) = BridgeRPCHTTPParser.inspect(transfer, limits: limits) else {
        throw TestFailure("transfer encoding accepted")
    }
    try expectEqual(transferCode, "unsupported_transfer", "transfer code")

    let getBody = Data("GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n\r\nx".utf8)
    guard case .invalid(_, let bodyCode, _) = BridgeRPCHTTPParser.inspect(getBody, limits: limits) else {
        throw TestFailure("GET body accepted")
    }
    try expectEqual(bodyCode, "unexpected_body", "GET body code")

    var large = Data("POST /rpc HTTP/1.1\r\nHost: x\r\nContent-Length: 300000\r\n\r\n".utf8)
    large.append(Data(repeating: 0, count: 4))
    guard case .invalid(let largeStatus, let largeCode, _) = BridgeRPCHTTPParser.inspect(large, limits: limits) else {
        throw TestFailure("oversize Content-Length accepted")
    }
    try expectEqual(largeStatus, 413, "oversize status")
    try expectEqual(largeCode, "request_body_too_large", "oversize code")

    let trailing = Data("GET /schema HTTP/1.1\r\nHost: x\r\n\r\nGET /schema HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
    guard case .invalid(_, let trailingCode, _) = BridgeRPCHTTPParser.inspect(trailing, limits: limits) else {
        throw TestFailure("pipelined request accepted")
    }
    try expectEqual(trailingCode, "unexpected_trailing_bytes", "trailing code")
}

func stopClosesTicketsAndConnections() async throws {
    let stream = TestStreamSource()
    let fixture = ServerFixture(streamSource: stream)
    let port = try fixture.start()
    let paired = try BridgeTestClient.pairPlain(host: "127.0.0.1", port: port, name: "stop")
    let ticketCall = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                               port: port, method: "stream_ticket")
    let ticket = try expectNotNil(BridgeTestClient.resultObject(ticketCall)?["ticket"]?.stringValue,
                                  "stop ticket")
    fixture.stop()
    try expectEqual(fixture.server.snapshot.running, false, "server stopped")
    try expect(fixture.authority.consumeStreamTicket(ticket) == nil, "tickets cleared on stop")
    do {
        _ = try RawHTTP.request(host: "127.0.0.1", port: port, method: "GET", path: "/schema")
        throw TestFailure("stopped server still accepted a connection")
    } catch is HTTPClientError {}
    try expect(fixture.store.count() == 1, "client key survives stop")
    let secondPort = try fixture.start()
    defer { fixture.stop() }
    try expect(secondPort > 0, "server restart port")
    let config = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                           port: secondPort, method: "config")
    try expect(BridgeTestClient.resultObject(config) != nil, "client key usable after restart")
}

func configStopAndHostSnapshot() async throws {
    let fixture = ServerFixture()
    let port = try fixture.start()
    defer { fixture.stop() }
    fixture.service.setStopHandler { fixture.stop() }
    let paired = try BridgeTestClient.pairPlain(host: "127.0.0.1", port: port, name: "config-stop")
    let stop = try BridgeTestClient.call(session: paired.session, host: "127.0.0.1",
                                         port: port, method: "config",
                                         params: .object(["stop_server": .bool(true)]))
    let result = try expectNotNil(BridgeTestClient.resultObject(stop), "stop config result")
    try expectEqual(result["stopping"]?.boolValue, true, "stopping acknowledged")
    let stopped = await waitUntil(timeout: 2) { !fixture.server.snapshot.running }
    try expect(stopped, "config stop stopped listeners")
}
