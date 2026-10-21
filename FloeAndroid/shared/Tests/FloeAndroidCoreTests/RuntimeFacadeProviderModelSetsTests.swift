// SPDX-License-Identifier: MPL-2.0
//
// job-2e38 — large provider profiles: trusted-host model-set staging,
// compact existing-row metadata keep, bounded committed projection, and the
// original Set/Keep/Clear chain end-to-end through the REAL router.
//
// AUTHORED ONLY: NOT compiled, NOT executed by this package (batch-first
// policy). Main's serialized verification lane runs them against the real
// toolchain together with the composed batch. Synthetic material only:
// scripted authorities, fake gateways with counters, file-backed stores,
// loopback-invalid hosts, no real credentials or network.
//
// Coverage contract (Main's meaningful-tests list):
//  1. a real file-backed 512-model profile CREATED through the staged
//     reference end-to-end via ModelConfigurationCommandRouter.handle —
//     the SAME original atomic draft/runner/bundle chain, zero secret
//     writes, models durable, and the committed OUTPUT proven inside the
//     ACTUAL effect frame path (bounded summary, never a frame-exploding
//     full array, never a false failure of a committed save);
//  2. compact metadata keep on that same 512-model profile: exact model
//     digests, provider fields, secret reference and gateway counters
//     byte-stable; only is_enabled/updated_at/sync_revision advance;
//  3. mixed/malformed metadata forms and candidate representation XOR
//     refuse BEFORE any effect (no DB change, no lease consume, no ledger);
//  4. stale/absent revision and pending-owner authority semantics;
//  5. stager chunk order/duplicate/tamper/foreign/expiry/count/bytes/
//     saturation + frozen identity + digest re-check;
//  6. probe borrow semantics: a borrowed frozen stage is never consumed
//     and can still back a later real save resolution.
//
// The small legacy committed shape stays byte-compatible (arrays intact,
// counts additive); these tests pin both shapes so neither silently drifts.

import XCTest
import Foundation
import GRDB
@testable import FloeAndroidCore
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders

final class RuntimeFacadeProviderModelSetsTests: XCTestCase {

    func testBareSingletonPreservesOriginalSingleModelFinalTwoBytes() throws {
        for targetBytes in [61_439, 61_440] {
            let empty = makeModel(index: targetBytes, displayName: "")
            let emptyObject = try ConfigModelSnapshot.jsonObject(empty)
            let emptyBytes = try XCTUnwrap(ConfigJSON.canonicalData(emptyObject)).count
            let model = makeModel(index: targetBytes,
                                  displayName: String(repeating: "x", count: targetBytes - emptyBytes))
            XCTAssertTrue(ProviderConfigurationValidation.issues(for: model).isEmpty)
            let row = try ConfigModelSnapshot.jsonObject(model)
            let bytes = try XCTUnwrap(ConfigJSON.canonicalData(row))
            XCTAssertEqual(bytes.count, targetBytes)
            let stage = try ProviderModelSetRegistry.shared.begin(
                providerID: providerID, baseResourceID: "provider.\(providerID.uuidString)",
                baseVersion: "0", createIntent: true, routeAssertion: liveToken)
            try ProviderModelSetRegistry.shared.append(
                stageID: stage, routeAssertion: liveToken, index: 0, chunk: bytes)
            let ref = try ProviderModelSetRegistry.shared.seal(
                stageID: stage, routeAssertion: liveToken, expectedCount: 1)
            let resolved = try ProviderModelSetRegistry.shared.resolve(
                frozenRef: ref, providerID: providerID, createIntent: true,
                baseRevision: nil, isDraftProbe: false)
            XCTAssertEqual(resolved.count, 1)
            XCTAssertEqual(try ConfigModelSnapshot.digest(XCTUnwrap(resolved.first)),
                           try ConfigModelSnapshot.digest(model))
            XCTAssertTrue(ProviderModelSetRegistry.shared.cancel(stageID: stage, routeAssertion: liveToken))
        }
    }

    // MARK: Fixtures

    private var databaseURL: URL!
    private var database: DatabaseManager!

    private let providerID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    /// Canonical ASCII route token (rt:v1: + 32 lowercase hex).
    private let liveToken = "rt:v1:0123456789abcdef0123456789abcdef"
    private var liveAuthority: ProviderModelSetAuthority {
        ProviderModelSetAuthority(rootEpoch: 7, routeToken: liveToken,
                                  routeGeneration: 5, editorID: "editor-1")
    }

    override func setUp() async throws {
        SecretSaveIntentVault.shared.resetForTesting()
        ProviderModelSetRegistry.shared.resetForTesting()
        ProviderModelSetRegistry.authorityForTesting = { [liveAuthority] token in
            token == liveAuthority.routeToken ? liveAuthority : nil
        }
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-large-profile-\(UUID().uuidString).db")
        database = try DatabaseManager(path: databaseURL)
        try await database.migrate()
    }

    override func tearDown() async throws {
        SecretSaveIntentVault.shared.resetForTesting()
        ProviderModelSetRegistry.shared.resetForTesting()
        try await database.close()
        try? FileManager.default.removeItem(at: databaseURL)
    }

    private func makeFacade(gateway: IngressTestGateway,
                            ownership: (any ProviderOperationOwning)? = nil)
        -> ModelConfigurationFacade
    {
        ModelConfigurationFacade(
            database: database,
            gateway: gateway,
            catalogBytes: nil,
            transportAdmission: TransportAdmissionClosed(),
            routeContext: FixedRouteContext(token: "route-a", generation: 5),
            adapters: CountingAdapterFactory(),
            ownership: ownership,
            epochProvider: FixedEpochProvider(epoch: 1),
            ownedWorkRegistry: AlwaysAttachOwnedWorkPort())
    }

