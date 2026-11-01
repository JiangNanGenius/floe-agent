import Foundation
import XCTest
@testable import FloeIOSAutomation

private func rpcResponse(
    _ request: FixtureRequest,
    key: Data,
    result: IOSBridgeJSONValue
) -> FixtureResponse {
    do {
        return try fixtureRPCResult(request, key: key, result: result)
    } catch {
        return fixtureError(500, code: "fixture_error", message: "\(error)")
    }
}

final class ClientContractTests: XCTestCase {
    private func makeClient(
        port: UInt16,
        store: MemoryPairingStore,
        clock: TestClock = TestClock(),
        authority: any IOSAutomationTaskAuthority = AllowAllAuthority(),
        policy: IOSAutomationProtectionPolicy = .default,
        probe: (any IOSBridgeCompanionProbe)? = nil,
        platformAllowsLocalAutomation: Bool = true,
        transport: any IOSBridgeHTTPTransport = IOSBridgeURLSessionTransport(),
        randomness: any IOSBridgeRandomness = TestRandomness()
    ) throws -> IOSBridgeClient {
        IOSBridgeClient(configuration: .init(
            store: store,
            platformAllowsLocalAutomation: platformAllowsLocalAutomation,
            endpoint: try IOSBridgeEndpoint(port: port),
            transport: transport,
            authority: authority,
            companionProbe: probe,
            policy: policy,
            clock: clock,
            randomness: randomness,
            pairingTimeout: 5,
            rpcTimeout: 5,
            statusTimeout: 2,
            credentialTouchInterval: 0
        ))
    }

    @discardableResult
    private func seed(
        _ store: MemoryPairingStore,
        key: Data,
        clock: TestClock
    ) async throws -> IOSBridgePairingRecord {
        let record = try testRecord(
            key: key,
            grantedAt: clock.now(),
            expiresAt: clock.now().addingTimeInterval(30 * 24 * 60 * 60)
        )
        try await store.seed(record, for: .localDefault)
        return record
    }

    func testStatusNeedsPairingThenReady() async throws {
        let clock = TestClock()
        let key = testKey(11)
        let store = MemoryPairingStore()
        let expiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let server = FixtureHTTPServer { request in
            switch request.path {
            case "/":
                return FixtureResponse(status: 200, body: fixtureInfoBody())
            case "/rpc":
                return rpcResponse(
                    request,
                    key: key,
                    result: fixtureConfigResult(
                        key: key,
                        engine: "ready",
                        methods: ["device_info", "page_source", "screenshot", "tap", "type"],
                        expiresAt: expiry,
                        sensitiveInput: false
                    )
                )
            default:
                return fixtureError(404, code: "not_found", message: "missing")
            }
        }
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)

        let needsPairing = await client.status()
        XCTAssertEqual(needsPairing.status, .needsPairing)
        XCTAssertEqual(server.requestCount, 1)

        try await seed(store, key: key, clock: clock)
        let ready = await client.status()
        XCTAssertEqual(ready.status, .ready)
        XCTAssertTrue(ready.status.isReady)
        XCTAssertEqual(ready.info?.protocolVersion, 1)
        XCTAssertEqual(ready.configuration?.engineState, .ready)
        XCTAssertEqual(ready.configuration?.supportedMethods.count, 5)
        XCTAssertEqual(ready.clientExpiresAt, Date(timeIntervalSince1970: TimeInterval(expiry)))
        XCTAssertFalse(ready.sensitiveInputGranted)

