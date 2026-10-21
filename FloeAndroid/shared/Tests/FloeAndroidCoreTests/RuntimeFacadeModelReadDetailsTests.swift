// SPDX-License-Identifier: MPL-2.0
//
// DEFERRED native tests for the additive full-row detail read on
// `config.models.list` (job-7d4d4e41017f4391).
// AUTHORED ONLY: NOT compiled, NOT executed by this task (Main batches
// these with the goal/Root coherent cohort). Reuses the doubles declared in
// RuntimeFacadeConfigStoreTests / RuntimeFacadeConfigIngressTests /
// RuntimeFacadeConfigBindingTests (same test target).

import XCTest
import Foundation
import Crypto
@testable import FloeAndroidCore
import FloeCore
import FloePersistence
import FloeProviders
import FloeAndroidWebTools

final class RuntimeFacadeModelReadDetailsTests: XCTestCase {

    private var databaseURL: URL!
    private var database: DatabaseManager!

    override func setUp() async throws {
        _ = floeSecretGatewayRemove()
        SecretRequestMailbox.shared.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-model-read-\(UUID().uuidString).db")
        database = try DatabaseManager(path: databaseURL)
        try await database.migrate()
    }

    override func tearDown() async throws {
        try await database.close()
        try? FileManager.default.removeItem(at: databaseURL)
    }

    private func makeRouter() -> ModelConfigurationCommandRouter {
        let facade = ModelConfigurationFacade(
            database: database,
            gateway: StoreTestGateway(),
            catalogBytes: RuntimeCatalogFixture.validDocument,
            transportAdmission: TransportAdmissionClosed(),
            routeContext: ConfigRouteContextUnavailable(),
            adapters: OriginalProviderAdapterFactory(),
            epochProvider: FixedEpochProvider(epoch: 1),
            ownedWorkRegistry: AlwaysAttachOwnedWorkPort())
        return ModelConfigurationCommandRouter(facade: facade)
    }

    private func makeProvider(_ id: UUID) async throws {
        try await ModelConfigurationStore(database: database).saveProvider(ProviderProfile(
            id: id, kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://modelread.invalid/v1")!,
            displayName: "ModelRead fixture",
            secretRef: SecretReference(keychainAccount: "provider.\(id.uuidString)",
                                       synchronizable: false)))
    }