    private func makeModel(index: Int,
                           displayName: String? = nil) -> ModelProfile {
        ModelProfile(
            id: UUID(uuidString: String(format: "%08X-0000-0000-0000-000000000000",
                                        0x1000_0000 + index))!,
            providerID: providerID,
            remoteModelID: "model-\(index)",
            displayName: displayName ?? "Model \(index)",
            limits: ModelLimits(contextTokens: 4096, maxOutputTokens: 1024),
            pricing: nil,
            capabilities: [.text, .tools],
            useSurfaces: nil,
            reasoningEffort: nil,
            isEnabled: true,
            isHiddenFromPrimaryPicker: false,
            explicitCapabilities: nil)
    }

    private func chunkPayload(_ models: [ModelProfile]) throws -> Data {
        let objects = try models.map { try ConfigModelSnapshot.jsonObject($0) }
        return try JSONSerialization.data(withJSONObject: objects)
    }

    /// Stage + seal `count` models in ordered ≤61,440-byte chunks; returns
    /// the frozen reference. Uses the REAL registry (scripted authority).
    private func stageModels(count: Int,
                              createIntent: Bool,
                              baseVersion: String) throws -> String {
        let resourceID = "provider.\(providerID.uuidString)"
        let stageID = try ProviderModelSetRegistry.shared.begin(
            providerID: providerID, baseResourceID: resourceID,
            baseVersion: baseVersion, createIntent: createIntent,
            routeAssertion: liveToken)
        var index = 0
        var start = 0
        while start < count {
            let end = min(start + 200, count)
            let models = (start..<end).map { makeModel(index: $0) }
            try ProviderModelSetRegistry.shared.append(
                stageID: stageID, routeAssertion: liveToken,
                index: index, chunk: try chunkPayload(models))
            index += 1
            start = end
        }
        return try ProviderModelSetRegistry.shared.seal(
            stageID: stageID, routeAssertion: liveToken, expectedCount: count)
    }

    private func refCandidateDict(modelSetRef: String,
                                  createIntent: Bool) -> [String: Any] {
        [
            "id": providerID.uuidString,
            "kind": "openAI",
            "wireProtocol": "openai-chat-completions",
            "baseURL": "https://api.example.invalid/v1",
            "displayName": "Large Profile",
            "syncEnabled": false,
            "modelSetRef": modelSetRef,
            "managedCapabilities": ModelCapabilities.text.rawValue,
            "serviceRoleIsConversation": true,
            "createIntent": createIntent,
        ]
    }

    private static func envelope(payload: [String: Any], revision: (String, String)?)
        throws -> sending [String: Any]
    {
        var envelope: [String: Any] = ["payload": payload]
        if let revision {
            envelope["revision"] = ["resourceID": revision.0, "version": revision.1]
        }
        // The production router receives a newly decoded JSON tree. Match
        // that ownership boundary; never transfer XCTestCase or caller's
        // heterogeneous payload graph across the actor boundary.
        let bytes = try JSONSerialization.data(withJSONObject: envelope)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

    private func decodedCompleted(_ data: Data) throws -> [String: Any] {
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["state"] as? String, "completed")
        return try XCTUnwrap(root["value"] as? [String: Any])
    }

    // MARK: - 1. Real 512-model staged create through the REAL router

    func testStaged512ModelCreateCommitsThroughOriginalChainAndProjectsBoundedSummary()
        async throws
    {
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        let router = ModelConfigurationCommandRouter(facade: facade)
        let reference = try stageModels(count: 512, createIntent: true, baseVersion: "0")
        let payload: [String: Any] = [
            "secretIntent": "clear", // new-provider create with no key
            "candidate": refCandidateDict(modelSetRef: reference, createIntent: true),
        ]
        let response = await router.handle(command: "config.provider.save",
                                           envelope: try Self.envelope(payload: payload,
                                                              revision: nil))
        let value = try decodedCompleted(response)
        XCTAssertEqual(value["state"] as? String, "committed")
        XCTAssertEqual(value["providerID"] as? String, providerID.uuidString)
        // 512 full ModelProfile objects cannot fit the proven frame: the
        // output is the EXPLICIT bounded summary — never a truncation.
        XCTAssertEqual(value["projection"] as? String, "summary")
        XCTAssertEqual(value["canonicalModelCount"] as? Int, 512)
        XCTAssertEqual((value["canonicalModels"] as? [Any])?.count, 0)
        XCTAssertEqual(value["deletedModelCount"] as? Int, 0)
        XCTAssertEqual(value["disabledModelCount"] as? Int, 0)
        // The ACTUAL persisted advanced revision (MC-R1), never optimistic.
        let revision = try XCTUnwrap(value["revision"] as? [String: Any])
        XCTAssertEqual(revision["resourceID"] as? String,
                       "provider.\(providerID.uuidString)")
        XCTAssertEqual(revision["version"] as? String, "1")
        // Settlement flags survive the summary unchanged.
        XCTAssertEqual(value["syncPending"] as? Bool, false)
        XCTAssertEqual(value["presetSidecarRecorded"] as? Bool, true)
        XCTAssertEqual(value["writeIntentFinalized"] as? Bool, true)
        XCTAssertEqual(value["leaseAdmissionCloseFailed"] as? Bool, false)
        // Output fits the proven carrier bound with the documented margin
        // below the 47_616 item ceiling — measured through the ACTUAL
        // RuntimeEffectItem frame-cost path the mailbox enforces (the same
        // max(wire, canonical) math whose refusal produced the old
        // payloadTooLarge→failed(frameBudgetExceeded) false terminal), not
        // just the router-local size guess.
        let wire = FacadeFrameBudget.serializedBytes(value)
        let canonical = FacadeFrameBudget.canonicalSerializedBytes(value) ?? wire
        XCTAssertLessThanOrEqual(max(wire, canonical),
                                 ModelConfigurationCommandRouter.maximumCommittedValueBytes)
        let item = RuntimeEffectItem(sequence: 1, kind: .accepted, code: nil,
                                     detail: nil, page: nil,
                                     value: DesignJSONValue.from(foundation: value))
        XCTAssertLessThanOrEqual(item.encodedBytes,
                                 FacadeEffectPump.Limits.maximumItemEncodedBytes,
                                 "a committed C1 terminal must remain appendable")
        // Effects: real durable rows, ZERO secret writes (clear/create has
        // no key material).
        let models = try await ModelConfigurationStore(database: database)
            .models(providerID: providerID)
        XCTAssertEqual(models.count, 512)
        let row = try await ModelConfigurationStore(database: database)
            .provider(id: providerID)
        XCTAssertNotNil(row)
        XCTAssertNil(row?.secretRef)
        XCTAssertTrue(gateway.snapshot().writes.isEmpty)
    }