        let methodsAfter = server.requests.map(\.method)
        XCTAssertEqual(methodsAfter, ["GET", "GET", "POST"])
    }

    func testStatusLockedExpiredRevokedAndRegistrationMissing() async throws {
        let clock = TestClock()
        let key = testKey(12)
        let expiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let rejectAuth = LockedValue(false)

        let store = MemoryPairingStore()
        let server = FixtureHTTPServer { request in
            switch request.path {
            case "/":
                return FixtureResponse(status: 200, body: fixtureInfoBody())
            case "/rpc":
                if rejectAuth.value {
                    return fixtureError(401, code: "auth_failed", message: "expired")
                }
                return rpcResponse(
                    request,
                    key: key,
                    result: fixtureConfigResult(key: key, expiresAt: expiry)
                )
            default:
                return fixtureError(404, code: "not_found", message: "missing")
            }
        }
        let port = try server.start()
        defer { server.stop() }

        await store.setMode(.locked)
        let lockedClient = try makeClient(port: port, store: store, clock: clock)
        let locked = await lockedClient.status()
        XCTAssertEqual(locked.status, .lockedCredentials)

        await store.setMode(.normal)
        try await store.seed(
            try testRecord(
                key: key,
                grantedAt: clock.now().addingTimeInterval(-31 * 24 * 60 * 60),
                expiresAt: clock.now().addingTimeInterval(-1)
            ),
            for: .localDefault
        )
        rejectAuth.set(true)
        let expiredClient = try makeClient(port: port, store: store, clock: clock)
        let expired = await expiredClient.status()
        XCTAssertEqual(expired.status, .expired)
    }

    func testStatusRefreshesExpiredHintWhenServerStillAccepts() async throws {
        let clock = TestClock()
        let key = testKey(35)
        let store = MemoryPairingStore()
        let oldRecord = try testRecord(
            key: key,
            grantedAt: clock.now().addingTimeInterval(-31 * 24 * 60 * 60),
            expiresAt: clock.now().addingTimeInterval(-1)
        )
        try await store.seed(oldRecord, for: .localDefault)
        let serverExpiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let server = FixtureHTTPServer { request in
            switch request.path {
            case "/":
                return FixtureResponse(status: 200, body: fixtureInfoBody())
            case "/rpc":
                return rpcResponse(
                    request,
                    key: key,
                    result: fixtureConfigResult(key: key, expiresAt: serverExpiry)
                )
            default:
                return fixtureError(404, code: "not_found", message: "missing")
            }
        }
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)
        let snapshot = await client.status()
        XCTAssertEqual(snapshot.status, .ready)
        let refreshed = try await store.load(.localDefault)
        XCTAssertEqual(
            refreshed.expiresAt,
            Date(timeIntervalSince1970: TimeInterval(serverExpiry))
        )
        XCTAssertGreaterThan(refreshed.lastVerifiedAt, oldRecord.lastVerifiedAt)
    }

    func testStatusRevokedWhenConfigReturns401() async throws {
        let clock = TestClock()
        let key = testKey(13)
        let store = MemoryPairingStore()
        let server = FixtureHTTPServer { request in
            switch request.path {
            case "/":
                return FixtureResponse(status: 200, body: fixtureInfoBody())
            case "/rpc":
                return fixtureError(401, code: "auth_failed", message: "not authorized")
            default:
                return fixtureError(404, code: "not_found", message: "missing")
            }
        }
        let port = try server.start()
        defer { server.stop() }
        try await seed(store, key: key, clock: clock)
        let client = try makeClient(port: port, store: store, clock: clock)
        let snapshot = await client.status()
        XCTAssertEqual(snapshot.status, .revoked)
        XCTAssertFalse(snapshot.status.isReady)
    }

    func testStatusUnreachableDistinguishesProbeResults() async throws {
        let probeServer = FixtureHTTPServer { _ in
            FixtureResponse(status: 200, body: Data("{}".utf8))
        }
        let port = try probeServer.start()
        probeServer.stop()
        try await Task.sleep(nanoseconds: 150_000_000)

        let store = MemoryPairingStore()
        let unknown = try makeClient(port: port, store: store)
        let unknownStatus = await unknown.status()
        XCTAssertEqual(unknownStatus.status, .serviceUnavailable)

        let missing = try makeClient(
            port: port,
            store: store,
            probe: StubCompanionProbe(value: .missing)
        )
        let missingStatus = await missing.status()
        XCTAssertEqual(missingStatus.status, .companionMissing)

        let installed = try makeClient(
            port: port,
            store: store,
            probe: StubCompanionProbe(value: .installed)
        )
        let installedStatus = await installed.status()
        XCTAssertEqual(installedStatus.status, .serviceOff)
    }

    func testPairingSavesVerifiedRecordAndBecomesReady() async throws {
        let clock = TestClock()
        let key = testKey(14)
        let expiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let store = MemoryPairingStore()
        let progress = LockedValue<[IOSBridgePairingProgress]>([])
        let server = FixtureHTTPServer { request in
            switch request.path {
            case "/":
                return FixtureResponse(status: 200, body: fixtureInfoBody())
            case "/pair":
                do {
                    return try fixturePairResponse(
                        request,
                        key: key,
                        expireSeconds: expiry
                    )
                } catch {
                    return fixtureError(500, code: "fixture_error", message: "\(error)")
                }
            case "/rpc":
                return rpcResponse(
                    request,
                    key: key,
                    result: fixtureConfigResult(key: key, expiresAt: expiry)
                )
            default:
                return fixtureError(404, code: "not_found", message: "missing")
            }
        }
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)

        let result = try await client.pair(clientName: "Floe on iPhone") { event in
            progress.mutate { $0.append(event) }
        }
        XCTAssertEqual(result.clientName, "Floe on iPhone")
        XCTAssertEqual(result.tokenID, IOSBridgeEnvelope.tokenID(for: key))
        XCTAssertEqual(result.expiresAt, Date(timeIntervalSince1970: TimeInterval(expiry)))

        let stored = try await store.load(.localDefault)
        XCTAssertEqual(stored.tokenID, result.tokenID)
        let expectedRecord = try testRecord(key: key, expiresAt: result.expiresAt)
        XCTAssertTrue(stored.matchesKey(in: expectedRecord))
        let events = progress.value
        XCTAssertTrue(events.contains(.contactingCompanion))
        XCTAssertTrue(events.contains(.waitingForOwnerApproval))
        XCTAssertTrue(events.contains(.savingCredential))
        XCTAssertTrue(events.contains(.verifyingCredential))
        XCTAssertTrue(events.contains(.paired(expiresAt: result.expiresAt)))

        let snapshot = await client.status()
        XCTAssertEqual(snapshot.status, .ready)
    }

    func testPairingRejectsTamperedWrappedKeyAndPlaintextDowngrade() async throws {
        let clock = TestClock()
        let oldKey = testKey(15)
        let newKey = testKey(16)
        let expiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let store = MemoryPairingStore()
        try await seed(store, key: oldKey, clock: clock)
        let oldToken = IOSBridgeEnvelope.tokenID(for: oldKey)

        let mode = LockedValue<String>("tamper")
        let server = FixtureHTTPServer { request in
            switch request.path {
            case "/":
                return FixtureResponse(status: 200, body: fixtureInfoBody())
            case "/pair":
                if mode.value == "denied" {
                    return fixtureError(403, code: "pair_denied", message: "denied")
                }
                if mode.value == "busy" {
                    return fixtureError(
                        429,
                        code: "pair_busy",
                        message: "busy",
                        retryAfter: 42
                    )
                }
                do {
                    let valid = try fixturePairResponse(
                        request,
                        key: newKey,
                        expireSeconds: expiry
                    )
                    var object = try XCTUnwrap(
                        IOSBridgeJSONValue.decode(valid.body).objectValue
                    )
                    if mode.value == "tamper" {
                        let current = try XCTUnwrap(object["token_ct"]?.stringValue)
                        let lastPair = String(current.suffix(2))
                        let changed = lastPair == "00" ? "01" : "00"
                        object["token_ct"] = .string(
                            String(current.dropLast(2)) + changed
                        )
                    } else if mode.value == "plain" {
                        object["token"] = .string(IOSBridgeEnvelope.hexLowercase(newKey))
                    }
                    return FixtureResponse(
                        status: 200,
                        body: IOSBridgeJSONValue.object(object).canonicalData()
                    )
                } catch {
                    return fixtureError(500, code: "fixture_error", message: "\(error)")
                }
            default:
                return fixtureError(404, code: "not_found", message: "missing")
            }
        }
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)

        do {
            _ = try await client.pair(clientName: "Floe on iPhone", replaceExisting: true)
            XCTFail("tampered pairing must be rejected")
        } catch let error as IOSBridgeError {
            XCTAssertEqual(error, .pairingResponseInvalid)
        }
        let afterTamper = try await store.load(.localDefault)
        XCTAssertEqual(afterTamper.tokenID, oldToken)

        mode.set("plain")
        do {
            _ = try await client.pair(clientName: "Floe on iPhone", replaceExisting: true)
            XCTFail("plaintext pairing downgrade must be rejected")
        } catch let error as IOSBridgeError {
            XCTAssertEqual(error, .pairingResponseInvalid)
        }
        let afterPlain = try await store.load(.localDefault)
        XCTAssertEqual(afterPlain.tokenID, oldToken)

        mode.set("denied")
        do {
            _ = try await client.pair(clientName: "Floe on iPhone", replaceExisting: true)
            XCTFail("denied pairing must throw")
        } catch let error as IOSBridgeError {
            XCTAssertEqual(error, .pairingDenied)
        }

        mode.set("busy")
        do {
            _ = try await client.pair(clientName: "Floe on iPhone", replaceExisting: true)
            XCTFail("busy pairing must throw")
        } catch let error as IOSBridgeError {
            XCTAssertEqual(error, .pairingBusy(retryAfter: 42))
        }
    }

    func testPairingSaveFailureIsNeverClaimed() async throws {
        let clock = TestClock()
        let key = testKey(17)
        let expiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let store = MemoryPairingStore()
        await store.setMode(.failSave)
        let server = FixtureHTTPServer { request in
            switch request.path {
            case "/":
                return FixtureResponse(status: 200, body: fixtureInfoBody())
            case "/pair":
                do {
                    return try fixturePairResponse(
                        request,
                        key: key,
                        expireSeconds: expiry
                    )
                } catch {
                    return fixtureError(500, code: "fixture_error", message: "\(error)")
                }
            default:
                return fixtureError(404, code: "not_found", message: "missing")
            }
        }
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)
        do {
            _ = try await client.pair(clientName: "Floe on iPhone")
            XCTFail("save failure must not be reported as paired")
        } catch let error as IOSBridgeError {
            XCTAssertEqual(error, .credentialStoreUnavailable)
        }
        let availability = await store.availability(for: .localDefault)
        XCTAssertEqual(availability, .missing)
    }

    func testReadbackMismatchRestoresOldRecord() async throws {
        let clock = TestClock()
        let oldKey = testKey(18)
        let newKey = testKey(19)
        let expiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let store = MemoryPairingStore()
        try await seed(store, key: oldKey, clock: clock)
        let alternate = try testRecord(key: testKey(20), grantedAt: clock.now(), expiresAt: clock.now().addingTimeInterval(30 * 24 * 60 * 60))
        await store.setAlternateRecord(alternate)
        await store.setMode(.mismatchAfterSave)
        let server = FixtureHTTPServer { request in
            switch request.path {
            case "/":
                return FixtureResponse(status: 200, body: fixtureInfoBody())
            case "/pair":
                do {
                    return try fixturePairResponse(request, key: newKey, expireSeconds: expiry)
                } catch {
                    return fixtureError(500, code: "fixture_error", message: "\(error)")
                }
            default:
                return fixtureError(404, code: "not_found", message: "missing")
            }
        }
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)
        do {
            _ = try await client.pair(
                clientName: "Floe on iPhone",
                replaceExisting: true
            )
            XCTFail("mismatched readback must not be claimed as paired")
        } catch let error as IOSBridgeError {
            XCTAssertEqual(error, .credentialStoreVerificationFailed)
        }
        await store.setMode(.normal)
        let restored = try await store.load(.localDefault)
        XCTAssertEqual(restored.tokenID, IOSBridgeEnvelope.tokenID(for: oldKey))
    }

    func testForgetLocalPairingNeverCallsServer() async throws {
        let clock = TestClock()
        let key = testKey(21)
        let store = MemoryPairingStore()
        try await seed(store, key: key, clock: clock)
        let server = FixtureHTTPServer { _ in
            FixtureResponse(status: 500, body: Data())
        }
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)
        let result = try await client.forgetLocalPairing()
        XCTAssertTrue(result.handleWasPresent)
        XCTAssertTrue(result.serverGrantMayRemain)
        let availability = await store.availability(for: .localDefault)
        XCTAssertEqual(availability, .missing)
        XCTAssertEqual(server.requestCount, 0)

        await store.setMode(.locked)
        do {
            _ = try await client.forgetLocalPairing()
            XCTFail("locked store must not be deleted")
        } catch let error as IOSBridgeError {
            XCTAssertEqual(error, .credentialStoreLocked)
        }
    }

    func testObserveAndControlPreflight() async throws {
        let clock = TestClock()
        let key = testKey(22)
        let expiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let store = MemoryPairingStore()
        try await seed(store, key: key, clock: clock)
        let foreground = LockedValue<String>("com.example.notes")
        let server = FixtureHTTPServer { request in
            guard request.path == "/rpc" else {
                return request.path == "/"
                    ? FixtureResponse(status: 200, body: fixtureInfoBody())
                    : fixtureError(404, code: "not_found", message: "missing")
            }
            guard let parsed = try? fixtureParseRPC(request, key: key) else {
                return fixtureError(400, code: "fixture_error", message: "bad rpc")
            }
            switch parsed.method {
            case "config":
                return rpcResponse(
                    request,
                    key: key,
                    result: fixtureConfigResult(key: key, expiresAt: expiry)
                )
            case "page_source":
                return rpcResponse(
                    request,
                    key: key,
                    result: .object([
                        "bundle_id": .string(foreground.value),
                        "source": .string("test tree"),
                    ])
                )
            case "device_info":
                return rpcResponse(
                    request,
                    key: key,
                    result: .object(["scale": .double(2.5)])
                )
            case "wait":
                return rpcResponse(
                    request,
                    key: key,
                    result: .object(["message": .string("waited")])
                )
            case "tap":
                return rpcResponse(
                    request,
                    key: key,
                    result: .object(["message": .string("tapped")])
                )
            default:
                return fixtureError(400, code: "fixture_error", message: "unexpected method")
            }
        }
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)
        let context = testContext()

        let deviceInfo = await client.deviceInfo(context: context)
        XCTAssertTrue(deviceInfo.isSuccess)
        XCTAssertEqual(deviceInfo.resultObject?["scale"], .double(2.5))

        let tap = await client.tap(
            context: context,
            targetBundleID: "com.example.notes",
            x: 10,
            y: 20
        )
        XCTAssertTrue(tap.isSuccess)
        XCTAssertEqual(tap.action, .tap)
        XCTAssertEqual(tap.effect, .mutating)
        XCTAssertTrue(tap.usedInputLease)
        let methods = server.requests.compactMap {
            try? fixtureParseRPC($0, key: key).method
        }
        XCTAssertEqual(methods.suffix(2), ["page_source", "tap"])

        // A read-only wait has no foreground preflight.
        let beforeWait = server.requestCount
        let wait = await client.wait(context: context, duration: 0.01)
        XCTAssertTrue(wait.isSuccess)
        XCTAssertEqual(server.requestCount, beforeWait + 1)
        let lastMethod = try fixtureParseRPC(
            try XCTUnwrap(server.requests.last),
            key: key
        ).method
        XCTAssertEqual(lastMethod, "wait")
    }

    func testControlRejectsProtectedOrUnverifiedForeground() async throws {
        let clock = TestClock()
        let key = testKey(23)
        let expiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let store = MemoryPairingStore()
        try await seed(store, key: key, clock: clock)
        let foreground = LockedValue<String>("org.floeagent.ios")
        let server = FixtureHTTPServer { request in
            guard request.path == "/rpc" else {
                return FixtureResponse(status: 200, body: fixtureInfoBody())
            }
            guard let parsed = try? fixtureParseRPC(request, key: key) else {
                return fixtureError(400, code: "fixture_error", message: "bad rpc")
            }
            switch parsed.method {
            case "page_source":
                return rpcResponse(
                    request,
                    key: key,
                    result: .object(["bundle_id": .string(foreground.value)])
                )
            case "tap":
                return rpcResponse(
                    request,
                    key: key,
                    result: .object(["message": .string("tapped")])
                )
            case "config":
                return rpcResponse(
                    request,
                    key: key,
                    result: fixtureConfigResult(key: key, expiresAt: expiry)
                )
            default:
                return fixtureError(400, code: "fixture_error", message: "unexpected")
            }
        }
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)

        let protected = await client.tap(
            context: testContext(),
            targetBundleID: "org.floeagent.ios",
            x: 1,
            y: 2
        )
        XCTAssertEqual(protected.outcome, .notSent(.protectedTarget))
        XCTAssertEqual(server.requests.filter { request in
            (try? fixtureParseRPC(request, key: key).method) == "tap"
        }.count, 0)

        foreground.set("com.example.notes")
        let mismatch = await client.tap(
            context: testContext(),
            targetBundleID: "com.example.other",
            x: 1,
            y: 2
        )
        XCTAssertEqual(mismatch.outcome, .notSent(.targetNotForeground))

        let protectedRead = await client.screenshot(
            context: testContext(),
            bundleID: "org.floeagent.iosbridge"
        )
        XCTAssertEqual(protectedRead.outcome, .notSent(.protectedTarget))

        let protectedURL = await client.openURL(
            context: testContext(),
            url: URL(string: "floe://open")!
        )
        XCTAssertEqual(protectedURL.outcome, .notSent(.protectedTarget))
    }

    func testInputLeaseSerializesConcurrentMutations() async throws {
        let clock = TestClock()
        let key = testKey(24)
        let expiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let store = MemoryPairingStore()
        try await seed(store, key: key, clock: clock)
        let server = FixtureHTTPServer { request in
            guard request.path == "/rpc" else {
                return FixtureResponse(status: 200, body: fixtureInfoBody())
            }
            guard let parsed = try? fixtureParseRPC(request, key: key) else {
                return fixtureError(400, code: "fixture_error", message: "bad rpc")
            }
            switch parsed.method {
            case "page_source":
                return rpcResponse(
                    request,
                    key: key,
                    result: .object(["bundle_id": .string("com.example.notes")])
                )
            case "tap":
                let response = rpcResponse(
                    request,
                    key: key,
                    result: .object(["message": .string("tapped")])
                )
                return FixtureResponse(
                    status: response.status,
                    headers: response.headers,
                    body: response.body,
                    delay: 0.7
                )
            case "config":
                return rpcResponse(
                    request,
                    key: key,
                    result: fixtureConfigResult(key: key, expiresAt: expiry)
                )
            default:
                return fixtureError(400, code: "fixture_error", message: "unexpected")
            }
        }
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)

        let taskID = UUID()
        let task = Task {
            await client.tap(
                context: testContext(taskID: taskID),
                targetBundleID: "com.example.notes",
                x: 1,
                y: 2
            )
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if server.requests.contains(where: {
                (try? fixtureParseRPC($0, key: key).method) == "tap"
            }) {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let second = await client.tap(
            context: testContext(taskID: taskID),
            targetBundleID: "com.example.notes",
            x: 3,
            y: 4
        )
        XCTAssertEqual(second.outcome, .notSent(.inputBusy))
        let first = await task.value
        XCTAssertTrue(first.isSuccess)
        let tapCount = server.requests.filter {
            (try? fixtureParseRPC($0, key: key).method) == "tap"
        }.count
        XCTAssertEqual(tapCount, 1)
    }

    func testCancellationAfterDispatchReportsUnknownWithoutRetry() async throws {
        let clock = TestClock()
        let key = testKey(25)
        let expiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let store = MemoryPairingStore()
        try await seed(store, key: key, clock: clock)
        let server = FixtureHTTPServer { request in
            guard request.path == "/rpc" else {
                return FixtureResponse(status: 200, body: fixtureInfoBody())
            }
            guard let parsed = try? fixtureParseRPC(request, key: key) else {
                return fixtureError(400, code: "fixture_error", message: "bad rpc")
            }
            switch parsed.method {
            case "page_source":
                return rpcResponse(
                    request,
                    key: key,
                    result: .object(["bundle_id": .string("com.example.notes")])
                )
            case "tap":
                let response = rpcResponse(
                    request,
                    key: key,
                    result: .object(["message": .string("tapped")])
                )
                return FixtureResponse(
                    status: response.status,
                    headers: response.headers,
                    body: response.body,
                    delay: 1.0
                )
            case "config":
                return rpcResponse(
                    request,
                    key: key,
                    result: fixtureConfigResult(key: key, expiresAt: expiry)
                )
            default:
                return fixtureError(400, code: "fixture_error", message: "unexpected")
            }
        }
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)
        let cancellation = IOSAutomationCancellationToken()
        let context = testContext(cancellation: cancellation)
        let task = Task {
            await client.tap(
                context: context,
                targetBundleID: "com.example.notes",
                x: 1,
                y: 2
            )
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if server.requests.contains(where: {
                (try? fixtureParseRPC($0, key: key).method) == "tap"
            }) {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        cancellation.cancel()
        let receipt = await task.value
        XCTAssertTrue(receipt.isOutcomeUnknown, "\(receipt)")
        if case .outcomeUnknown(let unknown) = receipt.outcome {
            XCTAssertEqual(unknown.reason, .cancelledAfterDispatch)
            XCTAssertFalse(unknown.recovery.permitsAutomaticRetry)
        } else {
            XCTFail("expected unknown outcome")
        }
        let tapCount = server.requests.filter {
            (try? fixtureParseRPC($0, key: key).method) == "tap"
        }.count
        XCTAssertEqual(tapCount, 1)
    }

    func testDroppedMutationIsUnknownAndNotRetried() async throws {
        let clock = TestClock()
        let key = testKey(26)
        let expiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let store = MemoryPairingStore()
        try await seed(store, key: key, clock: clock)
        let server = FixtureHTTPServer { request in
            guard request.path == "/rpc" else {
                return FixtureResponse(status: 200, body: fixtureInfoBody())
            }
            guard let parsed = try? fixtureParseRPC(request, key: key) else {
                return fixtureError(400, code: "fixture_error", message: "bad rpc")
            }
            switch parsed.method {
            case "page_source":
                return rpcResponse(
                    request,
                    key: key,
                    result: .object(["bundle_id": .string("com.example.notes")])
                )
            case "tap":
                return .dropping()
            case "config":
                return rpcResponse(
                    request,
                    key: key,
                    result: fixtureConfigResult(key: key, expiresAt: expiry)
                )
            default:
                return fixtureError(400, code: "fixture_error", message: "unexpected")
            }
        }
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)
        let receipt = await client.tap(
            context: testContext(),
            targetBundleID: "com.example.notes",
            x: 1,
            y: 2
        )
        XCTAssertTrue(receipt.isOutcomeUnknown, "\(receipt)")
        let tapCount = server.requests.filter {
            (try? fixtureParseRPC($0, key: key).method) == "tap"
        }.count
        XCTAssertEqual(tapCount, 1)
    }

    func testConfigIsInternalAndCannotEscalate() async throws {
        let clock = TestClock()
        let key = testKey(27)
        let expiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let store = MemoryPairingStore()
        try await seed(store, key: key, clock: clock)
        let seenParams = LockedValue<[[String: IOSBridgeJSONValue]]>([])
        let server = FixtureHTTPServer { request in
            guard request.path == "/rpc" else {
                return FixtureResponse(status: 200, body: fixtureInfoBody())
            }
            guard let parsed = try? fixtureParseRPC(request, key: key) else {
                return fixtureError(400, code: "fixture_error", message: "bad rpc")
            }
            if parsed.method == "config" {
                seenParams.mutate { $0.append(parsed.params) }
                return rpcResponse(
                    request,
                    key: key,
                    result: fixtureConfigResult(key: key, expiresAt: expiry)
                )
            }
            return fixtureError(400, code: "fixture_error", message: "unexpected method")
        }
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)

        let config = await client.readBridgeConfiguration()
        XCTAssertTrue(config.isSuccess)
        XCTAssertEqual(seenParams.value.first, [:])

        let before = server.requestCount
        let stop = await client.perform(
            .config,
            params: .object(["stop_server": .bool(true)]),
            context: testContext()
        )
        XCTAssertEqual(stop.outcome, .notSent(.actionNotAllowed(
            "The config method is internal to the connection service."
        )))
        let logs = await client.perform(.logs, context: testContext())
        XCTAssertNotNil(logs.error)
        let ticket = await client.perform(.streamTicket, context: testContext())
        XCTAssertNotNil(ticket.error)
        let reset = await client.perform(.reset, context: testContext())
        XCTAssertNotNil(reset.error)
        XCTAssertEqual(server.requestCount, before)
    }

    func testStatusDoesNotClaimReadyWithoutAuthenticatedConfig() async throws {
        let clock = TestClock()
        let key = testKey(28)
        let store = MemoryPairingStore()
        try await seed(store, key: key, clock: clock)
        let server = FixtureHTTPServer { request in
            switch request.path {
            case "/":
                return FixtureResponse(
                    status: 200,
                    body: fixtureInfoBody(engine: "ready")
                )
            case "/rpc":
                return fixtureError(401, code: "auth_required", message: "pair first")
            default:
                return fixtureError(404, code: "not_found", message: "missing")
            }
        }
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)
        let snapshot = await client.status()
        XCTAssertEqual(snapshot.status, .revoked)
        XCTAssertFalse(snapshot.status.isReady)
    }

    func testUnsupportedPlatformFailsClosed() async throws {
        let store = MemoryPairingStore()
        let server = FixtureHTTPServer { _ in
            FixtureResponse(status: 200, body: fixtureInfoBody())
        }
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(
            port: port,
            store: store,
            platformAllowsLocalAutomation: false
        )
        let snapshot = await client.status()
        XCTAssertEqual(snapshot.status, .unsupportedPlatform)
        let receipt = await client.deviceInfo(context: testContext())
        XCTAssertEqual(receipt.outcome, .notSent(.unsupportedPlatform))
        do {
            _ = try await client.pair(clientName: "Floe")
            XCTFail("pairing must be unavailable")
        } catch let error as IOSBridgeError {
            XCTAssertEqual(error, .unsupportedPlatform)
        }
        XCTAssertEqual(server.requestCount, 0)
    }

    func testLifecycleInvalidationFencesLateMutation() async throws {
        let clock = TestClock()
        let key = testKey(29)
        let expiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let store = MemoryPairingStore()
        try await seed(store, key: key, clock: clock)
        let server = FixtureHTTPServer { request in
            guard request.path == "/rpc" else {
                return FixtureResponse(status: 200, body: fixtureInfoBody())
            }
            guard let parsed = try? fixtureParseRPC(request, key: key) else {
                return fixtureError(400, code: "fixture_error", message: "bad rpc")
            }
            switch parsed.method {
            case "page_source":
                return rpcResponse(
                    request,
                    key: key,
                    result: .object(["bundle_id": .string("com.example.notes")])
                )
            case "tap":
                let response = rpcResponse(
                    request,
                    key: key,
                    result: .object(["message": .string("tapped")])
                )
                return FixtureResponse(
                    status: response.status,
                    headers: response.headers,
                    body: response.body,
                    delay: 0.8
                )
            case "config":
                return rpcResponse(
                    request,
                    key: key,
                    result: fixtureConfigResult(key: key, expiresAt: expiry)
                )
            default:
                return fixtureError(400, code: "fixture_error", message: "unexpected")
            }
        }
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)
        let task = Task {
            await client.tap(
                context: testContext(generation: 1),
                targetBundleID: "com.example.notes",
                x: 1,
                y: 2
            )
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if server.requests.contains(where: {
                (try? fixtureParseRPC($0, key: key).method) == "tap"
            }) {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await client.invalidate(reason: "test-background")
        let receipt = await task.value
        XCTAssertTrue(receipt.isOutcomeUnknown, "\(receipt)")
    }
}