    /// A LEGAL dense original row: displayName padded so the canonical
    /// ModelProfile JSON reaches exactly `targetBytes` (the proven
    /// ProviderModelSetLimits.maximumModelRowBytes save boundary uses the
    /// same construction).
    private func makeDenseModel(id: UUID, providerID: UUID, remote: String,
                                targetBytes: Int,
                                displayNamePrefix: String = "") throws -> ModelProfile {
        let emptyBytes = try ConfigModelSnapshot.data(
            ModelProfile(id: id, providerID: providerID, remoteModelID: remote,
                         displayName: "",
                         limits: ModelLimits(contextTokens: 4096, maxOutputTokens: 1024),
                         capabilities: [.text, .tools])).count
        let padding = targetBytes - emptyBytes - displayNamePrefix.utf8.count
        guard padding > 0 else { throw FixtureError.badTarget } // defensive, targets chosen above base
        return ModelProfile(id: id, providerID: providerID, remoteModelID: remote,
                            displayName: displayNamePrefix + String(repeating: "x", count: padding),
                            limits: ModelLimits(contextTokens: 4096, maxOutputTokens: 1024),
                            capabilities: [.text, .tools])
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func marker(of pageValue: [String: Any]) throws -> [String: Any] {
        let rows = try XCTUnwrap(pageValue["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1, "a chunk page carries exactly one marker row")
        return try XCTUnwrap(rows.first?[ConfigModelReadLimits.markerKey] as? [String: Any])
    }

    private func completedValue(_ data: Data) throws -> [String: Any] {
        let envelope = try decode(data)
        XCTAssertEqual(envelope["state"] as? String, "completed")
        return try XCTUnwrap(envelope["value"] as? [String: Any])
    }

    // MARK: - The proven gap: a legal saved row above the page budget

    func testSavedOversizedRowReadsBackCompletelyViaModelRead() async throws {
        // 61_439 and 61_440: the EXACT accepted save bounds — the row is
        // legally durable, so it MUST be fully readable afterwards.
        for target in [61_439, 61_440] {
            let providerID = UUID()
            try await makeProvider(providerID)
            let modelID = UUID()
            let store = ModelConfigurationStore(database: database)
            let dense = try makeDenseModel(id: modelID, providerID: providerID,
                                           remote: "dense-\(target)", targetBytes: target)
            try await store.saveModel(dense)

            // Legacy (no opt-in) keeps the proven bounded refusal.
            let legacy = await makeRouter().handle(
                command: "config.models.list",
                envelope: ["payload": ["providerID": providerID.uuidString]])
            let legacyEnvelope = try decode(legacy)
            XCTAssertEqual(legacyEnvelope["errorCode"] as? String, "payloadTooLarge",
                           "legacy oversized first row keeps the typed itemDoesNotFitPage refusal")
            XCTAssertEqual(legacyEnvelope["reason"] as? String, "itemDoesNotFitPage")

            // Opt-in: stream + reconstruct the COMPLETE original row.
            let router = makeRouter()
            var accumulated = Data()
            var cursor: String? = nil
            var marker: [String: Any]?
            var digest: String?
            var rowID: String?
            var total: Int?
            var guardCounter = 0
            while true {
                guardCounter += 1
                XCTAssertLessThanOrEqual(guardCounter, 8, "chunk chain stays bounded")
                var payload: [String: Any] = ["providerID": providerID.uuidString]
                var read: [String: Any] = [:]
                if let cursor, let marker, let digest, let rowID {
                    payload["cursor"] = cursor
                    read["id"] = rowID
                    read["digest"] = digest
                    read["offset"] = try XCTUnwrap(marker["next"] as? String)
                }
                payload["modelRead"] = read
                let response = await router.handle(command: "config.models.list",
                                                   envelope: ["payload": payload])
                let value = try completedValue(response)
                let pageMarker = try self.marker(of: value)
                marker = pageMarker
                rowID = try XCTUnwrap(pageMarker["id"] as? String)
                digest = try XCTUnwrap(pageMarker["digest"] as? String)
                total = Int(try XCTUnwrap(pageMarker["total"] as? String))
                XCTAssertEqual(value["hasMore"] as? Bool,
                               pageMarker["next"] is String,
                               "hasMore is truthful while the row is incomplete")
                cursor = value["nextCursor"] as? String
                let text = try XCTUnwrap(pageMarker["text"] as? String)
                let textBytes = Data(text.utf8)
                XCTAssertLessThanOrEqual(textBytes.count,
                                         ConfigModelReadLimits.maximumChunkRawBytes)
                accumulated.append(textBytes)
                if pageMarker["next"] is NSNull { break }
            }
            XCTAssertEqual(accumulated.count, total, "EOF carries the exact total")

            // The reconstructed bytes are EXACTLY the canonical CURRENT
            // store row (original ModelProfile JSON + actual native
            // revision): full metadata fidelity, byte-for-byte.
            let current = try await ModelConfigurationStore(database: database)
                .models(providerID: providerID)
            XCTAssertEqual(current.count, 1)
            var expectedObject = try ConfigModelSnapshot.jsonObject(current[0])
            expectedObject["revision"] = [
                "resourceID": "model.\(current[0].id.uuidString)",
                "version": try ConfigModelSnapshot.digest(current[0]),
            ]
            let expected = try XCTUnwrap(ConfigJSON.canonicalData(expectedObject))
            XCTAssertEqual(accumulated, expected)
            XCTAssertEqual(ConfigJSON.sha256Hex(expected), digest)

            // And the row reopens for editing: its revision digest passes
            // the ORIGINAL config.model.save CAS gate (round-trip proof:
            // the parse of the reconstructed bytes re-saves unchanged).
            let reopened = try JSONDecoder().decode(ModelProfile.self, from: accumulated)
            XCTAssertEqual(reopened, current[0])
            try await store.saveModel(reopened, expected: current[0])
        }
    }

    func testFittingRowsKeepTheExactLegacyPageShape() async throws {
        let providerID = UUID()
        try await makeProvider(providerID)
        let store = ModelConfigurationStore(database: database)
        try await store.saveModel(ModelProfile(id: UUID(), providerID: providerID,
                                               remoteModelID: "fit-1", displayName: "fit one",
                                               limits: ModelLimits(contextTokens: 4096,
                                                                   maxOutputTokens: 1024)))
        try await store.saveModel(ModelProfile(id: UUID(), providerID: providerID,
                                               remoteModelID: "fit-2", displayName: "fit two",
                                               limits: ModelLimits(contextTokens: 4096,
                                                                   maxOutputTokens: 1024)))
        let legacy = try completedValue(await makeRouter().handle(
            command: "config.models.list",
            envelope: ["payload": ["providerID": providerID.uuidString]]))
        let optedIn = try completedValue(await makeRouter().handle(
            command: "config.models.list",
            envelope: ["payload": ["providerID": providerID.uuidString,
                                   "modelRead": [String: Any]()]]))
        // Opt-in NEVER changes anything for rows that fit: identical
        // document (byte-identical at the wire level).
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys]),
                       try JSONSerialization.data(withJSONObject: optedIn, options: [.sortedKeys]))
    }