    func testSmallInlineSaveKeepsLegacyFullProjectionWithCounts() async throws {
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        let router = ModelConfigurationCommandRouter(facade: facade)
        // One tiny model inline: the FULL legacy shape (no summary marker)
        // plus the additive counts.
        let model = try ConfigModelSnapshot.jsonObject(makeModel(index: 0))
        let payload: [String: Any] = [
            "secretIntent": "clear",
            "candidate": [
                "id": providerID.uuidString,
                "kind": "openAI",
                "wireProtocol": "openai-chat-completions",
                "baseURL": "https://api.example.invalid/v1",
                "displayName": "Small",
                "syncEnabled": false,
                "selectedModels": [model],
                "managedCapabilities": ModelCapabilities.text.rawValue,
                "serviceRoleIsConversation": true,
                "createIntent": true,
            ],
        ]
        let value = try decodedCompleted(await router.handle(
            command: "config.provider.save",
            envelope: try Self.envelope(payload: payload, revision: nil)))
        XCTAssertEqual(value["state"] as? String, "committed")
        XCTAssertNil(value["projection"])
        XCTAssertEqual((value["canonicalModels"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(value["canonicalModelCount"] as? Int, 1)
        let item = RuntimeEffectItem(sequence: 1, kind: .accepted, code: nil,
                                     detail: nil, page: nil,
                                     value: DesignJSONValue.from(foundation: value))
        XCTAssertLessThanOrEqual(item.encodedBytes,
                                 FacadeEffectPump.Limits.maximumItemEncodedBytes)
    }

    // MARK: - 2. Compact metadata keep on a 512-model profile

    private func seedLargeProfile(models: Int = 512) async throws -> ProviderProfile {
        var row = ProviderProfile(
            id: providerID,
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://api.example.invalid/v1")!,
            displayName: "Large Profile",
            secretRef: SecretReference(
                keychainAccount: "provider.\(providerID.uuidString)",
                synchronizable: false),
            region: nil,
            nonSecretHeaders: ["X-Org": "kept"],
            isEnabled: false,
            allowsPlainHTTP: false,
            toolNameCompatibility: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            syncRevision: 0)
        let store = ModelConfigurationStore(database: database)
        let all = (0..<models).map { makeModel(index: $0) }
        // No expectedState: the ORIGINAL ungated bundle write persists the
        // profile verbatim, so the durable revision stays at the seeded 0.
        _ = try await store.saveProviderBundle(provider: row, models: all,
                                               managedCapabilities: [.text, .tools])
        _ = row // silence mutation warning; the persisted row is re-read below
        let persisted = try await store.provider(id: providerID)
        return try XCTUnwrap(persisted)
    }

    private func snapshotModelDigests() async throws -> [UUID: String] {
        let models = try await ModelConfigurationStore(database: database)
            .models(providerID: providerID)
        var digests: [UUID: String] = [:]
        for model in models {
            digests[model.id] = try ConfigModelSnapshot.digest(model)
        }
        return digests
    }

    func testMetadataKeepTogglesLargeProfilePreservingEveryModelAndSecretRef()
        async throws
    {
        let persisted = try await seedLargeProfile()
        XCTAssertEqual(persisted.isEnabled, false)
        let beforeDigests = try await snapshotModelDigests()
        XCTAssertEqual(beforeDigests.count, 512)
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        let router = ModelConfigurationCommandRouter(facade: facade)
        let payload: [String: Any] = [
            "secretIntent": "keep",
            "metadata": ["id": providerID.uuidString, "isEnabled": true],
        ]
        let value = try decodedCompleted(await router.handle(
            command: "config.provider.save",
            envelope: try Self.envelope(payload: payload,
                               revision: ("provider.\(providerID.uuidString)", "0"))))
        XCTAssertEqual(value["state"] as? String, "committed")
        XCTAssertEqual(value["metadataOnly"] as? Bool, true)
        let revision = try XCTUnwrap(value["revision"] as? [String: Any])
        // ACTUAL committed advanced revision (base+1), never optimistic.
        XCTAssertEqual(revision["version"] as? String, "1")
        let store = ModelConfigurationStore(database: database)
        let afterRow = try await store.provider(id: providerID)
        let after = try XCTUnwrap(afterRow)
        XCTAssertEqual(after.isEnabled, true)
        XCTAssertEqual(after.syncRevision, 1)
        // EVERY other persisted field byte-identical.
        XCTAssertEqual(after.id, persisted.id)
        XCTAssertEqual(after.kind, persisted.kind)
        XCTAssertEqual(after.wireProtocol, persisted.wireProtocol)
        XCTAssertEqual(after.baseURL, persisted.baseURL)
        XCTAssertEqual(after.displayName, persisted.displayName)
        XCTAssertEqual(after.region, persisted.region)
        XCTAssertEqual(after.nonSecretHeaders, persisted.nonSecretHeaders)
        XCTAssertEqual(after.allowsPlainHTTP, persisted.allowsPlainHTTP)
        XCTAssertEqual(after.toolNameCompatibility, persisted.toolNameCompatibility)
        XCTAssertEqual(after.createdAt, persisted.createdAt)
        XCTAssertEqual(after.secretRef?.keychainAccount,
                       persisted.secretRef?.keychainAccount)
        XCTAssertEqual(after.secretRef?.synchronizable,
                       persisted.secretRef?.synchronizable)
        XCTAssertGreaterThan(after.updatedAt, persisted.updatedAt)
        // Every model row untouched: digests equal, count equal.
        let afterDigests = try await snapshotModelDigests()
        XCTAssertEqual(afterDigests, beforeDigests)
        // NO secret read, NO secret write, no ledger activity.
        XCTAssertTrue(gateway.snapshot().writes.isEmpty)
    }

    /// Full existing-row saves must retain every staged model while the
    /// ORIGINAL secret chain changes Keep -> Clear -> Set. Metadata-only
    /// toggles and create-without-key do not prove these transitions.
    func testExistingStaged512KeepsClearsAndSetsThroughOriginalSecretChain() async throws {
        let initial = try await seedLargeProfile()
        let reference = ConfigSecretIdentity.providerOpaqueReference(for: try XCTUnwrap(initial.secretRef))
        let syntheticOldKey = Data("SYNTHETIC_OLD_LARGE_PROFILE_KEY".utf8)
        let syntheticNewKey = Data("SYNTHETIC_NEW_LARGE_PROFILE_KEY".utf8)
        let gateway = IngressTestGateway()
        gateway.seed(reference, syntheticOldKey)
        let facade = makeFacade(gateway: gateway)
        let router = ModelConfigurationCommandRouter(facade: facade)
        let originalDigests = try await snapshotModelDigests()
        XCTAssertEqual(originalDigests.count, 512)
        var revision = initial.syncRevision
        for intent in ["keep", "clear", "set"] {
            let frozen = try stageModels(count: 512, createIntent: false,
                                         baseVersion: String(revision))
            var candidate = refCandidateDict(modelSetRef: frozen, createIntent: false)
            candidate["nonSecretHeaders"] = initial.nonSecretHeaders
            candidate["managedCapabilities"] = ModelCapabilities.text.union(.tools).rawValue
            candidate["isEnabled"] = initial.isEnabled
            candidate["toolNameCompatibility"] = initial.toolNameCompatibility
            let writesBefore = gateway.snapshot().writes.count
            let deletesBefore = gateway.snapshot().deletes.count
            let payload: [String: Any]
            if intent == "set" {
                let token = try submitStagedSetIntent(candidate: candidate,
                                                      secret: syntheticNewKey,
                                                      revision: revision)
                payload = ["secretIntent": "set", "ingressToken": token]
            } else {
                payload = ["secretIntent": intent, "candidate": candidate]
            }
            let reply = await router.handle(command: "config.provider.save",
                envelope: try Self.envelope(payload: payload,
                    revision: ("provider.\(providerID.uuidString)", String(revision))))
            let value = try decodedCompleted(reply)
            if intent == "clear" {
                // Original clear terminal has its own settlement shape;
                // durable rows/revision below prove the full bundle commit.
                XCTAssertEqual(value["state"] as? String, "cleared")
                XCTAssertEqual(value["secretCleanup"] as? String, "removed")
                XCTAssertEqual(value["cleanupQueuedForRetry"] as? Bool, false)
                XCTAssertEqual(value["pendingReconciliation"] as? Bool, false)
            } else {
                XCTAssertEqual(value["state"] as? String, "committed", "\(intent) must commit the full staged set")
                XCTAssertEqual(value["canonicalModelCount"] as? Int, 512)
                XCTAssertEqual(value["projection"] as? String, "summary")
            }
            revision += 1
            let afterOptional = try await ModelConfigurationStore(database: database).provider(id: providerID)
            let after = try XCTUnwrap(afterOptional)
            XCTAssertEqual(after.syncRevision, revision)
            XCTAssertEqual(after.nonSecretHeaders, initial.nonSecretHeaders)
            XCTAssertEqual(after.isEnabled, initial.isEnabled)
            XCTAssertEqual(after.toolNameCompatibility, initial.toolNameCompatibility)
            let afterDigests = try await snapshotModelDigests()
            XCTAssertEqual(afterDigests, originalDigests, "\(intent) must preserve all512 identities and complete rows")
            let operations = gateway.snapshot()
            if intent == "clear" {
                XCTAssertNil(after.secretRef)
                XCTAssertEqual(operations.writes.count, writesBefore)
                XCTAssertEqual(operations.deletes.count, deletesBefore + 1)
                XCTAssertEqual(operations.deletes.last, reference)
            } else {
                XCTAssertEqual(after.secretRef, initial.secretRef)
                XCTAssertEqual(operations.deletes.count, deletesBefore)
                XCTAssertEqual(operations.writes.count, writesBefore + (intent == "set" ? 1 : 0))
                if intent == "set" {
                    XCTAssertEqual(operations.writes.last?.reference, reference)
                    XCTAssertEqual(operations.writes.last?.bytes, syntheticNewKey)
                }
            }
            // The accepted terminal already owns the typed values; drop
            // the unconsumed RAM record before the next editor revision.
            ProviderModelSetRegistry.shared.cancelAll(routeToken: liveToken)
        }
    }

    private func submitStagedSetIntent(candidate: [String: Any], secret: Data,
                                        revision: Int64) throws -> String {
        let intent: [String: Any] = [
            "subject": ["kind": SubjectKind.providerSave.rawValue, "id": providerID.uuidString],
            "route": ["token": "route-a", "generation": UInt64(5)],
            "intent": "set", "candidate": candidate,
            "baseRevision": ["resourceID": "provider.\(providerID.uuidString)",
                             "version": String(revision)],
        ]
        var bytes = try JSONSerialization.data(withJSONObject: intent, options: [.sortedKeys])
        XCTAssertLessThanOrEqual(bytes.count, SecretSaveIntentLimits.maximumIntentJSONBytes)
        bytes.append(0)
        var token = [CChar](repeating: 0, count: 64)
        let status: Int32 = bytes.withUnsafeBytes { raw in
            secret.withUnsafeBytes { key in
                token.withUnsafeMutableBufferPointer { output in
                    floeSecretSaveIntentSubmit(raw.bindMemory(to: CChar.self).baseAddress,
                        key.bindMemory(to: UInt8.self).baseAddress, Int32(secret.count),
                        output.baseAddress, 40)
                }
            }
        }
        XCTAssertEqual(status, 0, "synthetic staged credential intent must be admitted")
        return String(cString: token)
    }

    // MARK: - 3. Mixed/malformed forms refuse BEFORE any effect

    func testMetadataMixedAndMalformedFormsRefusePreEffect() async throws {
        _ = try await seedLargeProfile(models: 1)
        let beforeDigests = try await snapshotModelDigests()
        let beforeRow = try await ModelConfigurationStore(database: database)
            .provider(id: providerID)
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        let router = ModelConfigurationCommandRouter(facade: facade)
        let metadata: [String: Any] = ["id": providerID.uuidString, "isEnabled": true]
        let inlineCandidate: [String: Any] = [
            "id": providerID.uuidString, "kind": "openAI",
            "wireProtocol": "openai-chat-completions",
            "baseURL": "https://api.example.invalid/v1",
            "displayName": "X", "syncEnabled": false, "selectedModels": [],
            "managedCapabilities": ModelCapabilities.text.rawValue,
            "serviceRoleIsConversation": true,
        ]
        var mixedPayloads: [[String: Any]] = [
            ["secretIntent": "keep", "metadata": metadata, "candidate": inlineCandidate],
            ["secretIntent": "keep", "metadata": metadata, "ingressToken": "int:v1:0000000000000000000000000000abcd"],
            ["secretIntent": "set", "ingressToken": "int:v1:0000000000000000000000000000abcd", "metadata": metadata],
            ["secretIntent": "clear", "candidate": inlineCandidate, "metadata": metadata],
            ["secretIntent": "keep", "metadata": ["id": providerID.uuidString,
                                                  "isEnabled": "true"]],
            ["secretIntent": "keep", "metadata": ["id": "not-a-uuid", "isEnabled": true]],
            ["secretIntent": "keep", "metadata": ["id": providerID.uuidString,
                                                  "isEnabled": true, "extra": 1]],
            // Candidate representation XOR: both or neither.
            ["secretIntent": "keep", "candidate": [
                "id": providerID.uuidString, "kind": "openAI",
                "wireProtocol": "openai-chat-completions",
                "baseURL": "https://api.example.invalid/v1",
                "displayName": "X", "syncEnabled": false,
                "selectedModels": [], "modelSetRef": "ms:v1:" + String(repeating: "0", count: 32)
                    + "." + String(repeating: "0", count: 64),
                "managedCapabilities": ModelCapabilities.text.rawValue,
                "serviceRoleIsConversation": true,
            ]],
            ["secretIntent": "keep", "candidate": inlineCandidateMissingModels()],
        ]
        for payload in mixedPayloads {
            let data = await router.handle(command: "config.provider.save",
                                           envelope: try Self.envelope(payload: payload,
                                                              revision: nil))
            let root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNotNil(root["errorCode"], "form must refuse: \(payload.keys)")
            XCTAssertEqual(root["state"] as? String, nil)
        }
        _ = mixedPayloads // silence unused when loop consumes
        // Nothing changed anywhere.
        let after = try await ModelConfigurationStore(database: database)
            .provider(id: providerID)
        XCTAssertEqual(after?.syncRevision, beforeRow?.syncRevision)
        XCTAssertEqual(after?.isEnabled, beforeRow?.isEnabled)
        let afterDigests = try await snapshotModelDigests()
        XCTAssertEqual(afterDigests, beforeDigests)
        XCTAssertTrue(gateway.snapshot().writes.isEmpty)
    }

    private func inlineCandidateMissingModels() -> [String: Any] {
        [
            "id": providerID.uuidString, "kind": "openAI",
            "wireProtocol": "openai-chat-completions",
            "baseURL": "https://api.example.invalid/v1",
            "displayName": "X", "syncEnabled": false,
            "managedCapabilities": ModelCapabilities.text.rawValue,
            "serviceRoleIsConversation": true,
        ]
    }

    // MARK: - 4. Stale/absent revision + pending-owner authority

    func testMetadataStaleMissingRevisionAndMissingRowAreTypedNoOps() async throws {
        _ = try await seedLargeProfile(models: 1)
        let gateway = IngressTestGateway()
        let facade = makeFacade(gateway: gateway)
        let router = ModelConfigurationCommandRouter(facade: facade)
        let metadata: [String: Any] = ["secretIntent": "keep",
                                       "metadata": ["id": providerID.uuidString,
                                                    "isEnabled": true]]
        // Stale base (the seeded row persists at revision 0).
        var data = await router.handle(command: "config.provider.save",
            envelope: try Self.envelope(payload: metadata,
                               revision: ("provider.\(providerID.uuidString)", "9")))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["errorCode"] as? String, "staleRevision")
        // Missing revision.
        data = await router.handle(command: "config.provider.save",
                                   envelope: try Self.envelope(payload: metadata, revision: nil))
        root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["errorCode"] as? String, "invalidEnvelope")
        let reason = root["reason"] as? String ?? ""
        XCTAssertTrue(reason.hasPrefix("providerMetadataEnvelopeRevision")
                      || reason.hasPrefix("providerMetadataRevisionMissing"), reason)
        // Missing row (fresh provider id).
        let otherID = UUID()
        data = await router.handle(command: "config.provider.save",
            envelope: try Self.envelope(payload: ["secretIntent": "keep",
                                         "metadata": ["id": otherID.uuidString,
                                                      "isEnabled": true]],
                               revision: ("provider.\(otherID.uuidString)", "0")))
        root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["errorCode"] as? String, "notFound")
        XCTAssertTrue(gateway.snapshot().writes.isEmpty)
    }