final class TransportContractTests: XCTestCase {
    func testTransportRejectsOversizedResponseAndRequest() async throws {
        let server = FixtureHTTPServer { _ in
            FixtureResponse(status: 200, body: Data(repeating: 0x41, count: 2_048))
        }
        let port = try server.start()
        defer { server.stop() }
        let endpoint = try IOSBridgeEndpoint(port: port)
        let transport = IOSBridgeURLSessionTransport(maxRequestBytes: 1_024, maxResponseBytes: 1_024)
        do {
            _ = try await transport.send(
                IOSBridgeHTTPRequest(method: "GET", path: "/"),
                endpoint: endpoint,
                timeout: 3,
                cancellation: nil
            )
            XCTFail("oversized response should fail")
        } catch let error as IOSBridgeTransportError {
            XCTAssertEqual(error, .responseTooLarge(2_048))
        }

        let request = IOSBridgeHTTPRequest(
            method: "POST",
            path: "/rpc",
            body: Data(repeating: 0x42, count: 2_048)
        )
        do {
            _ = try await transport.send(
                request,
                endpoint: endpoint,
                timeout: 3,
                cancellation: nil
            )
            XCTFail("oversized request should fail")
        } catch let error as IOSBridgeTransportError {
            XCTAssertEqual(error, .requestTooLarge(2_048))
        }
    }