    func testMultibyteAndEscapingKeepValidScalarPrefixesAndBudgets() async throws {
        let providerID = UUID()
        try await makeProvider(providerID)
        let store = ModelConfigurationStore(database: database)
        let modelID = UUID()
        let tricky = "🖊️–—\"'\\  é汉 \u{7F}"
        let base = ModelProfile(id: modelID, providerID: providerID,
                                remoteModelID: "tricky", displayName: tricky,
                                limits: ModelLimits(contextTokens: 4096,
                                                    maxOutputTokens: 1024))
        let baseBytes = try ConfigModelSnapshot.data(base).count
        // 12_000 multibyte+quote pairs ≈ 60_000 canonical bytes: above the
        // 49_152 page item budget, inside the 64 KiB raw read carrier.
        let dense = ModelProfile(id: modelID, providerID: providerID,
                                 remoteModelID: "tricky",
                                 displayName: tricky + String(repeating: "汉\"", count: 12_000),
                                 limits: ModelLimits(contextTokens: 4096,
                                                     maxOutputTokens: 1024))
        _ = baseBytes
        try await store.saveModel(dense)
        let router = makeRouter()
        var accumulated = Data()
        var cursor: String?
        var markerDict: [String: Any]?
        var expectedOffset = 0
        while true {
            var payload: [String: Any] = ["providerID": providerID.uuidString]
            var read: [String: Any] = [:]
            if let cursor, let markerDict {
                payload["cursor"] = cursor
                read["id"] = try XCTUnwrap(markerDict["id"] as? String)
                read["digest"] = try XCTUnwrap(markerDict["digest"] as? String)
                read["offset"] = try XCTUnwrap(markerDict["next"] as? String)
            }
            payload["modelRead"] = read
            let response = await router.handle(command: "config.models.list",
                                               envelope: ["payload": payload])
            let pageData = response // Router returns the actual serialized wire Data.
            // Whole RESPONSE (including the {"state":"completed","value":…}
            // wrapper) stays below the frozen 65_536 frame.
            XCTAssertLessThan(pageData.count, 65_536)
            let value = try completedValue(response)
            let rows = try XCTUnwrap(value["rows"] as? [[String: Any]])
            XCTAssertEqual(rows.count, 1)
            let marker = try XCTUnwrap(rows.first?[ConfigModelReadLimits.markerKey] as? [String: Any])
            markerDict = marker
            cursor = value["nextCursor"] as? String
            let text = try XCTUnwrap(marker["text"] as? String)
            let bytes = Data(text.utf8)
            XCTAssertEqual(Int(try XCTUnwrap(marker["offset"] as? String)), expectedOffset,
                           "contiguous byte offsets")
            // No injected U+FFFD anywhere, and valid scalar prefixes
            // (re-encode is byte-exact).
            XCTAssertFalse(text.unicodeScalars.contains(where: { $0 == "\u{FFFD}" }))
            accumulated.append(bytes)
            expectedOffset += bytes.count
            if marker["next"] is NSNull { break }
        }
        let current = try await store.models(providerID: providerID)
        var expectedObject = try ConfigModelSnapshot.jsonObject(current[0])
        expectedObject["revision"] = [
            "resourceID": "model.\(current[0].id.uuidString)",
            "version": try ConfigModelSnapshot.digest(current[0]),
        ]
        XCTAssertEqual(accumulated, try XCTUnwrap(ConfigJSON.canonicalData(expectedObject)))
    }