    func testMetadataRespectsExistingOwnershipAndConflictNoBypass() async throws {
        _ = try await seedLargeProfile(models: 1)
        let ownership = ProviderOperationOwnership()
        // A concurrent owner already holds the per-provider save gate.
        guard case .attached(let held) = await ownership.beginOperation(
            providerID: providerID, kind: .save) else {
            return XCTFail("seed begin must attach")
        }
        let facade = makeFacade(gateway: IngressTestGateway(), ownership: ownership)
        let execution = await facade.saveProviderMetadataEnabled(
            providerID: providerID, isEnabled: true,
            envelopeRevision: ConfigRevision.provider(id: providerID, syncRevision: 0))
        guard case .failed(let failed) = execution,
              failed.error.code == .duplicateInFlight else {
            return XCTFail("existing owner gate must refuse: \(execution)")
        }
        // Nothing was written while the owner was held.
        let row = try await ModelConfigurationStore(database: database)
            .provider(id: providerID)
        XCTAssertEqual(row?.isEnabled, false)
        await ownership.endOperation(held)
        // After release the SAME toggle commits with the real advanced revision.
        let execution2 = await facade.saveProviderMetadataEnabled(
            providerID: providerID, isEnabled: true,
            envelopeRevision: ConfigRevision.provider(id: providerID, syncRevision: 0))
        guard case .committed(let committed) = execution2,
              committed.metadataOnly,
              committed.providerRevision.version == "1" else {
            return XCTFail("post-release toggle must commit: \(execution2)")
        }
    }

