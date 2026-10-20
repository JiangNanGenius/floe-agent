// SPDX-License-Identifier: MPL-2.0
//
// G02 trusted host secure-ingress qualification.
//
// Component coverage (scripted epoch / slot-lifetime branches) AND actual
// bootstrap coverage over the REAL accepted generation, the RECORDED
// AndroidBridge V3 ingress and the ORIGINAL provider save chain:
//
//  * route admission asserts the native Root epoch the App captured at
//    editor creation (stale/foreign Root refuses without mutating);
//  * the shared UI generation is monotonic: idempotent for the same live
//    editor incarnation, refused for an older one, and a genuinely newer
//    editor takes the ONE live route;
//  * the frozen intent core never carries a route: the native seam injects
//    the live pair under the same lock that proves epoch + ownership;
//  * close/retire discard ONLY that route's UNCONSUMED live vault intents
//    and never an ACTIVE lease;
//  * a REAL V3 `config.provider.save` Set (subject/candidate/baseRevision
//    frozen in the lease) commits through the original store + a synthetic
//    typed gateway, and `config.providers.list` reads back the persisted
//    provider with its canonical opaque secret reference;
//  * Root retirement refuses a later open/submit and sweeps its live intent.
import XCTest
import Foundation
import FloeCore
import FloeModels
@testable import FloeAndroidCore

final class G02HostSecureIngressTests: XCTestCase {

    private var tracked: [Boot] = []
    private var registryWasRegistered = false

    // MARK: - Fixtures

    private final class Boot: @unchecked Sendable {
        let epoch: UInt64
        let token: String
        let rootPath: String
        var retired = false
        init(epoch: UInt64, token: String, rootPath: String) {
            self.epoch = epoch
            self.token = token
            self.rootPath = rootPath
        }
    }