    // MARK: - Truthful logical row cursor across a mixed provider

    func testNumericRowCursorAdvancesOnlyAfterFullReconstruction() async throws {
        let providerID = UUID()
        try await makeProvider(providerID)
        let store = ModelConfigurationStore(database: database)
        try await store.saveModel(ModelProfile(id: UUID(), providerID: providerID,
                                               remoteModelID: "a", displayName: "a-small",
                                               limits: ModelLimits(contextTokens: 1,
                                                                   maxOutputTokens: 1)))
        let denseID = UUID()
        // displayName prefix "b-" sorts the dense row BETWEEN the two
        // small rows (the store orders rows by display_name, id).
        try await store.saveModel(try makeDenseModel(id: denseID, providerID: providerID,
                                                     remote: "b", targetBytes: 60_000,
                                                     displayNamePrefix: "b-"))
        try await store.saveModel(ModelProfile(id: UUID(), providerID: providerID,
                                               remoteModelID: "c", displayName: "c-small",
                                               limits: ModelLimits(contextTokens: 1,
                                                                   maxOutputTokens: 1)))
        let router = makeRouter()
        // Page 0: the small row, stopping before the oversized row.
        let first = try completedValue(await router.handle(
            command: "config.models.list",
            envelope: ["payload": ["providerID": providerID.uuidString,
                                   "modelRead": [String: Any]()]]))
        let firstRows = try XCTUnwrap(first["rows"] as? [[String: Any]])
        XCTAssertEqual(firstRows.count, 1)
        XCTAssertNil(firstRows[0][ConfigModelReadLimits.markerKey])
        let denseCursor = try XCTUnwrap(first["nextCursor"] as? String)
        XCTAssertEqual(denseCursor, "1")
        // The oversized row: first marker page keeps the row's OWN index.
        var marker = try completedValue(await router.handle(
            command: "config.models.list",
            envelope: ["payload": ["providerID": providerID.uuidString,
                                   "cursor": denseCursor,
                                   "modelRead": [String: Any]()]]))
        var markerDict = try self.marker(of: marker)
        XCTAssertEqual(marker["nextCursor"] as? String, denseCursor,
                       "the numeric row cursor does NOT advance while reconstruction is incomplete")
        XCTAssertEqual(marker["hasMore"] as? Bool, true)
        while markerDict["next"] is String {
            marker = try completedValue(await router.handle(
                command: "config.models.list",
                envelope: ["payload": ["providerID": providerID.uuidString,
                                       "cursor": denseCursor,
                                       "modelRead": [
                                           "id": try XCTUnwrap(markerDict["id"] as? String),
                                           "digest": try XCTUnwrap(markerDict["digest"] as? String),
                                           "offset": try XCTUnwrap(markerDict["next"] as? String),
                                       ]]]))
            markerDict = try self.marker(of: marker)
        }
        // Final chunk advances to the NEXT logical row.
        XCTAssertEqual(marker["nextCursor"] as? String, "2")
        XCTAssertEqual(marker["hasMore"] as? Bool, true)
        // The next page carries the following ORIGINAL row normally.
        let tail = try completedValue(await router.handle(
            command: "config.models.list",
            envelope: ["payload": ["providerID": providerID.uuidString,
                                   "cursor": "2",
                                   "modelRead": [String: Any]()]]))
        let tailRows = try XCTUnwrap(tail["rows"] as? [[String: Any]])
        XCTAssertEqual(tailRows.count, 1)
        XCTAssertNil(tailRows[0][ConfigModelReadLimits.markerKey])
    }

    // MARK: - Fail-closed validation