    // MARK: - 5. Stager chunk/binding mechanics

    func testStagerOrderDuplicateTamperAndBounds() throws {
        let models = (0..<3).map { makeModel(index: $0) }
        let first = try chunkPayload(models)
        let stageID = try ProviderModelSetRegistry.shared.begin(
            providerID: providerID,
            baseResourceID: "provider.\(providerID.uuidString)",
            baseVersion: "0", createIntent: true, routeAssertion: liveToken)
        try ProviderModelSetRegistry.shared.append(
            stageID: stageID, routeAssertion: liveToken, index: 0, chunk: first)
        // Exact idempotent resend converges.
        try ProviderModelSetRegistry.shared.append(
            stageID: stageID, routeAssertion: liveToken, index: 0, chunk: first)
        // Same index, divergent bytes: typed refusal, no partial accept.
        XCTAssertThrowsError(try ProviderModelSetRegistry.shared.append(
            stageID: stageID, routeAssertion: liveToken, index: 0,
            chunk: try chunkPayload([makeModel(index: 90)]))) { error in
            XCTAssertEqual(error as? ProviderModelSetError, .orderViolation)
        }
        // Gap.
        XCTAssertThrowsError(try ProviderModelSetRegistry.shared.append(
            stageID: stageID, routeAssertion: liveToken, index: 2, chunk: first)) { error in
            XCTAssertEqual(error as? ProviderModelSetError, .orderViolation)
        }
        // Malformed row (original codec refuses).
        XCTAssertThrowsError(try ProviderModelSetRegistry.shared.append(
            stageID: stageID, routeAssertion: liveToken, index: 1,
            chunk: Data("[\"not-an-object\"]".utf8))) { error in
            XCTAssertEqual(error as? ProviderModelSetError, .invalidChunk)
        }
        // Over-cap chunk bytes refused before decode.
        XCTAssertThrowsError(try ProviderModelSetRegistry.shared.append(
            stageID: stageID, routeAssertion: liveToken, index: 1,
            chunk: Data(repeating: 0x20, count: ProviderModelSetLimits.maximumChunkBytes + 1))) {
            error in
            XCTAssertEqual(error as? ProviderModelSetError, .chunkTooLarge)
        }
        // Seal count divergence.
        XCTAssertThrowsError(try ProviderModelSetRegistry.shared.seal(
            stageID: stageID, routeAssertion: liveToken, expectedCount: 99)) { error in
            XCTAssertEqual(error as? ProviderModelSetError, .countMismatch)
        }
        let reference = try ProviderModelSetRegistry.shared.seal(
            stageID: stageID, routeAssertion: liveToken, expectedCount: 3)
        XCTAssertTrue(reference.hasPrefix("ms:v1:"))
        XCTAssertNotNil(ProviderModelSetRef.parse(reference))
        // Immutable: append after seal refuses.
        XCTAssertThrowsError(try ProviderModelSetRegistry.shared.append(
            stageID: stageID, routeAssertion: liveToken, index: 1, chunk: first)) { error in
            XCTAssertEqual(error as? ProviderModelSetError, .sealedStateViolation)
        }
        // Re-seal idempotent for the identical count.
        let again = try ProviderModelSetRegistry.shared.seal(
            stageID: stageID, routeAssertion: liveToken, expectedCount: 3)
        XCTAssertEqual(again, reference)
        // Resolve returns the EXACT ordered typed rows and is repeatable.
        let resolved = try ProviderModelSetRegistry.shared.resolve(
            frozenRef: reference, providerID: providerID, createIntent: true,
            baseRevision: nil, isDraftProbe: false)
        XCTAssertEqual(resolved, models)
        let resolvedAgain = try ProviderModelSetRegistry.shared.resolve(
            frozenRef: reference, providerID: providerID, createIntent: true,
            baseRevision: nil, isDraftProbe: false)
        XCTAssertEqual(resolvedAgain, models)
    }

