// SPDX-License-Identifier: MPL-2.0
//
// Main-directed dependency regression (2026-10-19, job-6766e95388c342f0).
//
// ISOLATED SAME-BASE CAS RACE — the finite proof Main requested after the
// model-configuration qualification: the existing isolated case
// (`RuntimeFacadeConfigRepairTests.testReentrantTwoCommitterWrappersAndRealConcurrentDBWriter`)
// races two gated wrappers TOGETHER WITH raw revision-7/42 writers, so its
// "at most one accepted" outcome can be vacuous (raw writers can break the
// observation). This suite adds the complementary case with NO external/raw
// writer at all:
//
//   * REAL file-backed original DatabaseManager (schema 46, real migrations);
//   * TWO distinct `ModelConfigurationCommitter` actors over the SAME DB,
//     both staged `.editAtRevision(0)` from the same observed base;
//   * both ACTUAL commits launched concurrently through a controlled start
//     gate (no sleeps, no mock DB, no raw writer);
//   * EXACTLY ONE success and ONE typed
//     `ModelConfigurationRevisionConflict`;
//   * persisted revision 1 and the WINNER's payload;
//   * a late base-0 attempt writes nothing.
//
// This is a dependency regression distinct from the 53 authored conversation
// history methods; it changes NO model production source.

import XCTest
import Foundation
import GRDB
@testable import FloeAndroidCore
import FloeCore
import FloePersistence
import FloeProviders

final class RuntimeFacadeConfigSameBaseCASRaceTests: XCTestCase {

    private var databaseURL: URL!
    private var database: DatabaseManager!

    private let providerID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    override func setUp() async throws {
        _ = floeSecretGatewayRemove()
        SecretRequestMailbox.shared.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        ProviderOperationCoordinatorRegistry.shared.removeAllForTesting()
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-same-base-cas-\(UUID().uuidString).db")
        database = try DatabaseManager(path: databaseURL)
        try await database.migrate()
        let version = try await database.userVersion()
        XCTAssertEqual(version, DatabaseManager.currentSchemaVersion)
    }

    override func tearDown() async throws {
        _ = floeSecretGatewayRemove()
        SecretRequestMailbox.shared.resetForTesting()
        SecretSaveIntentVault.shared.resetForTesting()
        ProviderOperationCoordinatorRegistry.shared.removeAllForTesting()
        try? await database.close()
        try? FileManager.default.removeItem(at: databaseURL)
    }

    // MARK: - Controlled start gate (the only synchronization; no sleeps)