    func testContinuationRefusalsAreTypedAndSideEffectFree() async throws {
        let providerID = UUID()
        try await makeProvider(providerID)
        let store = ModelConfigurationStore(database: database)
        let modelID = UUID()
        try await store.saveModel(try makeDenseModel(id: modelID, providerID: providerID,
                                                     remote: "r", targetBytes: 55_000))
        let router = makeRouter()
        let first = try completedValue(await router.handle(
            command: "config.models.list",
            envelope: ["payload": ["providerID": providerID.uuidString,
                                   "modelRead": [String: Any]()]]))
        let marker = try self.marker(of: first)
        let goodID = try XCTUnwrap(marker["id"] as? String)
        let goodDigest = try XCTUnwrap(marker["digest"] as? String)
        let next = try XCTUnwrap(marker["next"] as? String)

        // Missing row cursor for a continuation.
        let noCursor = try decode(await router.handle(
            command: "config.models.list",
            envelope: ["payload": ["providerID": providerID.uuidString,
                                   "modelRead": ["id": goodID, "digest": goodDigest,
                                                 "offset": next]]]))
        XCTAssertEqual(noCursor["errorCode"] as? String, "invalidEnvelope")
        XCTAssertEqual(noCursor["reason"] as? String, "modelReadCursorRequired")

        // Foreign model id (identity is the CURRENT row at the index).
        let foreign = try decode(await router.handle(
            command: "config.models.list",
            envelope: ["payload": ["providerID": providerID.uuidString,
                                   "cursor": "0",
                                   "modelRead": ["id": UUID().uuidString,
                                                 "digest": goodDigest, "offset": next]]]))
        XCTAssertEqual(foreign["errorCode"] as? String, "staleRevision")
        XCTAssertEqual(foreign["reason"] as? String, "modelReadRowIdentity")

        // Wrong digest.
        let badDigest = try decode(await router.handle(
            command: "config.models.list",
            envelope: ["payload": ["providerID": providerID.uuidString,
                                   "cursor": "0",
                                   "modelRead": ["id": goodID,
                                                 "digest": String(repeating: "0", count: 64),
                                                 "offset": next]]]))
        XCTAssertEqual(badDigest["errorCode"] as? String, "staleRevision")
        XCTAssertEqual(badDigest["reason"] as? String, "modelReadRowChanged")

        // Foreign provider filter.
        let foreignProvider = UUID()
        try await makeProvider(foreignProvider)
        let cross = try decode(await router.handle(
            command: "config.models.list",
            envelope: ["payload": ["providerID": foreignProvider.uuidString,
                                   "cursor": "0",
                                   "modelRead": ["id": goodID, "digest": goodDigest,
                                                 "offset": next]]]))
        XCTAssertEqual(cross["errorCode"] as? String, "staleRevision")

        // Offset NOT on the deterministic chain: gap (next+1) and replay (0
        // mid-chain continuation is the head and legal; skip-a-chunk is not).
        let gap = try decode(await router.handle(
            command: "config.models.list",
            envelope: ["payload": ["providerID": providerID.uuidString,
                                   "cursor": "0",
                                   "modelRead": ["id": goodID, "digest": goodDigest,
                                                 "offset": String(Int(next)! + 1)]]]))
        XCTAssertEqual(gap["errorCode"] as? String, "invalidEnvelope")
        XCTAssertEqual(gap["reason"] as? String, "modelReadOffsetOutOfOrder")

        // Offset NOT on the chain that is ALSO inside the row (a mid-chain
        // split; for a dense multibyte row the same request refuses as a
        // scalar boundary violation — both are typed, never a chunk).
        let midScalar = try decode(await router.handle(
            command: "config.models.list",
            envelope: ["payload": ["providerID": providerID.uuidString,
                                   "cursor": "0",
                                   "modelRead": ["id": goodID, "digest": goodDigest,
                                                 "offset": "30001"]]]))
        XCTAssertTrue(["modelReadOffsetBoundary", "modelReadOffsetOutOfOrder"]
            .contains((midScalar["reason"] as? String) ?? ""))

        // Deleted row: the whole continuation refuses typed, no bytes.
        try await deleteModelThroughOriginalStore(id: modelID)
        let deleted = try decode(await router.handle(
            command: "config.models.list",
            envelope: ["payload": ["providerID": providerID.uuidString,
                                   "cursor": "0",
                                   "modelRead": ["id": goodID, "digest": goodDigest,
                                                 "offset": next]]]))
        XCTAssertEqual(deleted["errorCode"] as? String, "staleRevision")
        XCTAssertEqual(deleted["reason"] as? String, "modelReadRowMissing")

        // Malformed opt-ins refuse typed and NEVER downgrade to a legacy
        // page (unknown member / wrong shape).
        let unknownMember = try decode(await router.handle(
            command: "config.models.list",
            envelope: ["payload": ["providerID": providerID.uuidString,
                                   "modelRead": ["id": goodID, "digest": goodDigest,
                                                 "offset": next, "extra": "x"]]]))
        XCTAssertEqual(unknownMember["errorCode"] as? String, "invalidEnvelope")
        XCTAssertTrue(((unknownMember["reason"] as? String) ?? "")
            .hasPrefix("unknownField.modelRead"))
        let wrongShape = try decode(await router.handle(
            command: "config.models.list",
            envelope: ["payload": ["providerID": providerID.uuidString,
                                   "modelRead": "begin"]]))
        XCTAssertEqual(wrongShape["errorCode"] as? String, "invalidEnvelope")
        XCTAssertEqual(wrongShape["reason"] as? String, "modelReadShape")
    }