    private func beginFreshStage(id: UUID = UUID()) throws -> String {
        try ProviderModelSetRegistry.shared.begin(
            providerID: id, baseResourceID: "provider.\(id.uuidString)",
            baseVersion: "0", createIntent: true, routeAssertion: liveToken)
    }

    func testStagerCountBoundAndSaturationMatchOriginalLimits() throws {
        // 513 rows: the UNCHANGED native bound refuses typed.
        let stageID = try beginFreshStage(id: providerID)
        var start = 0
        do {
            while start < 513 {
                let end = min(start + 200, 513)
                let chunk = try chunkPayload((start..<end).map { makeModel(index: $0) })
                try ProviderModelSetRegistry.shared.append(
                    stageID: stageID, routeAssertion: liveToken,
                    index: start / 200, chunk: chunk)
                start = end
            }
            return XCTFail("513 rows must refuse")
        } catch let error as ProviderModelSetError {
            XCTAssertEqual(error, .countMismatch)
        }
        // Saturation: two live stages per accepted epoch; a third refuses
        // pre-mutation (the App's re-stage discipline cancels its previous
        // record first, so two is genuine headroom, not a capability cut).
        _ = try beginFreshStage()
        XCTAssertThrowsError(try beginFreshStage()) { error in
            XCTAssertEqual(error as? ProviderModelSetError, .saturated)
        }
    }

