import XCTest
@testable import FloeAndroidCore

/// Deterministic H-layer source tests for the P2 save-intent vault. AUTHORED
/// ONLY: this source package does not compile or execute them. Fixed synthetic
/// bytes and synthetic UUID-like identities are used; no real credential or
/// provider endpoint is present.
final class SecretSaveIntentVaultTests: XCTestCase {
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 1_000
        var now: UInt64 {
            lock.lock(); defer { lock.unlock() }
            return value
        }
        func advance(_ milliseconds: UInt64) {
            lock.lock(); value += milliseconds; lock.unlock()
        }
    }

    private var clock: TestClock!
    private let providerID = "11111111-1111-1111-1111-111111111111"
    private let mcpID = "22222222-2222-2222-2222-222222222222"

    override func setUp() {
        super.setUp()
        _ = floeSecretGatewayRemove()
        SecretRequestMailbox.shared.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        let testClock = TestClock()
        clock = testClock
        SecretSaveIntentVault.shared.configureForTesting(clock: { testClock.now })
    }

    override func tearDown() {
        _ = floeSecretGatewayRemove()
        SecretRequestMailbox.shared.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        clock = nil
        super.tearDown()
    }

    // MARK: Intent builders / C ABI helpers

    private func makeIntent(kind: SubjectKind = .providerSave,
                            id: String = "11111111-1111-1111-1111-111111111111",
                            candidate: [String: Any]? = nil,
                            routeToken: String = "route-token-1",
                            generation: Int = 7,
                            baseRevision: [String: Any]? = nil,
                            extraTopLevel: [String: Any] = [:]) -> Data {
        var candidateObject = candidate ?? [
            "id": id,
            "name": "Provider A",
            "baseURL": "https://example.invalid/v1",
        ]
        candidateObject["id"] = candidateObject["id"] ?? id
        var object: [String: Any] = [
            "subject": ["kind": kind.rawValue, "id": id],
            "route": ["token": routeToken, "generation": generation],
            "intent": "set",
            "candidate": candidateObject,
        ]
        if let baseRevision { object["baseRevision"] = baseRevision }
        for (key, value) in extraTopLevel { object[key] = value }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func makeIntent(generationLiteral: String) -> Data {
        let json = """
        {"subject":{"kind":"providerSave","id":"\(providerID)"},"route":{"token":"route-token-1","generation":\(generationLiteral)},"intent":"set","candidate":{"id":"\(providerID)","name":"Boundary"}}
        """
        return Data(json.utf8)
    }

    @discardableResult
    private func submit(_ intent: Data, secret: Data = Data("synthetic-secret".utf8),
                        capacity: Int32 = 40) -> (Int32, String?) {
        var json = intent
        json.append(0)
        var token = [CChar](repeating: 0, count: 64)
        var status: Int32 = -1
        json.withUnsafeBytes { jsonRaw in
            secret.withUnsafeBytes { secretRaw in
                token.withUnsafeMutableBufferPointer { tokenBuffer in
                    status = floeSecretSaveIntentSubmit(
                        jsonRaw.bindMemory(to: CChar.self).baseAddress,
                        secretRaw.bindMemory(to: UInt8.self).baseAddress,
                        Int32(secret.count),
                        tokenBuffer.baseAddress,
                        capacity)
                }
            }
        }
        return (status, status == 0 ? String(cString: token) : nil)
    }

    private func submitOK(_ intent: Data, secret: Data = Data("synthetic-secret".utf8)) -> String {
        let (status, token) = submit(intent, secret: secret)
        XCTAssertEqual(status, 0)
        return token ?? ""
    }

    private func discard(_ token: String) -> Int32 {
        var bytes = Array(token.utf8).map { CChar(bitPattern: $0) }
        bytes.append(0)
        return bytes.withUnsafeBufferPointer { pointer in
            floeSecretSaveIntentDiscard(pointer.baseAddress)
        }
    }

    private func consume(_ token: String, routeToken: String = "route-token-1",
                         generation: UInt64 = 7,
                         subject: SubjectKind = .providerSave) throws -> SaveIntentLease {
        try SecretSaveIntentVault.shared.consume(
            token: token,
            route: RouteBinding(token: routeToken, generation: generation),
            expectedSubject: subject)
    }

    private func rejection<T>(_ body: () throws -> T) -> IntentRejection? {
        do {
            _ = try body()
            XCTFail("expected a typed intent rejection")
            return nil
        } catch let error as SecretBackendError {
            if case .intentRejected(let reason) = error { return reason }
            XCTFail("wrong error \(error)")
            return nil
        } catch {
            XCTFail("unexpected error \(error)")
            return nil
        }
    }

    private func stats() -> SecretSaveIntentVaultStats {
        SecretSaveIntentVault.shared.statsSnapshot()
    }

    // MARK: One-shot / lease

    func testSubmitConsumeLeaseAndOneShot() throws {
        let secret = Data("synthetic-secret-value".utf8)
        let (status, token) = submit(
            makeIntent(baseRevision: ["resourceID": "provider:1", "version": "rev-7"]),
            secret: secret)
        XCTAssertEqual(status, 0)
        let value = try XCTUnwrap(token)
        XCTAssertEqual(value.utf8.count, 39)
        XCTAssertTrue(value.hasPrefix("int:v1:"))
        XCTAssertEqual(value.filter { $0 == ":" }.count, 2)
        XCTAssertEqual(stats().intentsLive, 1)
        XCTAssertEqual(stats().leasesActive, 0)

        let lease = try consume(value)
        XCTAssertEqual(lease.subject, .providerSave)
        XCTAssertEqual(lease.baseRevision,
                       SaveIntentBaseRevision(resourceID: "provider:1", version: "rev-7"))
        XCTAssertEqual(lease.secret, secret)
        let candidate = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: lease.candidateJSON) as? [String: Any])
        XCTAssertEqual(candidate["name"] as? String, "Provider A")
        XCTAssertEqual(stats().intentsLive, 0)
        XCTAssertEqual(stats().leasesActive, 1)
        XCTAssertEqual(rejection { try consume(value) }, .consumed)
        XCTAssertTrue(lease.close())
        XCTAssertEqual(stats().leasesActive, 0)
        XCTAssertTrue(lease.candidateJSON.isEmpty)
        XCTAssertNil(lease.secret)
        XCTAssertEqual(rejection { try consume(value) }, .consumed)
    }

    func testValidationBoundsAndClosedSchema() {
        XCTAssertEqual(submit(Data("not-json".utf8)).0, -110)
        XCTAssertEqual(submit(makeIntent(extraTopLevel: ["unexpected": "value"])).0, -110)
        XCTAssertEqual(submit(Data(), secret: Data([0x01])).0, -110)
        XCTAssertEqual(submit(makeIntent(), secret: Data()).0, -115)
        XCTAssertEqual(submit(makeIntent(), secret: Data(repeating: 0x41, count: 65_537)).0, -111)

        let largeName = String(repeating: "a", count: 17_000)
        let large = makeIntent(candidate: ["id": providerID, "name": largeName])
        XCTAssertGreaterThan(large.count, 16_384)
        XCTAssertEqual(submit(large).0, -116)

        var mismatch: [String: Any] = [
            "subject": ["kind": SubjectKind.providerSave.rawValue, "id": providerID],
            "route": ["token": "route-token-1", "generation": 7],
            "intent": "set",
            "candidate": ["id": "different-identity", "name": "Mismatch"],
        ]
        let mismatchData = try! JSONSerialization.data(withJSONObject: mismatch)
        XCTAssertEqual(submit(mismatchData).0, -110)
        mismatch["candidate"] = ["id": providerID, "providerID": "provider.x", "name": "MCP"]
        mismatch["subject"] = ["kind": SubjectKind.mcpSave.rawValue, "id": providerID]
        let mcpData = try! JSONSerialization.data(withJSONObject: mismatch)
        XCTAssertEqual(submit(mcpData).0, -110)

        var ids = Set<String>()
        for index in 0..<4 {
            let id = String(format: "33333333-3333-3333-3333-33333333333%d", index)
            let token = submitOK(makeIntent(id: id, candidate: ["id": id, "name": "Slot \(index)"]))
            ids.insert(token)
        }
        XCTAssertEqual(ids.count, 4)
        XCTAssertEqual(submit(makeIntent(id: "44444444-4444-4444-4444-444444444444")).0, -112)
        XCTAssertEqual(stats().intentsLive, 4)
    }

    func testGenerationSchemaRejectsBooleansFractionsNegativesAndOverflow() {
        for literal in ["true", "false", "-1", "1.5", "18446744073709551616"] {
            XCTAssertEqual(submit(makeIntent(generationLiteral: literal)).0, -110,
                           "generation literal \(literal) must be rejected")
        }
        XCTAssertEqual(submit(makeIntent(generationLiteral: "0")).0, 0)
        XCTAssertEqual(submit(makeIntent(generationLiteral: "7")).0, 0)
        XCTAssertEqual(stats().intentsLive, 2)
    }

    func testGenerationNumberValidationPreservesExactUIntegerValues() {
        let vault = SecretSaveIntentVault.shared
        XCTAssertEqual(vault.parseGenerationForTesting(NSNumber(value: 0)), 0)
        XCTAssertEqual(vault.parseGenerationForTesting(NSNumber(value: 1)), 1)
        XCTAssertEqual(vault.parseGenerationForTesting(NSNumber(value: UInt64.max)),
                       UInt64.max)
        XCTAssertNil(vault.parseGenerationForTesting(NSNumber(value: true)))
        XCTAssertNil(vault.parseGenerationForTesting(NSNumber(value: false)))
        XCTAssertNil(vault.parseGenerationForTesting(NSNumber(value: -1)))
        XCTAssertNil(vault.parseGenerationForTesting(NSNumber(value: 1.5)))
        XCTAssertNil(vault.parseGenerationForTesting(NSNumber(value: Double.infinity)))
    }

    func testSubjectAndRouteMismatchConsumeTheSlot() throws {
        let providerToken = submitOK(makeIntent())
        XCTAssertEqual(rejection { try consume(providerToken, subject: .mcpSave) },
                       .subjectMismatch)
        XCTAssertEqual(rejection { try consume(providerToken) }, .consumed)

        let routeToken = submitOK(makeIntent(id: providerID,
                                             candidate: ["id": providerID, "name": "Route"]))
        XCTAssertEqual(rejection { try consume(routeToken, routeToken: "other-route") },
                       .routeMismatch)
        XCTAssertEqual(rejection { try consume(routeToken) }, .consumed)
    }

    func testLiveTTLExpiryAndDiscard() throws {
        let token = submitOK(makeIntent())
        clock.advance(SecretSaveIntentLimits.liveSlotTTLMillis + 1)
        SecretSaveIntentVault.shared.sweepExpired(at: clock.now)
        XCTAssertEqual(stats().intentsLive, 0)
        XCTAssertEqual(rejection { try consume(token) }, .expired)

        let discarded = submitOK(makeIntent(id: "55555555-5555-5555-5555-555555555555"))
        XCTAssertEqual(discard(discarded), 0)
        XCTAssertEqual(stats().intentsLive, 0)
        XCTAssertEqual(rejection { try consume(discarded) }, .unknownToken)
        XCTAssertEqual(discard(discarded), 0)
        XCTAssertEqual(discard("not-a-token"), -105)
    }

    // MARK: ACTIVE lease lifetime / exact close

    func testActiveAdmissionsNoTTLAndExactOnceClose() throws {
        var leases: [SaveIntentLease] = []
        for index in 0..<4 {
            let id = String(format: "66666666-6666-6666-6666-66666666666%d", index)
            let token = submitOK(makeIntent(id: id, candidate: ["id": id, "name": "Active \(index)"]))
            leases.append(try consume(token))
        }
        XCTAssertEqual(stats().leasesActive, 4)
        clock.advance(10_000_000)
        SecretSaveIntentVault.shared.sweepExpired(at: clock.now)
        XCTAssertEqual(stats().leasesActive, 4, "ACTIVE admissions have NO TTL")

        let fifthID = "77777777-7777-7777-7777-777777777777"
        let fifthToken = submitOK(makeIntent(id: fifthID, candidate: ["id": fifthID, "name": "Fifth"]))
        XCTAssertEqual(rejection { try consume(fifthToken) }, .intentSaturated)
        XCTAssertEqual(stats().leasesActive, 4)
        XCTAssertEqual(stats().intentsLive, 0)

        SecretSaveIntentVault.shared.setFailNextCloseForTesting()
        XCTAssertFalse(leases[0].close())
        XCTAssertEqual(stats().leasesActive, 4)
        XCTAssertEqual(stats().leasesCloseFailed, 1)
        XCTAssertTrue(leases[0].close(), "failed close is retryable and frees exactly one")
        XCTAssertEqual(stats().leasesActive, 3)
        XCTAssertTrue(leases[1].close())
        XCTAssertEqual(stats().leasesActive, 2)

        let sixthID = "88888888-8888-8888-8888-888888888888"
        let sixthToken = submitOK(makeIntent(id: sixthID, candidate: ["id": sixthID, "name": "Sixth"]))
        let sixth = try consume(sixthToken)
        XCTAssertEqual(stats().leasesActive, 3)
        XCTAssertTrue(sixth.close())
        XCTAssertEqual(stats().leasesActive, 2)
    }

    // MARK: Frozen candidate / identity / hygiene

    func testDelayedFieldEditCannotChangeFrozenCandidate() throws {
        var object: [String: Any] = [
            "subject": ["kind": SubjectKind.providerSave.rawValue, "id": providerID],
            "route": ["token": "route-token-1", "generation": 7],
            "intent": "set",
            "candidate": ["id": providerID, "name": "Original Name"],
        ]
        let original = try JSONSerialization.data(withJSONObject: object)
        let token = submitOK(original)
        object["candidate"] = ["id": providerID, "name": "Edited After Save Tap"]
        let edited = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNotEqual(original, edited)
        let lease = try consume(token)
        let frozen = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: lease.candidateJSON) as? [String: Any])
        XCTAssertEqual(frozen["name"] as? String, "Original Name")
        XCTAssertTrue(lease.close())
    }

    func testIngressTokenCapacityAndIdentityLengths() throws {
        let intent = makeIntent()
        XCTAssertEqual(submit(intent, capacity: 39).0, -105, "capacity 39 cannot hold 39+NUL")
        XCTAssertEqual(stats().intentsLive, 0)
        let (status, token) = submit(intent, capacity: 40)
        XCTAssertEqual(status, 0)
        let value = try XCTUnwrap(token)
        XCTAssertEqual(value.utf8.count, 39)
        XCTAssertTrue(value.utf8.dropFirst(7).allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
        })

        let account = "mcp.6F1C2D3E-0000-0000-0000-000000000000.https.example.invalid.443"
        let providerRef = SecretGatewayNaming.opaqueReference(namespace: "keychainAccount",
                                                               account: account)
        let mcpRef = SecretGatewayNaming.opaqueReference(namespace: "org.floeagent.ios.mcp",
                                                          account: account)
        XCTAssertEqual(providerRef.utf8.count, 71)
        XCTAssertEqual(mcpRef.utf8.count, 71)
        XCTAssertEqual(providerRef.count, 71)
        XCTAssertEqual(mcpRef.count, 71)
        XCTAssertNotEqual(providerRef, mcpRef)
        XCTAssertEqual(mcpRef,
                       SecretGatewayNaming.opaqueReference(namespace: "org.floeagent.ios.mcp",
                                                           account: account))
        XCTAssertTrue(SecretGatewayIdentity.isCanonicalReference(providerRef))
        XCTAssertFalse(SecretGatewayIdentity.isCanonicalReference(providerRef + "0"))
        XCTAssertFalse(SecretGatewayIdentity.isCanonicalReference(
            "ref:v1:" + String(repeating: "A", count: 64)))
        XCTAssertTrue(SecretGatewayIdentity.isCanonicalIngressToken(value))
        XCTAssertFalse(SecretGatewayIdentity.isCanonicalIngressToken(value + "0"))
    }

    func testTokensAreNotValueDerived() {
        let intent = makeIntent()
        let first = submitOK(intent)
        let second = submitOK(intent)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.utf8.count, 39)
        XCTAssertEqual(second.utf8.count, 39)
    }

    func testStatsAndMailboxDiagnosticsNeverContainCandidateOrSecret() throws {
        let secret = Data("s3cr3t-value-never-in-diagnostics".utf8)
        let token = submitOK(makeIntent(candidate: [
            "id": providerID,
            "name": "Sensitive Display Name",
            "baseURL": "https://user:password@example.invalid/v1",
        ]), secret: secret)
        let vaultStats = stats()
        XCTAssertEqual(vaultStats.intentsLive, 1)
        let nativeStats = SecretRequestMailbox.shared.statsJSON()
        for forbidden in ["Sensitive Display Name", "user:password", "example.invalid",
                          "s3cr3t-value", token, "ref:v1:"] {
            XCTAssertFalse(nativeStats.contains(forbidden))
        }
        XCTAssertTrue(nativeStats.contains("\"intentsLive\":1"))
        let lease = try consume(token)
        XCTAssertTrue(lease.close())
    }

    func testMCPSubjectRoundTripAndIsolation() throws {
        let candidate: [String: Any] = [
            "id": mcpID,
            "name": "MCP Server",
            "url": "https://mcp.example.invalid",
            "transport": "https",
        ]
        let intent = makeIntent(kind: .mcpSave, id: mcpID, candidate: candidate,
                                routeToken: "route-mcp", generation: 9)
        let token = submitOK(intent)
        let lease = try consume(token, routeToken: "route-mcp", generation: 9,
                                subject: .mcpSave)
        XCTAssertEqual(lease.subject, .mcpSave)
        XCTAssertEqual(lease.secret, Data("synthetic-secret".utf8))
        let frozen = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: lease.candidateJSON) as? [String: Any])
        XCTAssertEqual(frozen["id"] as? String, mcpID)
        XCTAssertTrue(lease.close())
    }
}