    func testEndpointPortValidationAndLoopbackURL() throws {
        XCTAssertThrowsError(try IOSBridgeEndpoint(port: 0))
        let endpoint = try IOSBridgeEndpoint(port: 8200)
        XCTAssertEqual(endpoint.host, "127.0.0.1")
        XCTAssertEqual(endpoint.baseURL.absoluteString, "http://127.0.0.1:8200")
        XCTAssertEqual(endpoint.url(forPath: "/rpc")?.absoluteString, "http://127.0.0.1:8200/rpc")
        XCTAssertNil(endpoint.url(forPath: "rpc"))
    }
}

extension ClientContractTests {
    func testPerCallAuthorityOverrideAndExecutionGates() async throws {
        let clock = TestClock()
        let key = testKey(30)
        let expiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let store = MemoryPairingStore()
        try await seed(store, key: key, clock: clock)
        let server = FixtureHTTPServer { request in
            guard request.path == "/rpc" else {
                return FixtureResponse(status: 200, body: fixtureInfoBody())
            }
            guard let parsed = try? fixtureParseRPC(request, key: key) else {
                return fixtureError(400, code: "fixture_error", message: "bad rpc")
            }
            switch parsed.method {
            case "page_source":
                return rpcResponse(
                    request,
                    key: key,
                    result: .object(["bundle_id": .string("com.example.notes")])
                )
            case "tap":
                return rpcResponse(
                    request,
                    key: key,
                    result: .object(["message": .string("tapped")])
                )
            case "config":
                return rpcResponse(
                    request,
                    key: key,
                    result: fixtureConfigResult(key: key, expiresAt: expiry)
                )
            default:
                return fixtureError(400, code: "fixture_error", message: "unexpected")
            }
        }
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(
            port: port,
            store: store,
            clock: clock,
            authority: DenyAllAuthority()
        )

        let authorityTaskID = UUID()
        let allowed = await client.tap(
            context: testContext(
                taskID: authorityTaskID,
                authorityOverride: AllowAllAuthority()
            ),
            targetBundleID: "com.example.notes",
            x: 1,
            y: 2
        )
        XCTAssertTrue(allowed.isSuccess, "\(allowed)")

        let denied = await client.tap(
            context: testContext(
                taskID: authorityTaskID,
                authorityOverride: DenyAllAuthority()
            ),
            targetBundleID: "com.example.notes",
            x: 1,
            y: 2
        )
        XCTAssertEqual(denied.outcome, .notSent(.authorityDenied(reason: "test denial")))

        let expiredWindow = IOSAutomationExecutionWindow.backgroundRun(
            startedAt: clock.now().addingTimeInterval(-30),
            deadline: clock.now().addingTimeInterval(-1)
        )
        let beforeWindow = server.requestCount
        let expired = await client.tap(
            context: testContext(window: expiredWindow),
            targetBundleID: "com.example.notes",
            x: 1,
            y: 2
        )
        XCTAssertEqual(expired.outcome, .notSent(.executionWindowExpired))
        XCTAssertEqual(server.requestCount, beforeWindow)

        let taskID = UUID()
        await client.registerTaskGeneration(2, for: taskID)
        let beforeStale = server.requestCount
        let stale = await client.tap(
            context: testContext(taskID: taskID, generation: 1),
            targetBundleID: "com.example.notes",
            x: 1,
            y: 2
        )
        XCTAssertEqual(stale.outcome, .notSent(.staleTaskGeneration))
        XCTAssertEqual(server.requestCount, beforeStale)
    }
}