    func testStagerExpiryCancelForeignAndRouteReplacement() throws {
        let clock = LockedModelSetTestClock(1_000)
        ProviderModelSetRegistry.clockForTesting = { clock.now() }
        let stageID = try ProviderModelSetRegistry.shared.begin(
            providerID: providerID,
            baseResourceID: "provider.\(providerID.uuidString)",
            baseVersion: "0", createIntent: true, routeAssertion: liveToken)
        try ProviderModelSetRegistry.shared.append(
            stageID: stageID, routeAssertion: liveToken, index: 0,
            chunk: try chunkPayload([makeModel(index: 0)]))
        let reference = try ProviderModelSetRegistry.shared.seal(
            stageID: stageID, routeAssertion: liveToken, expectedCount: 1)
        // Exact-owner cancel requires the stage's own authority.
        XCTAssertFalse(ProviderModelSetRegistry.shared.cancel(
            stageID: stageID, routeAssertion: "rt:v1:ffffffffffffffffffffffffffffffff"))
        XCTAssertTrue(ProviderModelSetRegistry.shared.cancel(
            stageID: stageID, routeAssertion: liveToken))
        XCTAssertThrowsError(try ProviderModelSetRegistry.shared.resolve(
            frozenRef: reference, providerID: providerID, createIntent: true,
            baseRevision: nil, isDraftProbe: false)) { error in
            XCTAssertEqual(error as? ProviderModelSetError, .stageUnavailable)
        }
        // Expiry: un-consumed stages fall out; capacity frees again.
        let stage2 = try ProviderModelSetRegistry.shared.begin(
            providerID: providerID,
            baseResourceID: "provider.\(providerID.uuidString)",
            baseVersion: "0", createIntent: true, routeAssertion: liveToken)
        let reference2 = try ProviderModelSetRegistry.shared.seal(
            stageID: stage2, routeAssertion: liveToken, expectedCount: 0)
        _ = reference2
        clock.advance(ProviderModelSetLimits.stageTTLMillis + 1)
        XCTAssertThrowsError(try ProviderModelSetRegistry.shared.resolve(
            frozenRef: reference2, providerID: providerID, createIntent: true,
            baseRevision: nil, isDraftProbe: false)) { error in
            XCTAssertEqual(error as? ProviderModelSetError, .stageUnavailable)
        }
        // Route replacement / stale epoch: the scripted authority stops
        // answering with the recorded identity.
        let stage3 = try ProviderModelSetRegistry.shared.begin(
            providerID: providerID,
            baseResourceID: "provider.\(providerID.uuidString)",
            baseVersion: "0", createIntent: true, routeAssertion: liveToken)
        try ProviderModelSetRegistry.shared.append(
            stageID: stage3, routeAssertion: liveToken, index: 0,
            chunk: try chunkPayload([makeModel(index: 0)]))
        let reference3 = try ProviderModelSetRegistry.shared.seal(
            stageID: stage3, routeAssertion: liveToken, expectedCount: 1)
        ProviderModelSetRegistry.authorityForTesting = { _ in nil }
        XCTAssertThrowsError(try ProviderModelSetRegistry.shared.resolve(
            frozenRef: reference3, providerID: providerID, createIntent: true,
            baseRevision: nil, isDraftProbe: false)) { error in
            XCTAssertEqual(error as? ProviderModelSetError, .stageUnavailable)
        }
    }