    private enum FixtureEpoch {
        nonisolated(unsafe) static var lock = NSLock()
        nonisolated(unsafe) static var value: UInt64 =
            UInt64(DispatchTime.now().uptimeNanoseconds)
        static func allocate() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            let now = UInt64(DispatchTime.now().uptimeNanoseconds)
            value = Swift.max(value &+ 1, now)
            return value
        }
    }

    /// Synthetic typed gateway (never a real key): records the exact
    /// reference/value the original secret store writes so the test can
    /// prove the LOGICAL account binding of a real committed provider row.
    private actor SyntheticSecretGateway: AndroidSecretGateway {
        private var values: [String: Data] = [:]
        private(set) var writes: [(reference: String, value: Data)] = []

        func read(reference: String) async throws -> Data? { values[reference] }
        func write(reference: String, value: Data) async throws {
            values[reference] = value
            writes.append((reference, value))
        }
        func delete(reference: String) async throws { values.removeValue(forKey: reference) }
    }

    override func setUp() {
        super.setUp()
        let registry = SecretGatewayRegistry.shared
        registryWasRegistered = registry.isRegistered
        if registryWasRegistered { registry.unregister() }
        SecretSaveIntentVault.shared.resetForTesting()
        G02RuntimeComposition.shared.routeContext.resetRouteForTesting()
    }

    override func tearDown() async throws {
        for boot in tracked.reversed() where !boot.retired {
            await G02HostSecureIngressTests.shutdownEpoch(boot)
        }
        tracked.removeAll()
        G02RuntimeComposition.shared.routeContext.resetRouteForTesting()
        G02RuntimeComposition.shared.resetForTesting()
        AndroidRuntimeBootstrap.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        let registry = SecretGatewayRegistry.shared
        if registry.isRegistered { registry.unregister() }
        try await super.tearDown()
    }

    // MARK: - Closed intent helpers

    private func providerCandidate(providerID: UUID, modelID: UUID,
                                   displayName: String = "Floe G02 QA") throws -> [String: Any] {
        let model = ModelProfile(
            id: modelID,
            providerID: providerID,
            remoteModelID: "deepseek-flash",
            displayName: "DeepSeek Flash",
            limits: ModelLimits(contextTokens: 64_000, maxOutputTokens: 8_192),
            capabilities: [.text, .tools, .approval],
            reasoningEffort: nil,
            isEnabled: true,
            isHiddenFromPrimaryPicker: false)
        let encoded = try JSONEncoder().encode(model)
        let modelObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        return [
            "id": providerID.uuidString,
            "kind": "custom",
            "wireProtocol": "openai-chat-completions",
            "baseURL": "https://example.invalid/v1",
            "displayName": displayName,
            "nonSecretHeaders": [String: String](),
            "isEnabled": true,
            "allowsPlainHTTP": false,
            "toolNameCompatibility": false,
            "syncEnabled": false,
            "serviceRoleIsConversation": true,
            "selectedModels": [modelObject],
            "managedCapabilities": ModelCapabilities([.text, .tools, .approval]).rawValue,
            "createIntent": true,
        ]
    }

    private func intentCore(subjectKind: String, subjectID: String,
                            candidate: [String: Any],
                            baseRevision: [String: Any]? = nil) -> Data {
        var core: [String: Any] = [
            "subject": ["kind": subjectKind, "id": subjectID],
            "intent": "set",
            "candidate": candidate,
        ]
        if let baseRevision { core["baseRevision"] = baseRevision }
        return try! JSONSerialization.data(withJSONObject: core, options: [.sortedKeys])
    }

    private func canonicalJSON(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: - Component: admission clauses

    func testOpenAssertsCapturedNativeEpochAndNeverMutatesOnRefusal() {
        let registry = G02HostRouteContextProvider()
        registry.configureEpochForTesting { 31 }
        let first = registry.openEditorRoute(editorKind: "provider", editorID: "editor-A",
                                             uiGeneration: 9,
                                             expectedNativeRootEpoch: 31)
        let route = try! XCTUnwrap(first)
        XCTAssertTrue(G02HostRouteContextProvider.isCanonicalRouteToken(route.token))
        XCTAssertEqual(registry.currentRoute(), route)

        // Stale native Root (the App captured an older epoch) -> no mutation.
        XCTAssertNil(registry.openEditorRoute(editorKind: "provider", editorID: "editor-B",
                                              uiGeneration: 10,
                                              expectedNativeRootEpoch: 30))
        XCTAssertEqual(registry.currentRoute(), route)
        // Foreign/late Root with a *newer* UI generation still refuses.
        XCTAssertNil(registry.openEditorRoute(editorKind: "mcp", editorID: "editor-B",
                                              uiGeneration: 11,
                                              expectedNativeRootEpoch: 99))
        XCTAssertEqual(registry.currentRoute(), route)
        // Invalid shape never mutates either.
        XCTAssertNil(registry.openEditorRoute(editorKind: "unknown", editorID: "editor-A",
                                              uiGeneration: 12, expectedNativeRootEpoch: 31))
        XCTAssertNil(registry.openEditorRoute(editorKind: "provider", editorID: "",
                                              uiGeneration: 12, expectedNativeRootEpoch: 31))
        XCTAssertNil(registry.openEditorRoute(editorKind: "provider", editorID: "editor-A",
                                              uiGeneration: 0, expectedNativeRootEpoch: 31))
        XCTAssertEqual(registry.currentRoute(), route)
    }

    func testSharedUiGenerationIsMonotonicIdempotentAndSingleRoute() {
        let registry = G02HostRouteContextProvider()
        registry.configureEpochForTesting { 31 }
        let a = try! XCTUnwrap(registry.openEditorRoute(
            editorKind: "provider", editorID: "editor-A",
            uiGeneration: 9, expectedNativeRootEpoch: 31))
        // Same incarnation -> the SAME handle (idempotent, no replacement).
        let repeated = try! XCTUnwrap(registry.openEditorRoute(
            editorKind: "provider", editorID: "editor-A",
            uiGeneration: 9, expectedNativeRootEpoch: 31))
        XCTAssertEqual(a, repeated)
        // Older incarnation -> refused; newer editor -> takes the live route.
        XCTAssertNil(registry.openEditorRoute(editorKind: "provider", editorID: "editor-A",
                                              uiGeneration: 8, expectedNativeRootEpoch: 31))
        let b = try! XCTUnwrap(registry.openEditorRoute(
            editorKind: "mcp", editorID: "editor-B",
            uiGeneration: 10, expectedNativeRootEpoch: 31))
        XCTAssertNotEqual(a.token, b.token)
        XCTAssertEqual(registry.currentRoute(), b)
        // The older editor's late close can never clear the newer binding.
        XCTAssertTrue(registry.clearEditorRoute(token: a.token))
        XCTAssertEqual(registry.currentRoute(), b)
        // Same generation for a different editor id is a refusal.
        XCTAssertNil(registry.openEditorRoute(editorKind: "provider", editorID: "editor-C",
                                              uiGeneration: 10, expectedNativeRootEpoch: 31))
        XCTAssertTrue(registry.clearEditorRoute(token: b.token))
        XCTAssertNil(registry.currentRoute())
        // A resurrected old incarnation cannot be re-admitted after close.
        XCTAssertNil(registry.openEditorRoute(editorKind: "provider", editorID: "editor-A",
                                              uiGeneration: 9, expectedNativeRootEpoch: 31))
    }

    func testSubjectsAreBoundToTheEditorKindAndCoreCannotCarryRoute() throws {
        let registry = G02HostRouteContextProvider()
        registry.configureEpochForTesting { 31 }
        let route = try XCTUnwrap(registry.openEditorRoute(
            editorKind: "provider", editorID: "editor-A",
            uiGeneration: 5, expectedNativeRootEpoch: 31))
        let providerID = UUID()
        let modelID = UUID()
        let candidate = try providerCandidate(providerID: providerID, modelID: modelID)

        // A forged/foreign subject kind never consumes this route's authority.
        let mcpCore = intentCore(subjectKind: "mcpSave", subjectID: UUID().uuidString,
                                 candidate: ["id": UUID().uuidString, "displayName": "x",
                                             "endpoint": "https://example.invalid/mcp",
                                             "authentication": "none"])
        XCTAssertThrowsError(try registry.submitBoundIntent(
            intentCoreJSON: mcpCore, routeAssertion: route.token,
            secret: Data("synthetic-secret".utf8))) { error in
            XCTAssertEqual(error as? G02HostSecureIngressError, .routeAssertionMismatch)
        }

        // A core intent that names a route is refused before any vault slot.
        var smuggled = try JSONSerialization.jsonObject(
            with: intentCore(subjectKind: "providerSave", subjectID: providerID.uuidString,
                             candidate: candidate)) as! [String: Any]
        smuggled["route"] = ["token": "rt:v1:" + String(repeating: "a", count: 32),
                             "generation": 1]
        XCTAssertThrowsError(try registry.submitBoundIntent(
            intentCoreJSON: canonicalJSON(smuggled), routeAssertion: route.token,
            secret: Data("synthetic-secret".utf8))) { error in
            XCTAssertEqual(error as? G02HostSecureIngressError, .invalidIntent)
        }

        // Wrong/foreign route assertion for a valid core.
        XCTAssertThrowsError(try registry.submitBoundIntent(
            intentCoreJSON: intentCore(subjectKind: "providerSave",
                                       subjectID: providerID.uuidString,
                                       candidate: candidate),
            routeAssertion: "rt:v1:" + String(repeating: "0", count: 32),
            secret: Data("synthetic-secret".utf8))) { error in
            XCTAssertEqual(error as? G02HostSecureIngressError, .routeAssertionMismatch)
        }
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().intentsLive, 0)

        // Happy path: the lease carries EXACTLY the frozen candidate and the
        // optional base revision; the secret is the bounded byte array only.
        let token = try registry.submitBoundIntent(
            intentCoreJSON: intentCore(subjectKind: "providerSave",
                                       subjectID: providerID.uuidString,
                                       candidate: candidate,
                                       baseRevision: ["resourceID": "provider.\(providerID.uuidString)",
                                                      "version": "0"]),
            routeAssertion: route.token,
            secret: Data("synthetic-placeholder-key".utf8))
        XCTAssertTrue(SecretGatewayIdentity.isCanonicalIngressToken(token))
        XCTAssertFalse(token.contains("synthetic"))
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().intentsLive, 1)
        let lease = try SecretSaveIntentVault.shared.consume(
            token: token, route: try XCTUnwrap(registry.currentRoute()),
            expectedSubject: .providerSave)
        XCTAssertEqual(lease.baseRevision?.version, "0")
        XCTAssertEqual(lease.candidateJSON, canonicalJSON(candidate))
        XCTAssertEqual(lease.secret, Data("synthetic-placeholder-key".utf8))
        XCTAssertTrue(lease.close())

        // Cross-subject consumption of the SAME kind of token is refused.
        XCTAssertThrowsError(try SecretSaveIntentVault.shared.consume(
            token: token, route: try XCTUnwrap(registry.currentRoute()),
            expectedSubject: .providerSave))
    }

    // MARK: - Component: slot lifetime

    func testCloseAndRetireDiscardOnlyOwnUnconsumedLiveIntents() throws {
        let registry = G02HostRouteContextProvider()
        registry.configureEpochForTesting { 31 }
        let providerID = UUID()
        let candidate = try providerCandidate(providerID: providerID, modelID: UUID())
        let core = intentCore(subjectKind: "providerSave", subjectID: providerID.uuidString,
                              candidate: candidate)
        let route = try XCTUnwrap(registry.openEditorRoute(
            editorKind: "provider", editorID: "editor-A",
            uiGeneration: 5, expectedNativeRootEpoch: 31))
        _ = try registry.submitBoundIntent(intentCoreJSON: core,
                                           routeAssertion: route.token,
                                           secret: Data("k1".utf8))
        _ = try registry.submitBoundIntent(intentCoreJSON: core,
                                           routeAssertion: route.token,
                                           secret: Data("k2".utf8))
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().intentsLive, 2)
        // Retire for a DIFFERENT epoch is not this binding's fence.
        registry.retireBoundRoute(epoch: 30)
        XCTAssertEqual(registry.currentRoute(), route)
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().intentsLive, 2)
        // Exact-ownership clear sweeps this route's unconsumed live intents.
        XCTAssertTrue(registry.clearEditorRoute(token: route.token))
        XCTAssertNil(registry.currentRoute())
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().intentsLive, 0)

        // Retire path: a fresh incarnation's live intent is swept by its own
        // epoch's retirement, and nothing of a newer epoch is touched.
        let route2 = try XCTUnwrap(registry.openEditorRoute(
            editorKind: "webSearch", editorID: "editor-W",
            uiGeneration: 6, expectedNativeRootEpoch: 31))
        _ = try registry.submitBoundIntent(
            intentCoreJSON: intentCore(subjectKind: "webSearchSave",
                                       subjectID: providerID.uuidString,
                                       candidate: ["id": providerID.uuidString,
                                                   "kind": "custom",
                                                   "displayName": "synthetic web search",
                                                   "enabled": true,
                                                   "priority": 0,
                                                   "credentialAccount": "synthetic",
                                                   "options": [String: String]()]),
            routeAssertion: route2.token, secret: Data("k3".utf8))
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().intentsLive, 1)
        registry.retireBoundRoute(epoch: 31)
        XCTAssertNil(registry.currentRoute())
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().intentsLive, 0)
    }

    func testNewerEditorReplacementSweepsOldRouteLiveIntentsOnly() throws {
        // Main witness: openA -> submitA (LIVE) -> openB (newer) -> late
        // clearA (no-op) -> retire. A's LIVE secret must not survive the
        // replacement, while an ACTIVE lease from A stays owned.
        let registry = G02HostRouteContextProvider()
        registry.configureEpochForTesting { 31 }
        let providerID = UUID()
        let candidate = try providerCandidate(providerID: providerID, modelID: UUID())
        let core = intentCore(subjectKind: "providerSave",
                              subjectID: providerID.uuidString, candidate: candidate)
        let routeA = try XCTUnwrap(registry.openEditorRoute(
            editorKind: "provider", editorID: "editor-A",
            uiGeneration: 9, expectedNativeRootEpoch: 31))
        let tokenA = try registry.submitBoundIntent(
            intentCoreJSON: core, routeAssertion: routeA.token,
            secret: Data("old-route-secret".utf8))
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().intentsLive, 1)

        // A second LIVE intent from A, then claim it into an ACTIVE lease:
        // the replacement may sweep only the UNCONSUMED one.
        let tokenA2 = try registry.submitBoundIntent(
            intentCoreJSON: core, routeAssertion: routeA.token,
            secret: Data("claimed-old-secret".utf8))
        let claimed = try SecretSaveIntentVault.shared.consume(
            token: tokenA2, route: try XCTUnwrap(registry.currentRoute()),
            expectedSubject: .providerSave)
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().intentsLive, 1)
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().leasesActive, 1)

        // A genuinely newer editor replaces the LIVE binding.
        let routeB = try XCTUnwrap(registry.openEditorRoute(
            editorKind: "mcp", editorID: "editor-B",
            uiGeneration: 10, expectedNativeRootEpoch: 31))
        XCTAssertEqual(registry.currentRoute(), routeB)
        // The replaced route's UNCONSUMED live intent is gone; the claimed
        // ACTIVE lease is untouched.
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().intentsLive, 0)
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().leasesActive, 1)
        // The old token cannot be consumed any more (unknown, never replay).
        XCTAssertThrowsError(try SecretSaveIntentVault.shared.consume(
            token: tokenA, route: try XCTUnwrap(registry.currentRoute()),
            expectedSubject: .providerSave))
        // A late close of the replaced handle never clears B.
        XCTAssertTrue(registry.clearEditorRoute(token: routeA.token))
        XCTAssertEqual(registry.currentRoute(), routeB)
        // The claimed lease still owns its exact secret and closes once.
        XCTAssertEqual(claimed.secret, Data("claimed-old-secret".utf8))
        XCTAssertTrue(claimed.close())
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().leasesActive, 0)
        // Retiring the epoch sweeps B's own live intents (none) and keeps the
        // binding semantics exact.
        registry.retireBoundRoute(epoch: 31)
        XCTAssertNil(registry.currentRoute())
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().intentsLive, 0)
    }

    func testFailedOpenNeverMutatesOrSweepsTheLiveBinding() throws {
        let registry = G02HostRouteContextProvider()
        registry.configureEpochForTesting { 31 }
        let providerID = UUID()
        let candidate = try providerCandidate(providerID: providerID, modelID: UUID())
        let route = try XCTUnwrap(registry.openEditorRoute(
            editorKind: "provider", editorID: "editor-A",
            uiGeneration: 9, expectedNativeRootEpoch: 31))
        _ = try registry.submitBoundIntent(
            intentCoreJSON: intentCore(subjectKind: "providerSave",
                                       subjectID: providerID.uuidString,
                                       candidate: candidate),
            routeAssertion: route.token, secret: Data("live-secret".utf8))
        // Stale epoch / older UI generation / invalid kind: no mutation and
        // no sweep of the live binding's intent.
        XCTAssertNil(registry.openEditorRoute(editorKind: "provider", editorID: "editor-B",
                                              uiGeneration: 10, expectedNativeRootEpoch: 30))
        XCTAssertNil(registry.openEditorRoute(editorKind: "provider", editorID: "editor-B",
                                              uiGeneration: 8, expectedNativeRootEpoch: 31))
        XCTAssertNil(registry.openEditorRoute(editorKind: "bogus", editorID: "editor-B",
                                              uiGeneration: 10, expectedNativeRootEpoch: 31))
        XCTAssertEqual(registry.currentRoute(), route)
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().intentsLive, 1)
    }

    func testActiveLeaseIsNeverDroppedByCloseOrRetire() throws {
        let registry = G02HostRouteContextProvider()
        registry.configureEpochForTesting { 31 }
        let providerID = UUID()
        let candidate = try providerCandidate(providerID: providerID, modelID: UUID())
        let route = try XCTUnwrap(registry.openEditorRoute(
            editorKind: "provider", editorID: "editor-A",
            uiGeneration: 5, expectedNativeRootEpoch: 31))
        let token = try registry.submitBoundIntent(
            intentCoreJSON: intentCore(subjectKind: "providerSave",
                                       subjectID: providerID.uuidString,
                                       candidate: candidate),
            routeAssertion: route.token, secret: Data("claimed-key".utf8))
        let lease = try SecretSaveIntentVault.shared.consume(
            token: token, route: try XCTUnwrap(registry.currentRoute()),
            expectedSubject: .providerSave)
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().leasesActive, 1)
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().intentsLive, 0)
        // Closing the route / retiring the Root must not release the ACTIVE
        // admission that a handler has already claimed.
        XCTAssertTrue(registry.clearEditorRoute(token: route.token))
        registry.retireBoundRoute(epoch: 31)
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().leasesActive, 1)
        // The claimed lease is still usable and closes exactly once.
        XCTAssertEqual(lease.secret, Data("claimed-key".utf8))
        XCTAssertTrue(lease.close())
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().leasesActive, 0)
    }

    func testCAbiValidatesCapacityBeforeMintingOrReplacing() {
        let registry = G02HostSecureIngress.registry
        registry.configureEpochForTesting { 31 }
        let good = registry.openEditorRoute(editorKind: "provider", editorID: "editor-A",
                                            uiGeneration: 1, expectedNativeRootEpoch: 31)
        let established = try! XCTUnwrap(good)
        var buffer = [CChar](repeating: 0, count: 64)
        let tiny = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            "provider".withCString { kind in
                "editor-B".withCString { id in
                    floeHostRouteOpen(kind, id, 2, 31, pointer.baseAddress, 8)
                }
            }
        }
        XCTAssertEqual(tiny, G02HostSecureIngressStatus.invalidArgument)
        // No replacement happened on the invalid capacity.
        XCTAssertEqual(registry.currentRoute(), established)
        let ok = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
            "provider".withCString { kind in
                "editor-B".withCString { id in
                    floeHostRouteOpen(kind, id, 2, 31, pointer.baseAddress, 64)
                }
            }
        }
        XCTAssertEqual(ok, G02HostSecureIngressStatus.ok)
        XCTAssertNotEqual(registry.currentRoute()?.token, established.token)
    }

    // MARK: - Actual bootstrap: real V3 save through the trusted seam

    @discardableResult
    private func bootInstalledGeneration() async throws -> Boot {
        let root = NSTemporaryDirectory()
            .appending("g02-secure-ingress-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root,
                                                withIntermediateDirectories: true)
        let token = String((0..<16).map { _ in "0123456789abcdef".randomElement()! })
        let epoch = FixtureEpoch.allocate()
        guard case .accepted(let receipt) = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: token, epoch: epoch) else {
            XCTFail("bootstrap not accepted (root preserved: \(root))")
            throw TestError.bootstrap
        }
        let boot = Boot(epoch: epoch, token: token, rootPath: root)
        tracked.append(boot)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            guard let gen = AndroidRuntimeBootstrap.currentGenerationForTesting(),
                  gen.epoch == epoch else {
                XCTFail("generation vanished before its accepted terminal: "
                            + AndroidRuntimeBootstrap.statusSnapshotJSON())
                throw TestError.bootstrap
            }
            guard case .page(let effects, _, _, _) =
                    gen.effects.poll(receipt: receipt, afterSequence: 0),
                  let terminal = effects.first(where: { $0.isTerminal }) else {
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            guard terminal.kind == .accepted else {
                XCTFail("bootstrap terminal not accepted: \(terminal.kind)")
                throw TestError.bootstrap
            }
            guard let installed = G02RuntimeComposition.shared.installedComposition,
                  installed.epoch == epoch else {
                try await Task.sleep(nanoseconds: 10_000_000)
                continue
            }
            return boot
        }
        XCTFail("bootstrap terminal did not settle")
        throw TestError.bootstrap
    }

    private func shutdownAndAwaitClosed(_ boot: Boot) async {
        await G02HostSecureIngressTests.shutdownEpoch(boot)
    }

    private static func shutdownEpoch(_ boot: Boot) async {
        guard !boot.retired else { return }
        boot.retired = true
        switch AndroidRuntimeBootstrap.shutdown(expectedEpoch: boot.epoch,
                                                ownerToken: boot.token) {
        case .accepted, .idempotent:
            break
        case .rejected(let code):
            if code == .notInstalled,
               AndroidRuntimeBootstrap.currentGenerationForTesting() == nil {
                return
            }
            XCTFail("shutdown not accepted for epoch \(boot.epoch): \(code.rawValue)")
            return
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if AndroidRuntimeBootstrap.currentGenerationForTesting() == nil {
                let status = AndroidRuntimeBootstrap.statusSnapshotJSON()
                if status.contains("\"ownedStorePhase\":\"closed\"")
                    || !status.contains("\"generation\"") {
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let raw = AndroidRuntimeBootstrap.statusSnapshotJSON()
        let object = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)))
            as? [String: Any] ?? [:]
        let compact = [
            "phase=\(object["phase"] ?? "?")",
            "retiring=\(object["retiring"] ?? "?")",
            "store=\(object["ownedStorePhase"] ?? "?")",
            "generation=\(object["generation"] ?? "nil")",
            "ownedWork=\(RuntimeOwnedWorkRegistry.shared.count(for: boot.epoch))",
            "mailbox=\(object["mailbox"] ?? "?")",
        ].joined(separator: " ")
        XCTFail("generation did not reach closed/gone for epoch \(boot.epoch): " + compact)
    }

    private enum TestError: Error { case bootstrap }

    private func exchange(_ request: String) -> [String: Any]? {
        let data = AndroidBridge.exchange(Data(request.utf8))
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object,
                                               options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func submitEnvelope(
        correlation: String, command: String, scope: String,
        configurationScope: String? = nil,
        revision: (resourceID: String, version: String)? = nil,
        createIntent: Bool = false, stateful: Bool = false,
        payload: [String: Any]? = nil
    ) -> String {
        var envelope: [String: Any] = [
            "schema": BridgeV3.commandSchema,
            "scope": scope,
            "command": command,
            "stateful": stateful,
            "correlationID": correlation,
        ]
        if let configurationScope { envelope["configurationScope"] = configurationScope }
        if let revision {
            envelope["revision"] = ["resourceID": revision.resourceID,
                                    "version": revision.version]
        }
        if createIntent { envelope["createIntent"] = true }
        if let payload { envelope["payload"] = payload }
        return json([
            "version": BridgeV3.version,
            "operation": BridgeV3.Operation.submit.rawValue,
            "requestID": correlation,
            "envelope": envelope,
        ])
    }

    private func effectEnvelope(correlation: String, receipt: String,
                                sequence: Int) -> String {
        json([
            "version": BridgeV3.version,
            "operation": BridgeV3.Operation.effectPoll.rawValue,
            "requestID": correlation,
            "envelope": [
                "schema": BridgeV3.effectSchema,
                "scope": BridgeV3.Scope.applicationConfiguration.rawValue,
                "configurationScope": "system",
                "command": BridgeV3.Operation.effectPoll.rawValue,
                "stateful": false,
                "correlationID": correlation,
                "effect": ["operationReceiptID": receipt, "sequence": sequence],
            ],
        ])
    }

    private func submit(_ request: String) throws -> String {
        let answer = try XCTUnwrap(exchange(request))
        XCTAssertEqual(answer["ok"] as? Bool, true, "\(answer)")
        XCTAssertEqual(answer["queued"] as? Bool, true, "\(answer)")
        return try XCTUnwrap(answer["operationReceiptID"] as? String, "\(answer)")
    }

    private func pollUntilTerminal(receipt: String,
                                   timeout: TimeInterval = 25,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while Date() < deadline {
            attempt += 1
            let page = try XCTUnwrap(
                exchange(effectEnvelope(correlation: "secure-ingress-poll-\(attempt)",
                                        receipt: receipt, sequence: 0)),
                "effect.poll unavailable", file: file, line: line)
            if let effects = page["effects"] as? [[String: Any]],
               let terminal = effects.last(where: { item in
                   ["accepted", "failed", "rejected", "cancelled",
                    "replaced", "closed"].contains(item["kind"] as? String ?? "")
               }) {
                return terminal
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("no terminal settled for \(receipt)", file: file, line: line)
        throw TestError.bootstrap
    }

    func testActualBootstrapFirstProviderSetCommitsWithBoundSecretReference() async throws {
        let gateway = SyntheticSecretGateway()
        SecretGatewayRegistry.shared.register(gateway)
        let boot = try await bootInstalledGeneration()
        let registry = G02HostSecureIngress.registry
        // The App captures the ACTUAL accepted native root epoch now.
        let capturedEpoch = try XCTUnwrap(G02NativeRootEpoch.readback())
        XCTAssertEqual(capturedEpoch, boot.epoch)

        let providerID = UUID()
        let modelID = UUID()
        let candidate = try providerCandidate(providerID: providerID, modelID: modelID)
        let route = try XCTUnwrap(registry.openEditorRoute(
            editorKind: "provider", editorID: "new-conversation-1",
            uiGeneration: 9, expectedNativeRootEpoch: capturedEpoch))
        // Controlled native 31 vs UI 9 separation: the UI generation is
        // independent, but a stale NATIVE epoch is refused even with a newer
        // UI generation.
        XCTAssertNil(registry.openEditorRoute(
            editorKind: "provider", editorID: "new-conversation-2",
            uiGeneration: 10, expectedNativeRootEpoch: capturedEpoch &- 1))

        let token = try registry.submitBoundIntent(
            intentCoreJSON: intentCore(subjectKind: "providerSave",
                                       subjectID: providerID.uuidString,
                                       candidate: candidate,
                                       baseRevision: ["resourceID": "provider.\(providerID.uuidString)",
                                                      "version": "0"]),
            routeAssertion: route.token,
            secret: Data("synthetic-placeholder-key".utf8))

        let saveReceipt = try submit(submitEnvelope(
            correlation: "secure-ingress-save-1",
            command: "config.provider.save",
            scope: BridgeV3.Scope.applicationConfiguration.rawValue,
            configurationScope: "providers",
            createIntent: true,
            stateful: true,
            payload: ["secretIntent": "set", "ingressToken": token]))
        let terminal = try await pollUntilTerminal(receipt: saveReceipt)
        XCTAssertEqual(terminal["kind"] as? String, "accepted", "\(terminal)")
        let value = try XCTUnwrap(terminal["value"] as? [String: Any], "\(terminal)")
        XCTAssertEqual(value["state"] as? String, "committed", "\(value)")
        XCTAssertEqual(value["providerID"] as? String, providerID.uuidString)

        // The persisted row (read through the REAL V3 list) carries the
        // canonical opaque secret reference bound to the deterministic
        // provider account; the raw key is nowhere in the wire or store.
        let listReceipt = try submit(submitEnvelope(
            correlation: "secure-ingress-list-1",
            command: "config.providers.list",
            scope: BridgeV3.Scope.applicationConfiguration.rawValue,
            configurationScope: "providers",
            payload: ["operation": "snapshot"]))
        let listTerminal = try await pollUntilTerminal(receipt: listReceipt)
        XCTAssertEqual(listTerminal["kind"] as? String, "accepted", "\(listTerminal)")
        let listValue = try XCTUnwrap(listTerminal["value"] as? [String: Any])
        let rows = try XCTUnwrap(listValue["rows"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first(where: { ($0["id"] as? String) == providerID.uuidString }))
        XCTAssertEqual(row["displayName"] as? String, "Floe G02 QA")
        XCTAssertEqual(row["isEnabled"] as? Bool, true)
        let secret = try XCTUnwrap(row["secret"] as? [String: Any])
        XCTAssertEqual(secret["configured"] as? Bool, true, "\(row)")
        let reference = try XCTUnwrap(secret["opaqueReference"] as? String, "\(row)")
        XCTAssertTrue(SecretGatewayIdentity.isCanonicalReference(reference), reference)
        // The logical binding is the SAME deterministic provider account:
        // recompute the canonical reference for provider.<UUID> and require
        // the ACTUAL gateway write to have used exactly it.
        let account = ConfigSecretIdentity.providerAccount(providerID: providerID)
        let expectedReference = ConfigSecretIdentity.providerOpaqueReference(
            for: ConfigSecretIdentity.providerSecretReference(account: account,
                                                              synchronizable: false))
        XCTAssertEqual(reference, expectedReference)
        let writes = await gateway.writes
        XCTAssertEqual(writes.count, 1, "\(writes)")
        XCTAssertEqual(writes.first?.reference, expectedReference)
        XCTAssertEqual(writes.first?.value, Data("synthetic-placeholder-key".utf8))
        // The raw synthetic key never appears in any wire value.
        XCTAssertFalse(json(listTerminal).contains("synthetic-placeholder-key"))
        XCTAssertFalse(json(terminal).contains("synthetic-placeholder-key"))
    }

    func testRootRetirementRefusesLateOpenSubmitAndSweepsItsLiveIntent() async throws {
        SecretGatewayRegistry.shared.register(SyntheticSecretGateway())
        let boot = try await bootInstalledGeneration()
        let registry = G02HostSecureIngress.registry
        let epoch = try XCTUnwrap(G02NativeRootEpoch.readback())
        XCTAssertEqual(epoch, boot.epoch)
        let providerID = UUID()
        let candidate = try providerCandidate(providerID: providerID, modelID: UUID())
        let route = try XCTUnwrap(registry.openEditorRoute(
            editorKind: "provider", editorID: "editor-live",
            uiGeneration: 21, expectedNativeRootEpoch: epoch))
        // One UNCONSUMED live intent admitted BEFORE the fence.
        _ = try registry.submitBoundIntent(
            intentCoreJSON: intentCore(subjectKind: "providerSave",
                                       subjectID: providerID.uuidString,
                                       candidate: candidate),
            routeAssertion: route.token,
            secret: Data("pre-fence-synthetic".utf8))
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().intentsLive, 1)

        await shutdownAndAwaitClosed(boot)

        // Post-fence: no route, no live secret slot, no admission.
        XCTAssertNil(registry.currentRoute())
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().intentsLive, 0)
        XCTAssertThrowsError(try registry.submitBoundIntent(
            intentCoreJSON: intentCore(subjectKind: "providerSave",
                                       subjectID: providerID.uuidString,
                                       candidate: candidate),
            routeAssertion: route.token,
            secret: Data("post-fence-synthetic".utf8))) { error in
            XCTAssertEqual(error as? G02HostSecureIngressError, .routeUnavailable)
        }
        XCTAssertNil(registry.openEditorRoute(
            editorKind: "provider", editorID: "editor-late",
            uiGeneration: 22, expectedNativeRootEpoch: epoch))
    }
    // MARK: - Actual bootstrap: held admission vs RootStop linearization

    /// Deterministic interleaving: an admission is HELD inside the one-shot
    /// vault (holding the registry lock) while the Root stop begins. The stop
    /// cannot finish before the held admission settles, the pre-fence
    /// admission is then swept by the same epoch's retirement, no old-scope
    /// live secret survives, and the retired epoch's route can never be
    /// minted into a NEW Root.
    func testRootStopCannotFinishBeforeHeldAdmissionSettlesAndSweeps() async throws {
        SecretGatewayRegistry.shared.register(SyntheticSecretGateway())
        let boot = try await bootInstalledGeneration()
        let registry = G02HostSecureIngress.registry
        let epoch = try XCTUnwrap(G02NativeRootEpoch.readback())
        XCTAssertEqual(epoch, boot.epoch)
        let providerID = UUID()
        let candidate = try providerCandidate(providerID: providerID, modelID: UUID())
        let route = try XCTUnwrap(registry.openEditorRoute(
            editorKind: "provider", editorID: "editor-held",
            uiGeneration: 41, expectedNativeRootEpoch: epoch))

        // Hold the vault's submit path open deterministically through its
        // test clock (called INSIDE the vault lock, therefore while this
        // admission also holds the registry lock). The barrier is SINGLE-USE:
        // only the held admission blocks; every later vault clock call (the
        // replay consume below) passes straight through.
        let barrier = SingleUseVaultBarrier()
        SecretSaveIntentVault.shared.configureForTesting(clock: {
            barrier.waitIfFirst()
            return 1
        })
        let heldCore = intentCore(subjectKind: "providerSave",
                                  subjectID: providerID.uuidString,
                                  candidate: candidate)
        let heldRoute = route.token
        let admission = Task.detached { [registry, heldCore, heldRoute] () -> Result<String, Error> in
            do {
                let token = try registry.submitBoundIntent(
                    intentCoreJSON: heldCore, routeAssertion: heldRoute,
                    secret: Data("held-pre-fence-secret".utf8))
                return .success(token)
            } catch {
                return .failure(error)
            }
        }
        XCTAssertEqual(barrier.entered.wait(timeout: .now() + 10), .success,
                       "the admission never reached the vault submit")
        defer { barrier.releaseAdmission() }

        let closed = RaceFlag()
        let stop = Task { [boot, closed] in
            await G02HostSecureIngressTests.shutdownEpoch(boot)
            closed.set()
        }
        // Observed ACTUAL Root fence/admission point: shutdown's atomic
        // boundary has fenced admissions and the drain control is running.
        // Only then is "the stop has not completed" meaningful (a not-yet
        // started stop would make the assertion vacuous).
        var fenced = false
        let fenceDeadline = Date().addingTimeInterval(10)
        while Date() < fenceDeadline {
            if AndroidRuntimeBootstrap.statusSnapshotJSON().contains("\"phase\":\"draining\"") {
                fenced = true
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(fenced, "Root shutdown never reached its draining fence")
        // The fence has been reached, the held pre-fence admission still owns
        // the registry lock, so retirement cannot have completed its clear or
        // torn the composition down: both are still present.
        XCTAssertFalse(closed.isSet,
                       "RootStop completed while an admission was still held")
        XCTAssertNotNil(G02RuntimeComposition.shared.installedComposition,
                        "retirement passed the host route fence while it was held")
        XCTAssertNotNil(AndroidRuntimeBootstrap.currentGenerationForTesting())
        // NOTE: no registry/vault reads here — the held admission owns those
        // locks until released. The blocked-state proof is the actual
        // draining phase + installed composition + uncompleted stop above.

        barrier.releaseAdmission()

        let outcome = await admission.value
        let token: String
        switch outcome {
        case .success(let issued):
            token = issued
        case .failure(let error):
            XCTFail("pre-fence admission was refused instead of ordered before the fence: \(error)")
            await stop.value
            SecretSaveIntentVault.shared.configureForTesting(clock: nil)
            return
        }
        XCTAssertTrue(SecretGatewayIdentity.isCanonicalIngressToken(token))
        await stop.value
        XCTAssertTrue(closed.isSet)
        // The real stop made progress AFTER the held admission settled.
        XCTAssertNil(G02RuntimeComposition.shared.installedComposition)
        XCTAssertNil(AndroidRuntimeBootstrap.currentGenerationForTesting())
        // The clock barrier is retired before the replay consume: no test
        // instrumentation participates in the production consume path.
        SecretSaveIntentVault.shared.configureForTesting(clock: nil)
        // The held (pre-fence) admission was ordered BEFORE retirement and
        // swept by that same epoch's fence: no live old-scope secret, no
        // route, and a replay can never consume it.
        XCTAssertEqual(SecretSaveIntentVault.shared.statsSnapshot().intentsLive, 0)
        XCTAssertNil(registry.currentRoute())
        XCTAssertThrowsError(try SecretSaveIntentVault.shared.consume(
            token: token, route: route, expectedSubject: .providerSave))
        // No old-epoch route is admitted into the NEXT Root.
        let nextEpoch = FixtureEpoch.allocate()
        let root = NSTemporaryDirectory()
            .appending("g02-secure-ingress-next-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root,
                                                withIntermediateDirectories: true)
        let nextToken = String((0..<16).map { _ in "0123456789abcdef".randomElement()! })
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root, ownerToken: nextToken, epoch: nextEpoch) else {
            return XCTFail("next generation not accepted")
        }
        let nextBoot = Boot(epoch: nextEpoch, token: nextToken, rootPath: root)
        tracked.append(nextBoot)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let installed = G02RuntimeComposition.shared.installedComposition,
               installed.epoch == nextEpoch { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(G02NativeRootEpoch.readback(), nextEpoch)
        // The OLD epoch/editor handle can never be admitted into the new Root.
        XCTAssertNil(registry.openEditorRoute(
            editorKind: "provider", editorID: "editor-held",
            uiGeneration: 42, expectedNativeRootEpoch: epoch))
        XCTAssertNil(registry.currentRoute())
        // A genuinely new-Root editor incarnation is admitted.
        XCTAssertNotNil(registry.openEditorRoute(
            editorKind: "provider", editorID: "editor-new-root",
            uiGeneration: 43, expectedNativeRootEpoch: nextEpoch))
    }
}

/// Single-use vault clock barrier: exactly the held admission blocks; every
/// subsequent clock read passes through (no fixture deadlock, no weakening).
private final class SingleUseVaultBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func waitIfFirst() {
        lock.lock()
        let first = !used
        if first { used = true }
        lock.unlock()
        guard first else { return }
        entered.signal()
        released.wait()
    }

    func releaseAdmission() { released.signal() }
}

/// Minimal completion flag for the race assertion (test support only).
private final class RaceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