    private enum FixtureError: Error { case badTarget }

    private func deleteModelThroughOriginalStore(id: UUID) async throws {
        // The ORIGINAL store API stays the only durable authority.
        try await database.writer { db in
            _ = try db.execute(sql: "DELETE FROM models WHERE id = ?", arguments: [id.uuidString])
        }
    }

    func testChangedRowCannotMixSnapshots() async throws {
        let providerID = UUID()
        try await makeProvider(providerID)
        let store = ModelConfigurationStore(database: database)
        let modelID = UUID()
        let original = try makeDenseModel(id: modelID, providerID: providerID,
                                          remote: "mut", targetBytes: 55_000)
        try await store.saveModel(original)
        let router = makeRouter()
        let first = try completedValue(await router.handle(
            command: "config.models.list",
            envelope: ["payload": ["providerID": providerID.uuidString,
                                   "modelRead": [String: Any]()]]))
        let marker = try self.marker(of: first)
        // Mutate the row between chunks (same id, changed content).
        var mutated = original
        mutated.displayName = mutated.displayName + "MUTATED"
        try await store.saveModel(mutated)
        let stale = try decode(await router.handle(
            command: "config.models.list",
            envelope: ["payload": ["providerID": providerID.uuidString,
                                   "cursor": "0",
                                   "modelRead": ["id": try XCTUnwrap(marker["id"] as? String),
                                                 "digest": try XCTUnwrap(marker["digest"] as? String),
                                                 "offset": try XCTUnwrap(marker["next"] as? String)]]]))
        XCTAssertEqual(stale["errorCode"] as? String, "staleRevision")
        XCTAssertEqual(stale["reason"] as? String, "modelReadRowChanged")
    }

    // MARK: - No weakening of frozen bounds

    func testFrozenBudgetsAndPinsRemainUnchanged() throws {
        // This package reads streams WITHIN these proven numbers; if any
        // of them ever moves, this pin fails and the gap is re-examined.
        XCTAssertEqual(ConfigPageBudget.maximumPageItemsBytes, 49_152)
        XCTAssertEqual(ConfigPageBudget.maximumCommandPayloadBytes, 61_440)
        XCTAssertEqual(ProviderModelSetLimits.maximumModelRowBytes, 61_440)
        XCTAssertEqual(BridgeV3.maximumBytes, 65_536)
        XCTAssertEqual(ConfigModelReadLimits.maximumChunkRawBytes, 32_768)
        XCTAssertEqual(ConfigModelReadLimits.maximumRawRowBytes, 65_536)
        XCTAssertEqual(ConfigModelReadLimits.maximumMarkerItemBytes,
                       ConfigPageBudget.maximumPageItemsBytes - 2)
    }
}
