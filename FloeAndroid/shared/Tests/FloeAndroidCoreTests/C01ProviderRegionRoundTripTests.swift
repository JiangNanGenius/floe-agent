// SPDX-License-Identifier: MPL-2.0
//
// C01 — provider `region` survives a real read-edit-save round trip.
//
// The Android provider editor has no region picker, so a name-only edit used
// to rebuild the frozen ProviderProfile without `region`; the store then
// upserted NULL over the persisted value (silent metadata loss). These tests
// exercise the ACTUAL chain — ProviderSaveCandidate parse -> makeDraft ->
// ProviderSaveDraft.makeRequest -> ModelConfigurationCommitter over the real
// SQLite store — and assert the region, credential owner, endpoints and
// unrelated metadata after commit/readback. No fake store, no second save
// path, no provider/network call.

import XCTest
import Foundation
import GRDB
import FloeCore
import FloePersistence
@testable import FloeAndroidCore

final class C01ProviderRegionRoundTripTests: XCTestCase {

    private let providerID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    private func candidateDictionary(
        providerID: UUID,
        displayName: String = "Original Provider",
        baseURL: String = "https://region.example.invalid/v1",
        region: String? = nil,
        createIntent: Bool = false
    ) throws -> [String: Any] {
        // Mirror the ORIGINAL ModelCapabilities Codable encoding exactly (the
        // proven fixture technique) instead of hand-writing a scalar/object.
        let capsData = try JSONEncoder().encode(ModelCapabilities.text)
        let capsObject = try JSONSerialization.jsonObject(
            with: capsData, options: [.fragmentsAllowed])
        var candidate: [String: Any] = [
            "id": providerID.uuidString,
            "kind": ProviderKind.openAI.rawValue,
            "wireProtocol": ModelProtocol.openAIChatCompletions.rawValue,
            "baseURL": baseURL,
            "displayName": displayName,
            "syncEnabled": false,
            "selectedModels": [[String: Any]](),
            "managedCapabilities": capsObject,
            "serviceRoleIsConversation": true,
        ]
        if let region { candidate["region"] = region }
        if createIntent { candidate["createIntent"] = true }
        return candidate
    }

    private func candidate(_ dictionary: [String: Any]) throws -> ProviderSaveCandidate {
        try ProviderSaveCandidate.parse(dictionary)
    }