    func testResolveBindingDivergencesAndDigestTamper() throws {
        let stageID = try ProviderModelSetRegistry.shared.begin(
            providerID: providerID,
            baseResourceID: "provider.\(providerID.uuidString)",
            baseVersion: "5", createIntent: false, routeAssertion: liveToken)
        try ProviderModelSetRegistry.shared.append(
            stageID: stageID, routeAssertion: liveToken, index: 0,
            chunk: try chunkPayload([makeModel(index: 0)]))
        let reference = try ProviderModelSetRegistry.shared.seal(
            stageID: stageID, routeAssertion: liveToken, expectedCount: 1)
        // Edit context: revision required + exact.
        XCTAssertThrowsError(try ProviderModelSetRegistry.shared.resolve(
            frozenRef: reference, providerID: providerID, createIntent: false,
            baseRevision: nil, isDraftProbe: false)) { error in
            XCTAssertEqual(error as? ProviderModelSetError, .bindingDivergence)
        }
        XCTAssertThrowsError(try ProviderModelSetRegistry.shared.resolve(
            frozenRef: reference, providerID: providerID, createIntent: false,
            baseRevision: ConfigRevision(resourceID: "provider.\(providerID.uuidString)",
                                         version: "6"),
            isDraftProbe: false)) { error in
            XCTAssertEqual(error as? ProviderModelSetError, .bindingDivergence)
        }
        // Foreign provider / intent flip.
        XCTAssertThrowsError(try ProviderModelSetRegistry.shared.resolve(
            frozenRef: reference, providerID: UUID(), createIntent: false,
            baseRevision: ConfigRevision(resourceID: "provider.\(UUID().uuidString)",
                                         version: "5"),
            isDraftProbe: false)) { error in
            XCTAssertEqual(error as? ProviderModelSetError, .bindingDivergence)
        }
        XCTAssertThrowsError(try ProviderModelSetRegistry.shared.resolve(
            frozenRef: reference, providerID: providerID, createIntent: true,
            baseRevision: nil, isDraftProbe: false)) { error in
            XCTAssertEqual(error as? ProviderModelSetError, .bindingDivergence)
        }
        // Digest tamper inside the ref (the frozen candidate cannot swap
        // the byte set the stage holds).
        let tampered = "ms:v1:" + String(reference
            .dropFirst("ms:v1:".count).prefix(32)) + "." + String(repeating: "a", count: 64)
        XCTAssertThrowsError(try ProviderModelSetRegistry.shared.resolve(
            frozenRef: tampered, providerID: providerID, createIntent: false,
            baseRevision: ConfigRevision(resourceID: "provider.\(providerID.uuidString)",
                                         version: "5"),
            isDraftProbe: false)) { error in
            XCTAssertEqual(error as? ProviderModelSetError, .digestMismatch)
        }
        // Correct edit context resolves.
        let models = try ProviderModelSetRegistry.shared.resolve(
            frozenRef: reference, providerID: providerID, createIntent: false,
            baseRevision: ConfigRevision(resourceID: "provider.\(providerID.uuidString)",
                                         version: "5"),
            isDraftProbe: false)
        XCTAssertEqual(models.count, 1)
    }

    // MARK: - 6. Draft-probe borrow is non-consuming

    func testProbeBorrowDoesNotConsumeStage() async throws {
        // A sealed stage may be BORROWED by a draft probe resolution (no DB,
        // no vault, no consumption marker) and STILL back a real save.
        let stageID = try ProviderModelSetRegistry.shared.begin(
            providerID: providerID,
            baseResourceID: "provider.\(providerID.uuidString)",
            baseVersion: "0", createIntent: true, routeAssertion: liveToken)
        try ProviderModelSetRegistry.shared.append(
            stageID: stageID, routeAssertion: liveToken, index: 0,
            chunk: try chunkPayload([makeModel(index: 0)]))
        let reference = try ProviderModelSetRegistry.shared.seal(
            stageID: stageID, routeAssertion: liveToken, expectedCount: 1)
        let borrowed = try ProviderModelSetRegistry.shared.resolve(
            frozenRef: reference, providerID: providerID, createIntent: true,
            baseRevision: nil, isDraftProbe: true)
        XCTAssertEqual(borrowed.count, 1)
        let saved = try ProviderModelSetRegistry.shared.resolve(
            frozenRef: reference, providerID: providerID, createIntent: true,
            baseRevision: nil, isDraftProbe: false)
        XCTAssertEqual(saved.count, 1)
        // The probe never wrote anything.
        let row = try await ModelConfigurationStore(database: database)
            .provider(id: providerID)
        XCTAssertNil(row)
    }
}

/// Synchronizes the deterministic clock used by the Sendable production seam.
private final class LockedModelSetTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64
    init(_ value: UInt64) { self.value = value }
    func now() -> UInt64 { lock.withLock { value } }
    func advance(_ delta: UInt64) { lock.withLock { value += delta } }
}