extension ClientContractTests {
    private func ownershipServer(
        key: Data,
        expiry: Int,
        tapDelay: TimeInterval = 0
    ) -> FixtureHTTPServer {
        FixtureHTTPServer { request in
            guard request.path == "/rpc" else {
                return FixtureResponse(status: 200, body: fixtureInfoBody())
            }
            guard let parsed = try? fixtureParseRPC(request, key: key) else {
                return fixtureError(400, code: "fixture_error", message: "bad rpc")
            }
            switch parsed.method {
            case "page_source":
                return rpcResponse(
                    request,
                    key: key,
                    result: .object(["bundle_id": .string("com.example.notes")])
                )
            case "tap":
                let response = rpcResponse(
                    request,
                    key: key,
                    result: .object(["message": .string("tapped")])
                )
                return FixtureResponse(
                    status: response.status,
                    headers: response.headers,
                    body: response.body,
                    delay: tapDelay
                )
            case "config":
                return rpcResponse(
                    request,
                    key: key,
                    result: fixtureConfigResult(key: key, expiresAt: expiry)
                )
            default:
                return fixtureError(400, code: "fixture_error", message: "unexpected")
            }
        }
    }

    func testPersistentDeviceInputOwnershipAcrossCalls() async throws {
        let clock = TestClock()
        let key = testKey(31)
        let expiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let store = MemoryPairingStore()
        try await seed(store, key: key, clock: clock)
        let server = ownershipServer(key: key, expiry: expiry)
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)