    private func seedProvider(
        region: String?,
        syncRevision: Int64 = 3,
        displayName: String = "Original Provider",
        baseURL: String = "https://region.example.invalid/v1"
    ) async throws -> (DatabaseManager, ModelConfigurationStore, ProviderProfile) {
        let stores = try await RB3TestBed.stores(name: #function)
        let store = ModelConfigurationStore(database: stores.database)
        let profile = ProviderProfile(
            id: providerID,
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: baseURL)!,
            displayName: displayName,
            presetID: "region-preset",
            secretRef: SecretReference(
                keychainAccount: ConfigSecretIdentity.providerAccount(providerID: providerID),
                synchronizable: false),
            region: region,
            nonSecretHeaders: ["X-Org": "acme"],
            isEnabled: true,
            allowsPlainHTTP: false,
            toolNameCompatibility: false,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000),
            syncRevision: syncRevision)
        try await store.saveProvider(profile)
        return (stores.database, store, profile)
    }

    private func makeRequest(_ candidate: ProviderSaveCandidate,
                             existing: ProviderProfile?,
                             enteredAPIKey: String = "") throws -> ProviderSaveRequest {
        let draft = candidate.makeDraft(existingRow: existing,
                                        enteredAPIKey: enteredAPIKey)
        switch draft.makeRequest() {
        case .success(let request):
            return request
        case .failure(let report):
            throw NSError(domain: "C01ProviderRegion", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "unexpected validation: \(report.issues)",
            ])
        }
    }

    // MARK: - Read-edit-save

    func testNameOnlyEditPreservesPersistedRegionThroughRealSavePath() async throws {
        let (database, store, existing) = try await seedProvider(region: "eu-west-1")
        let parsed = try candidate(try candidateDictionary(
            providerID: providerID,
            displayName: "Renamed Provider",
            region: "eu-west-1"))
        let request = try makeRequest(parsed, existing: existing)
        XCTAssertEqual(request.profile.region, "eu-west-1")

        let committer = ModelConfigurationCommitter(database: database)
        _ = try await committer.commitProviderBundle(request)
        let readback = await committer.verifyProviderPersisted(request)
        XCTAssertNil(readback, "the committed row must read back exactly")

        let persistedMaybe = try await store.provider(id: providerID)
        let persisted = try XCTUnwrap(persistedMaybe)
        XCTAssertEqual(persisted.region, "eu-west-1", "region must survive the edit")
        XCTAssertEqual(persisted.displayName, "Renamed Provider")
        XCTAssertEqual(persisted.baseURL.absoluteString,
                       "https://region.example.invalid/v1")
        XCTAssertEqual(persisted.presetID, "region-preset")
        XCTAssertEqual(persisted.nonSecretHeaders, ["X-Org": "acme"])
        XCTAssertEqual(persisted.secretRef?.keychainAccount,
                       ConfigSecretIdentity.providerAccount(providerID: providerID),
                       "credential ownership is unchanged")
        XCTAssertEqual(persisted.secretRef?.synchronizable, false)
        XCTAssertEqual(persisted.syncRevision, 4, "the durable CAS advanced by one")
    }

    func testOldClientWithoutRegionKeyAlsoPreservesThePersistedValue() async throws {
        let (database, store, existing) = try await seedProvider(region: "us-east-2")
        // No `region` key at all: the native draft must fall back to the
        // ACTUAL persisted row, never clear it or choose a default.
        let parsed = try candidate(try candidateDictionary(
            providerID: providerID, displayName: "No Region Key"))
        let request = try makeRequest(parsed, existing: existing)
        XCTAssertEqual(request.profile.region, "us-east-2")

        let committer = ModelConfigurationCommitter(database: database)
        _ = try await committer.commitProviderBundle(request)
        let readback = await committer.verifyProviderPersisted(request)
        XCTAssertNil(readback)
        let persistedMaybe = try await store.provider(id: providerID)
        let persisted = try XCTUnwrap(persistedMaybe)
        XCTAssertEqual(persisted.region, "us-east-2")
        XCTAssertEqual(persisted.displayName, "No Region Key")
    }

    func testChangedEndpointAndExplicitNewRegionPersistWithSameCredentialOwner() async throws {
        let (database, store, existing) = try await seedProvider(region: "eu-west-1")
        // A different connection requires a freshly entered key; the CAS
        // target remains the SAME provider row and keychain account.
        let parsed = try candidate(try candidateDictionary(
            providerID: providerID,
            displayName: "Moved Provider",
            baseURL: "https://moved.example.invalid/v1",
            region: "ap-southeast-2"))
        let request = try makeRequest(parsed, existing: existing,
                                      enteredAPIKey: "synthetic-not-a-real-key")
        XCTAssertEqual(request.profile.region, "ap-southeast-2")

        let committer = ModelConfigurationCommitter(database: database)
        _ = try await committer.commitProviderBundle(request)
        let readback = await committer.verifyProviderPersisted(request)
        XCTAssertNil(readback)
        let persistedMaybe = try await store.provider(id: providerID)
        let persisted = try XCTUnwrap(persistedMaybe)
        XCTAssertEqual(persisted.baseURL.absoluteString,
                       "https://moved.example.invalid/v1")
        XCTAssertEqual(persisted.region, "ap-southeast-2")
        XCTAssertEqual(persisted.secretRef?.keychainAccount,
                       ConfigSecretIdentity.providerAccount(providerID: providerID),
                       "the credential stays bound to the same provider identity")
        XCTAssertEqual(persisted.kind, .openAI)
        XCTAssertEqual(persisted.wireProtocol, .openAIChatCompletions)
        XCTAssertEqual(persisted.presetID, "region-preset")
    }

    func testRegionMismatchIsAnActionableReadbackFailure() async throws {
        let (database, _, existing) = try await seedProvider(region: "eu-west-1")
        let parsed = try candidate(try candidateDictionary(
            providerID: providerID, region: "us-west-2"))
        let request = try makeRequest(parsed, existing: existing)
        // Prove the REAL guard still refuses a row whose region differs; the
        // fixed path above is the one that matches.
        let reason = await ModelConfigurationCommitter(database: database)
            .verifyProviderPersisted(request)
        XCTAssertEqual(reason, "providerRegionMismatch")
    }

    func testCreateDefaultsRegionNilAndExplicitRegionPersists() async throws {
        let stores = try await RB3TestBed.stores(name: #function)
        let database = stores.database
        let committer = ModelConfigurationCommitter(database: database)
        let store = ModelConfigurationStore(database: database)

        let plain = try candidate(try candidateDictionary(
            providerID: providerID, createIntent: true))
        let plainRequest = try makeRequest(plain, existing: nil)
        XCTAssertNil(plainRequest.profile.region)
        await committer.stageNextBundleExpectation(
            providerID: providerID, expectation: .createExpectedAbsent)
        _ = try await committer.commitProviderBundle(plainRequest)
        let createdMaybe = try await store.provider(id: providerID)
        let created = try XCTUnwrap(createdMaybe)
        XCTAssertNil(created.region)
        XCTAssertEqual(created.syncRevision, 1)

        let otherID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let parsed = try candidate(try candidateDictionary(
            providerID: otherID, createIntent: true, region: "cn-beijing"))
        let request = try makeRequest(parsed, existing: nil)
        XCTAssertEqual(request.profile.region, "cn-beijing")
        await committer.stageNextBundleExpectation(
            providerID: otherID, expectation: .createExpectedAbsent)
        _ = try await committer.commitProviderBundle(request)
        let explicitMaybe = try await store.provider(id: otherID)
        let explicit = try XCTUnwrap(explicitMaybe)
        XCTAssertEqual(explicit.region, "cn-beijing")
        try await database.close()
    }
}