    private actor StartGate {
        private let expected: Int
        private var arrivals = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(expected: Int) { self.expected = expected }

        /// Suspend until ALL racers have arrived, then release them together.
        func arriveAndWait() async {
            arrivals += 1
            if arrivals >= expected {
                let pending = waiters
                waiters.removeAll()
                for waiter in pending { waiter.resume() }
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    private struct RaceOutcome: Sendable {
        let name: String
        let succeeded: Bool
        let conflict: ModelConfigurationRevisionConflict?
        let otherErrorDescription: String?
    }

    // MARK: - Helpers

    private func store() -> ModelConfigurationStore {
        ModelConfigurationStore(database: database)
    }

    private func seedProvider(revision: Int64, displayName: String) async throws {
        try await store().saveProvider(ProviderProfile(
            id: providerID, kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://cas.example.invalid/v1")!,
            displayName: displayName,
            secretRef: SecretReference(
                keychainAccount: ConfigSecretIdentity.providerAccount(providerID: providerID),
                synchronizable: false),
            syncRevision: revision))
    }

    private func draft(displayName: String, baseRevision: Int64) throws
        -> ProviderSaveRequest
    {
        let draft = ProviderSaveDraft(
            providerID: providerID, kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURLString: "https://cas.example.invalid/v1",
            displayName: displayName, presetID: nil,
            existingSecretRef: SecretReference(
                keychainAccount: ConfigSecretIdentity.providerAccount(providerID: providerID),
                synchronizable: false),
            nonSecretHeaders: [:], isEnabled: true, allowsPlainHTTP: false,
            toolNameCompatibility: false, syncEnabled: false, enteredAPIKey: "",
            selectedModels: [], managedCapabilities: .text,
            serviceRoleIsConversation: true, defaultModelID: nil,
            existingCreatedAt: Date(timeIntervalSince1970: 1),
            existingSyncRevision: baseRevision,
            existingBaseURL: URL(string: "https://cas.example.invalid/v1"),
            existingKind: .openAI)
        guard case .success(let request) = draft.makeRequest() else {
            throw NSError(domain: "SameBaseCAS", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "frozen draft must build a request"
            ])
        }
        return request
    }

    /// Static: an async-let child task may not capture the (non-Sendable)
    /// XCTestCase instance; this helper uses only its parameters.
    private static func race(_ committer: ModelConfigurationCommitter,
                             name: String,
                             request: ProviderSaveRequest,
                             gate: StartGate) async -> RaceOutcome
    {
        await gate.arriveAndWait()
        do {
            _ = try await committer.commitProviderBundle(request)
            return RaceOutcome(name: name, succeeded: true, conflict: nil,
                               otherErrorDescription: nil)
        } catch let conflict as ModelConfigurationRevisionConflict {
            return RaceOutcome(name: name, succeeded: false, conflict: conflict,
                               otherErrorDescription: nil)
        } catch {
            return RaceOutcome(name: name, succeeded: false, conflict: nil,
                               otherErrorDescription: String(describing: error))
        }
    }

    // MARK: - The isolated same-base race

    func testTwoIndependentCommittersSameObservedBaseNoRawWriterExactlyOneWins() async throws {
        try await seedProvider(revision: 0, displayName: "CAS seed")

        // Both frozen requests carry the SAME observed base revision 0 and
        // differ only in payload, so the winner is distinguishable.
        let nameA = "CAS winner A"
        let nameB = "CAS winner B"
        let requestA = try draft(displayName: nameA, baseRevision: 0)
        let requestB = try draft(displayName: nameB, baseRevision: 0)
        XCTAssertEqual(requestA.profile.syncRevision, 0)
        XCTAssertEqual(requestB.profile.syncRevision, 0)
        XCTAssertEqual(requestA.profile.id, requestB.profile.id)

        // TWO DISTINCT committer actors over the SAME file-backed DB, each
        // staged with the SAME observed base. No raw/external writer exists
        // in this test at all.
        let committerA = ModelConfigurationCommitter(database: database)
        let committerB = ModelConfigurationCommitter(database: database)
        await committerA.stageNextBundleExpectation(providerID: providerID,
                                                    expectation: .editAtRevision(0))
        await committerB.stageNextBundleExpectation(providerID: providerID,
                                                    expectation: .editAtRevision(0))

        let gate = StartGate(expected: 2)
        async let racedA = Self.race(committerA, name: nameA, request: requestA, gate: gate)
        async let racedB = Self.race(committerB, name: nameB, request: requestB, gate: gate)
        let outcomes = await [racedA, racedB]

        let successes = outcomes.filter { $0.succeeded }
        let otherErrors = outcomes.filter { !$0.succeeded && $0.conflict == nil }
        let conflicts = outcomes.compactMap { $0.conflict }

        XCTAssertEqual(successes.count, 1,
                       "EXACTLY one same-base commit may be accepted")
        XCTAssertEqual(conflicts.count, 1,
                       "the loser must be the TYPED durable CAS conflict")
        XCTAssertTrue(otherErrors.isEmpty,
                      "no other failure kind may occur: \(otherErrors.map { "\($0.name): \($0.otherErrorDescription ?? "?")" })")
        guard let winner = successes.first, let loserConflict = conflicts.first else {
            return XCTFail("race did not produce one winner and one typed conflict")
        }
        XCTAssertEqual(loserConflict.expected, 0,
                       "the refusal is the durable expected base")
        XCTAssertEqual(loserConflict.observed, 1,
                       "the refusal observed the winner's persisted revision")

        // Persisted state: revision advanced exactly once, payload is the
        // WINNER's (never a merge of both).
        let persistedRaw = try await store().provider(id: providerID)
        let persisted = try XCTUnwrap(persistedRaw)
        XCTAssertEqual(persisted.syncRevision, 1,
                       "the winning same-writer CAS advanced exactly one revision")
        XCTAssertEqual(persisted.displayName ?? "", winner.name,
                       "the persisted payload is the winner's")
        let persistedWins = [nameA, nameB]
            .filter { $0 == (persisted.displayName ?? "") }
        XCTAssertEqual(persistedWins.count, 1, "exactly one candidate produced the row")
        let rowCount = try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM providers") ?? -1
        }
        XCTAssertEqual(rowCount, 1, "the race never duplicated the provider row")

        // LATE base-0 attempt (a third, distinct wrapper): typed conflict and
        // NOTHING is written — revision and payload stay the winner's.
        let late = ModelConfigurationCommitter(database: database)
        await late.stageNextBundleExpectation(providerID: providerID,
                                              expectation: .editAtRevision(0))
        do {
            _ = try await late.commitProviderBundle(requestB)
            XCTFail("a late base-0 attempt must conflict after the winner advanced")
        } catch let conflict as ModelConfigurationRevisionConflict {
            XCTAssertEqual(conflict.expected, 0)
            XCTAssertEqual(conflict.observed, 1)
        } catch {
            XCTFail("late attempt must surface the typed conflict, got \(error)")
        }
        let unchangedRaw = try await store().provider(id: providerID)
        let unchanged = try XCTUnwrap(unchangedRaw)
        XCTAssertEqual(unchanged.syncRevision, 1, "the late refusal mutated nothing")
        XCTAssertEqual(unchanged.displayName ?? "", winner.name,
                       "the late refusal kept the winner's payload")
    }
}