        let taskA = UUID()
        let taskB = UUID()
        let first = await client.tap(
            context: testContext(taskID: taskA),
            targetBundleID: "com.example.notes",
            x: 1,
            y: 2
        )
        XCTAssertTrue(first.isSuccess, "\(first)")

        let owner = await client.currentDeviceInputOwner()
        XCTAssertEqual(owner?.taskID, taskA)
        XCTAssertEqual(owner?.taskGeneration, 1)

        let beforeB = server.requestCount
        let blocked = await client.tap(
            context: testContext(taskID: taskB),
            targetBundleID: "com.example.notes",
            x: 3,
            y: 4
        )
        XCTAssertEqual(blocked.outcome, .notSent(.inputBusy))
        XCTAssertEqual(server.requestCount, beforeB)

        let second = await client.tap(
            context: testContext(taskID: taskA),
            targetBundleID: "com.example.notes",
            x: 5,
            y: 6
        )
        XCTAssertTrue(second.isSuccess, "\(second)")

        let wrongTaskRelease = await client.releaseTaskOwnership(
            taskID: taskB,
            generation: 1
        )
        XCTAssertFalse(wrongTaskRelease)
        let staleRelease = await client.releaseTaskOwnership(
            taskID: taskA,
            generation: 2
        )
        XCTAssertFalse(staleRelease)
        let stillBlocked = await client.tap(
            context: testContext(taskID: taskB),
            targetBundleID: "com.example.notes",
            x: 7,
            y: 8
        )
        XCTAssertEqual(stillBlocked.outcome, .notSent(.inputBusy))

