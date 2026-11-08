import Foundation
import XCTest
import Crypto
@testable import FloeSkills

final class GitHubTransportMirrorManifestTests: XCTestCase, @unchecked Sendable {
    private let key = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 42, count: 32))
    private var mode: CuratedSkillTrustMode { .fixtureTestOnly(fixturePublicKey: key.publicKey.rawRepresentation) }
    private let now = ISO8601DateFormatter().date(from: "2026-11-08T11:00:00Z")!
    private var root: URL!

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        func get() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ value: Date) { lock.lock(); self.value = value; lock.unlock() }
    }
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var starters: [CheckedContinuation<Void, Never>] = []
        private(set) var count = 0
        private var cancelSeen = false
        private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
        func noteCancellation() {
            cancelSeen = true; cancelWaiters.forEach { $0.resume() }; cancelWaiters = []
        }
        func cancellationStarted() async {
            if cancelSeen { return }
            await withCheckedContinuation { cancelWaiters.append($0) }
        }
        func wait() async {
            count += 1
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                starters.forEach { $0.resume() }; starters = []
            }
        }
        func started() async {
            if count > 0 { return }
            await withCheckedContinuation { starters.append($0) }
        }
        func open() { continuation?.resume(); continuation = nil }
    }

    override func setUpWithError() throws {
        let scratch = ProcessInfo.processInfo.environment["FLOE_TEST_SCRATCH"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        root = scratch.appendingPathComponent("mirror-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func value(_ generation: Int64 = 1) -> [String: Any] {
        ["schemaVersion": 1, "purpose": "floe-github-transport-mirrors", "generation": generation,
         "issuedAt": "2026-11-08T10:00:00Z", "expiresAt": "2026-11-15T10:00:00Z",
         "roles": ["rawFiles": ["ghfast.top", "gh-proxy.com"], "atom": ["gh-proxy.com"], "releaseAssets": []]]
    }
    private func bytes(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) + Data([10])
    }
    private func signed(_ payload: Data, domain: Data = GitHubTransportMirrorManifest.domain)
        throws -> GitHubTransportMirrorPolicyStore.Downloaded {
        let signature = try key.signature(for: domain + payload)
        let envelope = try JSONSerialization.data(withJSONObject: ["keyID": CuratedSkillHub.fixtureKeyID,
            "signature": signature.base64EncodedString()], options: [.sortedKeys])
        return .init(payload: payload, signature: envelope)
    }
    private func pair(_ generation: Int64 = 1) throws -> GitHubTransportMirrorPolicyStore.Downloaded {
        try signed(bytes(value(generation)))
    }
    private func verify(_ pair: GitHubTransportMirrorPolicyStore.Downloaded) throws -> GitHubTransportMirrorManifest.Verified {
        try GitHubTransportMirrorManifest.verify(payload: pair.payload, signature: pair.signature, now: now, mode: mode)
    }
    private func store(_ clock: Clock, path: URL? = nil) -> GitHubTransportMirrorPolicyStore {
        GitHubTransportMirrorPolicyStore(persistenceURL: path ?? root.appendingPathComponent("state.json"),
                                        mode: mode, clock: { clock.get() })
    }
    private func refresh(_ store: GitHubTransportMirrorPolicyStore, _ pair: GitHubTransportMirrorPolicyStore.Downloaded) async {
        _ = await store.policyRefreshingIfNeeded { pair }
        await store.waitForRefresh()
    }

    func testCanonicalDomainSeparatedProofAndCompiledProductionTrust() throws {
        let pair = try pair()
        let verified = try verify(pair)
        XCTAssertEqual(verified.manifest.roles, .bundled)
        XCTAssertEqual(try verified.manifest.canonicalBytes(), pair.payload)
        XCTAssertThrowsError(try GitHubTransportMirrorManifest.verify(payload: pair.payload, signature: pair.signature, now: now))
        XCTAssertThrowsError(try verify(signed(pair.payload, domain: Data())))
        var changed = pair.payload; changed.append(10)
        XCTAssertThrowsError(try verify(.init(payload: changed, signature: pair.signature)))
    }

    func testPythonProducerGoldenSignatureInteroperates() throws {
        // Public-knowledge test seed 42, fixture-only trust, never production.
        let payload = Data("{\"expiresAt\":\"2026-11-15T10:00:00Z\",\"generation\":1,\"issuedAt\":\"2026-11-08T10:00:00Z\",\"purpose\":\"floe-github-transport-mirrors\",\"roles\":{\"atom\":[\"gh-proxy.com\"],\"rawFiles\":[\"ghfast.top\",\"gh-proxy.com\"],\"releaseAssets\":[]},\"schemaVersion\":1}\n".utf8)
        let envelope = Data("{\"keyID\":\"fixture-only-2026-10\",\"signature\":\"MCVLdl3hJJrJKgmezFgcAEkbjAF9dK7iN8TCeTqM7CB8Hcd9szRDKbWycyWZm93vUnYgSiztqfClpwlF7A0jBA==\"}".utf8)
        let verified = try verify(.init(payload: payload, signature: envelope))
        XCTAssertEqual(verified.manifest.generation, 1)
        XCTAssertEqual(try verified.manifest.canonicalBytes(), payload)
    }

    func testBoundsAndSignedNoncanonicalRepresentationsRefused() throws {
        let payload = try pair().payload
        for altered in [Data([239, 187, 191]) + payload, payload + Data([10]),
                        Data("{\"schemaVersion\":1,\"schemaVersion\":1,".utf8) + payload.dropFirst(),
                        payload.replacingOccurrences(of: Data("\"generation\":1".utf8), with: Data("\"generation\":1.0".utf8))] {
            XCTAssertThrowsError(try verify(signed(altered)))
        }
        XCTAssertThrowsError(try verify(.init(payload: Data(repeating: 32, count: 16385), signature: Data([1]))))
        XCTAssertThrowsError(try verify(.init(payload: payload, signature: Data(repeating: 32, count: 8193))))
    }

    func testExactFieldsRolesAndIntegerLimits() throws {
        var variants: [[String: Any]] = []
        for invalid: Any in [true, 0, -1, Int64(9_007_199_254_740_992)] {
            var v = value(); v["generation"] = invalid; variants.append(v)
        }
        var v = value(); v["schemaVersion"] = true; variants.append(v)
        v = value(); v["url"] = "https://example.invalid"; variants.append(v)
        v = value(); v["purpose"] = "floe-skill-catalog"; variants.append(v)
        for roles: [String: Any] in [
            ["rawFiles": ["unapproved.invalid"], "atom": [], "releaseAssets": []],
            ["rawFiles": ["ghfast.top", "ghfast.top"], "atom": [], "releaseAssets": []],
            ["rawFiles": [], "atom": [], "releaseAssets": [], "url": []],
            ["rawFiles": [], "atom": []],
        ] { v = value(); v["roles"] = roles; variants.append(v) }
        for variant in variants { XCTAssertThrowsError(try verify(signed(bytes(variant)))) }
        XCTAssertEqual(try verify(pair(GitHubTransportMirrorManifest.maximumGeneration)).manifest.generation,
                       GitHubTransportMirrorManifest.maximumGeneration)
    }

    func testStrictUTCTimeSkewExpiryAndValidity() throws {
        for (field, bad) in [
            ("issuedAt", "2026-11-08T11:05:01Z"), ("issuedAt", "2026-11-08T10:00:00+00:00"),
            ("issuedAt", "2026-11-08T10:00:00.000Z"), ("issuedAt", "2026-02-30T10:00:00Z"),
            ("expiresAt", "2026-11-08T11:00:00Z"), ("expiresAt", "2026-12-09T10:00:01Z"),
            ("expiresAt", "2026-11-08T09:59:59Z"),
        ] { var v = value(); v[field] = bad; XCTAssertThrowsError(try verify(signed(bytes(v)))) }
        var v = value(); v["issuedAt"] = "2026-11-08T11:05:00Z"
        XCTAssertNoThrow(try verify(signed(bytes(v))))
    }

    func testDurableReloadAndRejectedRollbackPreserveExactRecord() async throws {
        let clock = Clock(now); let store = store(clock); let path = root.appendingPathComponent("state.json")
        await refresh(store, try pair(3))
        let before = try Data(contentsOf: path)
        let reloaded = self.store(clock); let loaded = await reloaded.snapshot()
        XCTAssertEqual(loaded.highestGeneration, 3); XCTAssertEqual(loaded.generation, 3)
        clock.set(now.addingTimeInterval(7 * 3600)); await refresh(store, try pair(2))
        let result = await store.snapshot()
        XCTAssertEqual(result.generation, 3); XCTAssertEqual(result.diagnostic, .rollback)
        XCTAssertEqual(try Data(contentsOf: path), before)
    }

    func testSameGenerationChangedContentRefusedIdenticalRefreshNoop() async throws {
        let clock = Clock(now); let store = store(clock); let path = root.appendingPathComponent("state.json")
        let original = try pair(3); await refresh(store, original); let saved = try Data(contentsOf: path)
        var v = value(3); v["roles"] = ["rawFiles": [], "atom": [], "releaseAssets": []]
        clock.set(now.addingTimeInterval(7 * 3600)); await refresh(store, try signed(bytes(v)))
        let rejected = await store.snapshot(); XCTAssertEqual(rejected.diagnostic, .generationReused)
        XCTAssertEqual(try Data(contentsOf: path), saved)
        clock.set(now.addingTimeInterval(14 * 3600)); await refresh(store, original)
        let unchanged = await store.snapshot(); XCTAssertNil(unchanged.diagnostic)
        XCTAssertEqual(try Data(contentsOf: path), saved)
    }

    func testExpiredCacheRetainsFloorAndUsesDefaultsThenHigherGeneration() async throws {
        let clock = Clock(now); let store = store(clock); await refresh(store, try pair(3))
        clock.set(now.addingTimeInterval(12 * 86400))
        let restarted = self.store(clock); let expired = await restarted.snapshot()
        XCTAssertTrue(expired.usesBundledDefaults); XCTAssertEqual(expired.highestGeneration, 3)
        var lower = value(2); lower["issuedAt"] = "2026-11-20T10:00:00Z"; lower["expiresAt"] = "2026-11-27T10:00:00Z"
        await refresh(restarted, try signed(bytes(lower)))
        let rejected = await restarted.snapshot(); XCTAssertEqual(rejected.diagnostic, .rollback)
        clock.set(clock.get().addingTimeInterval(7 * 3600)); lower["generation"] = 4
        lower["roles"] = ["rawFiles": [], "atom": [], "releaseAssets": []]
        await refresh(restarted, try signed(bytes(lower)))
        let advanced = await restarted.snapshot()
        XCTAssertEqual(advanced.highestGeneration, 4); XCTAssertFalse(advanced.usesBundledDefaults)
        XCTAssertTrue(advanced.roles.rawFiles.isEmpty)
    }

    func testCorruptCacheIsPreservedAndCannotResetFloorByOverwrite() async throws {
        let path = root.appendingPathComponent("state.json"); let corrupted = Data("partial record".utf8)
        try corrupted.write(to: path); let store = self.store(Clock(now)); await refresh(store, try pair())
        let result = await store.snapshot(); XCTAssertTrue(result.usesBundledDefaults); XCTAssertEqual(result.diagnostic, .storage)
        XCTAssertEqual(try Data(contentsOf: path), corrupted)
    }

    func testInvalidProofAndStorageFailureNeverActivateCandidate() async throws {
        let clock = Clock(now); let store = store(clock); await refresh(store, try pair(3))
        clock.set(now.addingTimeInterval(7 * 3600)); let wrong = try signed(bytes(value(4)), domain: Data())
        await refresh(store, wrong); let existing = await store.snapshot()
        XCTAssertEqual(existing.generation, 3); XCTAssertEqual(existing.diagnostic, .signature)
        let blocker = root.appendingPathComponent("file"); try Data([1]).write(to: blocker)
        let failing = self.store(clock, path: blocker.appendingPathComponent("state.json"))
        await refresh(failing, try pair(4)); let rejected = await failing.snapshot()
        XCTAssertTrue(rejected.usesBundledDefaults); XCTAssertEqual(rejected.highestGeneration, 0)
        XCTAssertEqual(rejected.diagnostic, .storage)
    }

    func testSingleServiceOwnedFlightSixHourRefreshAndCancellationFence() async throws {
        let clock = Clock(now); let store = store(clock); let gate = Gate(); let late = try pair(10)
        _ = await store.policyRefreshingIfNeeded {
            await withTaskCancellationHandler { await gate.wait() }
                onCancel: { Task { await gate.noteCancellation() } }
            return late
        }
        await gate.started()
        _ = await store.policyRefreshingIfNeeded { XCTFail("duplicate in-flight download"); return late }
        let count = await gate.count; XCTAssertEqual(count, 1)
        let cancellation = Task { await store.cancelRefresh() }
        await gate.cancellationStarted(); await gate.open(); await cancellation.value
        clock.set(now.addingTimeInterval(7 * 3600)); await refresh(store, try pair(3))
        let result = await store.snapshot(); XCTAssertEqual(result.highestGeneration, 3)
        _ = await store.policyRefreshingIfNeeded { XCTFail("six-hour guard bypassed"); return late }
        await store.waitForRefresh()
    }
}

private extension Data {
    func replacingOccurrences(of old: Data, with replacement: Data) -> Data {
        var value = self
        if let range = value.range(of: old) { value.replaceSubrange(range, with: replacement) }
        return value
    }
}