        let released = await client.releaseTaskOwnership(
            taskID: taskA,
            generation: 1
        )
        XCTAssertTrue(released)
        let afterOwnerRelease = await client.currentDeviceInputOwner()
        XCTAssertNil(afterOwnerRelease)
        let afterRelease = await client.tap(
            context: testContext(taskID: taskB),
            targetBundleID: "com.example.notes",
            x: 9,
            y: 10
        )
        XCTAssertTrue(afterRelease.isSuccess, "\(afterRelease)")
    }

    func testNewGenerationSupersedesOwnerAndStaleCannotReleaseSuccessor() async throws {
        let clock = TestClock()
        let key = testKey(32)
        let expiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let store = MemoryPairingStore()
        try await seed(store, key: key, clock: clock)
        let server = ownershipServer(key: key, expiry: expiry)
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)

        let taskA = UUID()
        let taskB = UUID()
        let first = await client.tap(
            context: testContext(taskID: taskA, generation: 1),
            targetBundleID: "com.example.notes",
            x: 1,
            y: 2
        )
        XCTAssertTrue(first.isSuccess)
        let firstOwner = await client.currentDeviceInputOwner()
        XCTAssertEqual(firstOwner?.taskGeneration, 1)

        await client.registerTaskGeneration(2, for: taskA)
        let afterNewGeneration = await client.currentDeviceInputOwner()
        XCTAssertNil(afterNewGeneration)

        let successor = await client.tap(
            context: testContext(taskID: taskA, generation: 2),
            targetBundleID: "com.example.notes",
            x: 3,
            y: 4
        )
        XCTAssertTrue(successor.isSuccess)

        let staleRelease = await client.releaseTaskOwnership(
            taskID: taskA,
            generation: 1
        )
        XCTAssertFalse(staleRelease)
        let successorOwner = await client.currentDeviceInputOwner()
        XCTAssertEqual(successorOwner?.taskGeneration, 2)
        let blocked = await client.tap(
            context: testContext(taskID: taskB),
            targetBundleID: "com.example.notes",
            x: 5,
            y: 6
        )
        XCTAssertEqual(blocked.outcome, .notSent(.inputBusy))

        let successorRelease = await client.releaseTaskOwnership(
            taskID: taskA,
            generation: 2
        )
        XCTAssertTrue(successorRelease)
        let afterRelease = await client.tap(
            context: testContext(taskID: taskB),
            targetBundleID: "com.example.notes",
            x: 7,
            y: 8
        )
        XCTAssertTrue(afterRelease.isSuccess)
    }

    func testBoundedWindowExpiresPersistentOwnership() async throws {
        let clock = TestClock()
        let key = testKey(33)
        let expiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let store = MemoryPairingStore()
        try await seed(store, key: key, clock: clock)
        let server = ownershipServer(key: key, expiry: expiry)
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)

        let taskA = UUID()
        let taskB = UUID()
        let window = IOSAutomationExecutionWindow.backgroundRun(
            startedAt: clock.now(),
            deadline: clock.now().addingTimeInterval(1)
        )
        let first = await client.tap(
            context: testContext(taskID: taskA, window: window),
            targetBundleID: "com.example.notes",
            x: 1,
            y: 2
        )
        XCTAssertTrue(first.isSuccess)
        let boundedOwner = await client.currentDeviceInputOwner()
        XCTAssertNotNil(boundedOwner)
        clock.advance(2)
        let expiredOwner = await client.currentDeviceInputOwner()
        XCTAssertNil(expiredOwner)
        let afterExpiry = await client.tap(
            context: testContext(taskID: taskB),
            targetBundleID: "com.example.notes",
            x: 3,
            y: 4
        )
        XCTAssertTrue(afterExpiry.isSuccess)

        // Lifecycle invalidation clears ownership immediately as well.
        let again = await client.tap(
            context: testContext(taskID: taskB),
            targetBundleID: "com.example.notes",
            x: 5,
            y: 6
        )
        XCTAssertTrue(again.isSuccess)
        await client.invalidate(reason: "test-ownership")
        let invalidatedOwner = await client.currentDeviceInputOwner()
        XCTAssertNil(invalidatedOwner)
        let afterInvalidate = await client.tap(
            context: testContext(taskID: UUID()),
            targetBundleID: "com.example.notes",
            x: 7,
            y: 8
        )
        XCTAssertTrue(afterInvalidate.isSuccess)
    }

    func testPreDispatchAuthorityDenialDoesNotStrandOwnership() async throws {
        let clock = TestClock()
        let key = testKey(34)
        let expiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let store = MemoryPairingStore()
        try await seed(store, key: key, clock: clock)
        let server = ownershipServer(key: key, expiry: expiry)
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)

        let denied = await client.tap(
            context: testContext(authorityOverride: DenyAllAuthority()),
            targetBundleID: "com.example.notes",
            x: 1,
            y: 2
        )
        XCTAssertEqual(denied.outcome, .notSent(.authorityDenied(reason: "test denial")))
        let strandedOwner = await client.currentDeviceInputOwner()
        XCTAssertNil(strandedOwner)
        let other = await client.tap(
            context: testContext(),
            targetBundleID: "com.example.notes",
            x: 3,
            y: 4
        )
        XCTAssertTrue(other.isSuccess)
    }
}

extension ClientContractTests {
    func testControlIsBlockedWhilePairing() async throws {
        let clock = TestClock()
        let key = testKey(36)
        let expiry = Int(clock.now().addingTimeInterval(30 * 24 * 60 * 60).timeIntervalSince1970)
        let store = MemoryPairingStore()
        let server = FixtureHTTPServer { request in
            switch request.path {
            case "/":
                return FixtureResponse(status: 200, body: fixtureInfoBody())
            case "/pair":
                do {
                    let response = try fixturePairResponse(
                        request,
                        key: key,
                        expireSeconds: expiry
                    )
                    return FixtureResponse(
                        status: response.status,
                        headers: response.headers,
                        body: response.body,
                        delay: 0.6
                    )
                } catch {
                    return fixtureError(500, code: "fixture_error", message: "\(error)")
                }
            case "/rpc":
                return rpcResponse(
                    request,
                    key: key,
                    result: fixtureConfigResult(key: key, expiresAt: expiry)
                )
            default:
                return fixtureError(404, code: "not_found", message: "missing")
            }
        }
        let port = try server.start()
        defer { server.stop() }
        let client = try makeClient(port: port, store: store, clock: clock)
        let pairTask = Task {
            try await client.pair(clientName: "Floe on iPhone")
        }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if server.requests.contains(where: { $0.path == "/pair" }) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let blocked = await client.tap(
            context: testContext(),
            targetBundleID: "com.example.notes",
            x: 1,
            y: 2
        )
        XCTAssertEqual(blocked.outcome, .notSent(.deviceBusy))
        let rpcMethods = server.requests.compactMap { request -> String? in
            guard request.path == "/rpc" else { return nil }
            return try? fixtureParseRPC(request, key: key).method
        }
        XCTAssertTrue(rpcMethods.isEmpty)
        _ = try await pairTask.value
        let owner = await client.currentDeviceInputOwner()
        XCTAssertNil(owner)
    }
}
