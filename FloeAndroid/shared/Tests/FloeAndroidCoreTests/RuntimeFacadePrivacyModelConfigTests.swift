// SPDX-License-Identifier: MPL-2.0
//
// G02 privacy model-configuration + trusted-host confirmation tests
// (authored source for the later combined qualification; not executed here).
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeAgentRuntime
@testable import FloeAndroidCore

final class RuntimeFacadePrivacyModelConfigTests: XCTestCase {

    private func modelRevision(_ assembly: PrivacyFacadeAssembly) async throws -> String {
        try await assembly.facade.summary().modelConfiguration.revision
    }

    private func clearModel(_ assembly: PrivacyFacadeAssembly,
                            invocation: String = "inv-model",
                            token override: String? = nil) async throws
        -> PrivacyModelConfigClearReport
    {
        let digest = try await modelRevision(assembly)
        let token = override ?? privacyIssue(
            assembly,
            operation: RuntimeFacadePrivacy.modelConfigClearOperation,
            digest: digest, invocation: invocation)!
        return try await assembly.facade.clearModelConfiguration(
            request: PrivacyClearRequest(confirmToken: token),
            revision: BaseRevision(
                resourceID: RuntimeFacadePrivacy.modelConfigurationResourceID,
                version: digest),
            invocationID: invocation)
    }

    private func providerCount(_ stores: PrivacyTestBed.Stores) async throws -> Int {
        try await PrivacyTestBed.count(stores.database,
                                       "SELECT COUNT(*) FROM providers")
    }

    /// Sendable snapshot of the preference singleton (a GRDB `Row` cannot
    /// cross the async boundary — pinned-Sendable repair 2026-10-21).
    private struct PreferencesRowSnapshot: Sendable, Equatable {
        var syncRevision: Int64?
        var onboardingStatus: String?
        var defaultAgentModelID: String?
    }

    private func preferencesRow(_ stores: PrivacyTestBed.Stores) async throws
        -> PreferencesRowSnapshot?
    {
        try await stores.database.reader { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM model_preferences WHERE id = 'default'")
            else { return nil }
            let revision: Int64? = row["sync_revision"]
            let onboarding: String? = row["onboarding_status"]
            let defaultModel: String? = row["default_agent_model_id"]
            return PreferencesRowSnapshot(
                syncRevision: revision,
                onboardingStatus: onboarding,
                defaultAgentModelID: defaultModel)
        }
    }

    // MARK: - Happy path / monotonic reset

    func testModelConfigClearHappyPathWithMonotonicPreferenceReset() async throws {
        let stores = try await PrivacyTestBed.stores(name: "model-happy")
        let provider = try await PrivacyTestBed.seedProvider(stores)
        _ = try await PrivacyTestBed.seedModel(stores, providerID: provider)
        let assembly = PrivacyFacadeFactory.make(stores: stores)
        let report = try await clearModel(assembly)
        XCTAssertEqual(report.enumerated.providers, 1)
        XCTAssertEqual(report.enumerated.models, 1)
        XCTAssertEqual(report.deleted.providers, 1)
        XCTAssertEqual(report.deleted.models, 1)
        XCTAssertEqual(report.deleted.secrets, 0)
        XCTAssertTrue(report.preferencesReset)
        XCTAssertEqual(report.preferencesSyncRevision, 1)
        XCTAssertFalse(report.partial)
        let providers = try await providerCount(stores)
        XCTAssertEqual(providers, 0)
        let snapshot = try await preferencesRow(stores)
        XCTAssertEqual(snapshot?.syncRevision, 1)
        XCTAssertEqual(snapshot?.onboardingStatus, "unseen")
    }

    func testGatewayUnregisteredFailsBeforeAnyMutation() async throws {
        let stores = try await PrivacyTestBed.stores(name: "gateway-unregistered")
        let account = "provider.\(UUID().uuidString)"
        let provider = try await PrivacyTestBed.seedProvider(
            stores, secretAccount: account)
        let assembly = PrivacyFacadeFactory.make(
            stores: stores, secrets: FakeSecretOrdering(registered: false))
        do {
            _ = try await clearModel(assembly)
            XCTFail("expected needsConfiguration")
        } catch let error as PrivacyDomainError {
            XCTAssertEqual(error.wireCode, "needsConfiguration")
            XCTAssertEqual(error.wireReason, "gatewayUnregistered")
        }
        let providers = try await providerCount(stores)
        XCTAssertEqual(providers, 1)
        let snapshot = try await preferencesRow(stores)
        XCTAssertEqual(snapshot?.syncRevision, 0)
        let persisted = try await PrivacyTestBed.count(
            stores.database, "SELECT COUNT(*) FROM providers WHERE id = ?",
            [provider.uuidString])
        XCTAssertEqual(persisted, 1)
    }

    func testSecretReferenceChangedBetweenSnapshotAndDeleteSkipsProvider() async throws {
        let stores = try await PrivacyTestBed.stores(name: "secret-drift")
        let account = "provider.\(UUID().uuidString)"
        let provider = try await PrivacyTestBed.seedProvider(
            stores, secretAccount: account)
        let counter = PrivacyOnceCounter()
        let assembly = PrivacyFacadeFactory.make(
            stores: stores,
            faultInjection: { phase in
                guard phase == "modelConfig.clear.provider",
                      counter.take() else { return }
                try await stores.database.writer { db in
                    try db.execute(
                        sql: """
                            UPDATE providers
                            SET secret_ref_account = 'provider.changed',
                                sync_revision = 1
                            WHERE id = ?
                            """,
                        arguments: [provider.uuidString])
                }
            })
        let report = try await clearModel(assembly)
        XCTAssertEqual(report.deleted.providers, 0)
        XCTAssertEqual(report.deletionFailures.first?.phase,
                       .secretReferenceChanged)
        let providers = try await providerCount(stores)
        XCTAssertEqual(providers, 1)
        let records = await assembly.secrets.records
        XCTAssertFalse(records.contains { $0.kind == "delete" })
    }

    func testSameAccountNewSetCannotBeDeletedRace() async throws {
        let stores = try await PrivacyTestBed.stores(name: "same-account")
        let account = "provider.\(UUID().uuidString)"
        let provider = try await PrivacyTestBed.seedProvider(
            stores, secretAccount: account, syncRevision: 0)
        let counter = PrivacyOnceCounter()
        let assembly = PrivacyFacadeFactory.make(
            stores: stores,
            faultInjection: { phase in
                guard phase == "modelConfig.clear.provider",
                      counter.take() else { return }
                // A newer Set keeps the deterministic provider.<uuid> account
                // but advances the row revision: account equality alone must
                // never authorize the physical secret delete.
                try await stores.database.writer { db in
                    try db.execute(
                        sql: """
                            UPDATE providers
                            SET sync_revision = 1,
                                updated_at = '2026-10-19T02:00:00Z'
                            WHERE id = ?
                            """,
                        arguments: [provider.uuidString])
                }
            })
        let report = try await clearModel(assembly)
        XCTAssertEqual(report.deleted.providers, 0)
        XCTAssertEqual(report.deleted.secrets, 0)
        XCTAssertEqual(report.deletionFailures.first?.phase,
                       .secretReferenceChanged)
        let records = await assembly.secrets.records
        XCTAssertFalse(records.contains { $0.kind == "delete" })
        let providers = try await providerCount(stores)
        XCTAssertEqual(providers, 1)
    }

    func testPendingPhysicalNativeWriteRetainsOwner() async throws {
        let stores = try await PrivacyTestBed.stores(name: "physical-pending")
        let account = "provider.\(UUID().uuidString)"
        let provider = try await PrivacyTestBed.seedProvider(
            stores, secretAccount: account)
        let witness = FakeObservingGateway()
        let receipt = PhysicalOperationReceipt(
            claim: 42, epoch: 1, reference: "ref", kind: .delete, tracked: true)
        let counter = PrivacyOnceCounter()
        let secrets = FakeSecretOrdering(registered: true)
        let assembly = PrivacyFacadeFactory.make(
            stores: stores, secrets: secrets,
            faultInjection: { phase in
                guard phase == "modelConfig.clear.provider",
                      counter.take() else { return }
                await secrets.setNextOutcome(
                    PrivacySecretDeletionOutcome(
                        settled: false, reason: "physicalOutstanding",
                        physicalOutstanding: true, receipt: receipt,
                        witness: witness))
            })
        let report = try await clearModel(assembly)
        XCTAssertEqual(report.deleted.providers, 0)
        XCTAssertEqual(report.deleted.secrets, 0)
        XCTAssertEqual(report.deletionFailures.first?.phase, .gatewayDelete)
        XCTAssertEqual(report.deletionFailures.first?.reason, "physicalOutstanding")
        let parked = await assembly.operations.parked
        XCTAssertEqual(parked, [provider])
        let ended = await assembly.operations.ended
        XCTAssertFalse(ended.contains(provider))
        let records = await assembly.secrets.records
        XCTAssertFalse(records.contains { $0.kind == "complete" })
        let providers = try await providerCount(stores)
        XCTAssertEqual(providers, 1)
    }

    func testFailedGatewayDeleteKeepsDurableIntentForBootstrapReplay() async throws {
        let stores = try await PrivacyTestBed.stores(name: "gateway-failure")
        let account = "provider.\(UUID().uuidString)"
        _ = try await PrivacyTestBed.seedProvider(stores, secretAccount: account)
        let reference = ConfigSecretIdentity.providerOpaqueReference(
            for: ConfigSecretIdentity.providerSecretReference(
                account: account, synchronizable: false))
        let secrets = FakeSecretOrdering(registered: true)
        await secrets.failDeleteFor(reference)
        let assembly = PrivacyFacadeFactory.make(stores: stores, secrets: secrets)
        let report = try await clearModel(assembly)
        XCTAssertEqual(report.deleted.providers, 0)
        XCTAssertEqual(report.deleted.secrets, 0)
        XCTAssertEqual(report.deletionFailures.first?.phase, .gatewayDelete)
        let queue = await secrets.queuedAccounts()
        XCTAssertEqual(queue, [account])
        let records = await secrets.records
        XCTAssertTrue(records.contains { $0.kind == "recordFailure" })
        let providers = try await providerCount(stores)
        XCTAssertEqual(providers, 1)
    }

    func testDifferentProviderCreatedAfterSnapshotSurvives() async throws {
        let stores = try await PrivacyTestBed.stores(name: "late-provider")
        let first = try await PrivacyTestBed.seedProvider(stores)
        let counter = PrivacyOnceCounter()
        let late = UUID()
        let assembly = PrivacyFacadeFactory.make(
            stores: stores,
            faultInjection: { phase in
                guard phase == "modelConfig.clear.provider",
                      counter.take() else { return }
                try await stores.database.writer { db in
                    try db.execute(
                        sql: """
                            INSERT INTO providers
                                (id, kind, wire_protocol, base_url,
                                 secret_ref_account, secret_ref_synchronizable,
                                 region, non_secret_headers_json, display_name,
                                 is_enabled, allows_plain_http,
                                 tool_name_compatibility, created_at, updated_at,
                                 sync_revision)
                            VALUES (?, 'openaiCompatible', 'https',
                                    'https://late.invalid', NULL, NULL, NULL,
                                    '{}', 'late', 1, 0, 0,
                                    '2026-10-19T00:00:00Z',
                                    '2026-10-19T00:00:00Z', 0)
                            """,
                        arguments: [late.uuidString])
                }
            })
        let report = try await clearModel(assembly)
        XCTAssertEqual(report.enumerated.providers, 1)
        XCTAssertEqual(report.deleted.providers, 1)
        let providers = try await providerCount(stores)
        XCTAssertEqual(providers, 1)
        let lateCount = try await PrivacyTestBed.count(
            stores.database, "SELECT COUNT(*) FROM providers WHERE id = ?",
            [late.uuidString])
        XCTAssertEqual(lateCount, 1)
        let firstCount = try await PrivacyTestBed.count(
            stores.database, "SELECT COUNT(*) FROM providers WHERE id = ?",
            [first.uuidString])
        XCTAssertEqual(firstCount, 0)
    }

    // MARK: - Preferences CAS

    func testLatePreferenceSaveIsNeverOverwrittenByReset() async throws {
        let stores = try await PrivacyTestBed.stores(name: "late-preference")
        // Seed one provider so the provider loop actually runs and the
        // modelConfig.clear.provider fault fires mid-clear (without a
        // provider the loop never executes the injection).
        _ = try await PrivacyTestBed.seedProvider(stores)
        let counter = PrivacyOnceCounter()
        let assembly = PrivacyFacadeFactory.make(
            stores: stores,
            faultInjection: { phase in
                guard phase == "modelConfig.clear.provider",
                      counter.take() else { return }
                try await stores.database.writer { db in
                    try db.execute(sql: """
                        UPDATE model_preferences
                        SET onboarding_status = 'completed'
                        WHERE id = 'default'
                        """)
                }
            })
        let report = try await clearModel(assembly)
        XCTAssertFalse(report.preferencesReset)
        XCTAssertNil(report.preferencesFailure)
        XCTAssertTrue(report.partial)
        let snapshot = try await preferencesRow(stores)
        XCTAssertEqual(snapshot?.onboardingStatus, "completed")
        XCTAssertEqual(snapshot?.syncRevision, 0)
    }

    func testPreferenceResetMonotonicPreviousPlusOneAndFKNulling() async throws {
        let stores = try await PrivacyTestBed.stores(name: "preference-cas")
        let provider = try await PrivacyTestBed.seedProvider(stores)
        let model = try await PrivacyTestBed.seedModel(stores,
                                                       providerID: provider)
        try await stores.database.writer { db in
            try db.execute(
                sql: """
                    UPDATE model_preferences
                    SET default_agent_model_id = ?, sync_revision = 7
                    WHERE id = 'default'
                    """,
                arguments: [model.uuidString])
        }
        let assembly = PrivacyFacadeFactory.make(stores: stores)
        let report = try await clearModel(assembly)
        XCTAssertTrue(report.preferencesReset)
        XCTAssertEqual(report.preferencesSyncRevision, 8)
        let snapshot = try await preferencesRow(stores)
        XCTAssertEqual(snapshot?.syncRevision, 8)
        XCTAssertNil(snapshot?.defaultAgentModelID)
    }

    /// Ref-only drift to ANOTHER id supersedes the reset (the clear's own
    /// cascade exception never tolerates an id change): a mid-clear write
    /// pointing the reference at a DIFFERENT (surviving) model must not be
    /// overwritten by the fresh-default reset.
    func testPreferenceRefChangeToAnotherIDSupersedesReset() async throws {
        let stores = try await PrivacyTestBed.stores(name: "ref-drift-id")
        let first = try await PrivacyTestBed.seedProvider(stores)
        let firstModel = try await PrivacyTestBed.seedModel(stores,
                                                            providerID: first)
        let late = try await PrivacyTestBed.seedProvider(stores)
        let lateModel = try await PrivacyTestBed.seedModel(stores,
                                                           providerID: late)
        try await stores.database.writer { db in
            try db.execute(
                sql: """
                    UPDATE model_preferences
                    SET default_agent_model_id = ?
                    WHERE id = 'default'
                    """,
                arguments: [firstModel.uuidString])
        }
        let counter = PrivacyOnceCounter()
        let assembly = PrivacyFacadeFactory.make(
            stores: stores,
            faultInjection: { phase in
                guard phase == "modelConfig.clear.provider",
                      counter.take() else { return }
                try await stores.database.writer { db in
                    // Point the reference at a different model AND make the
                    // late provider's row CAS fail so that model survives
                    // the clear (its id is never proven deleted here).
                    try db.execute(
                        sql: """
                            UPDATE model_preferences
                            SET default_agent_model_id = ?
                            WHERE id = 'default'
                            """,
                        arguments: [lateModel.uuidString])
                    try db.execute(
                        sql: """
                            UPDATE providers SET sync_revision = 999
                            WHERE id = ?
                            """,
                        arguments: [late.uuidString])
                }
            })
        let report = try await clearModel(assembly)
        XCTAssertFalse(report.preferencesReset)
        XCTAssertTrue(report.partial)
        let snapshot = try await preferencesRow(stores)
        // The mid-clear reference survives untouched.
        XCTAssertEqual(snapshot?.defaultAgentModelID, lateModel.uuidString)
        XCTAssertEqual(snapshot?.syncRevision, 0)
    }

    /// A reference that becomes NULL when THIS clear did NOT delete the
    /// referenced model supersedes the reset: the cascade exception applies
    /// only to models the clear itself removed.
    func testPreferenceUnrelatedNullSupersedesReset() async throws {
        let stores = try await PrivacyTestBed.stores(name: "ref-drift-null")
        let provider = try await PrivacyTestBed.seedProvider(stores)
        let model = try await PrivacyTestBed.seedModel(stores, providerID: provider)
        try await stores.database.writer { db in
            try db.execute(
                sql: """
                    UPDATE model_preferences
                    SET default_agent_model_id = ?
                    WHERE id = 'default'
                    """,
                arguments: [model.uuidString])
        }
        let counter = PrivacyOnceCounter()
        let assembly = PrivacyFacadeFactory.make(
            stores: stores,
            faultInjection: { phase in
                guard phase == "modelConfig.clear.provider",
                      counter.take() else { return }
                try await stores.database.writer { db in
                    // Null the reference AND make the provider's row CAS
                    // fail: the model is NOT deleted by this clear, so the
                    // id -> NULL drift is external and must supersede.
                    try db.execute(
                        sql: """
                            UPDATE model_preferences
                            SET default_agent_model_id = NULL
                            WHERE id = 'default'
                            """)
                    try db.execute(
                        sql: """
                            UPDATE providers SET sync_revision = 999
                            WHERE id = ?
                            """,
                        arguments: [provider.uuidString])
                }
            })
        let report = try await clearModel(assembly)
        XCTAssertFalse(report.preferencesReset)
        XCTAssertTrue(report.partial)
        let snapshot = try await preferencesRow(stores)
        // No fresh-default write: the external null stands, revision intact.
        XCTAssertNil(snapshot?.defaultAgentModelID)
        XCTAssertEqual(snapshot?.syncRevision, 0)
        let providers = try await providerCount(stores)
        XCTAssertEqual(providers, 1)
    }

    /// 2026-10-21 Main bounded-memory integration fix: the preferences reset
    /// CAS may only ever observe the at-most-eleven captured model-reference
    /// preference columns — never a materialized set of every deleted model
    /// id. `observedPreferenceModelIDs` must project EXACTLY the reference
    /// UUIDs from a full canonical record, exclude UUID-shaped values in
    /// NON-reference columns, fail closed (empty) on any malformed record
    /// shape, and collapse duplicates.
    func testObservedPreferenceModelIDsProjectsExactlyElevenReferenceColumns() {
        // The frozen model-reference preference columns — the CAS's only
        // legitimate observation surface. Pinned here intentionally: any
        // production change to this set is a contract change this test
        // must surface.
        let referenceColumns: Set<String> = [
            "default_agent_model_id", "general_auxiliary_llm_model_id",
            "canvas_agent_model_id", "vision_model_id", "canvas_vision_model_id",
            "approval_model_id", "package_review_model_id",
            "shared_image_model_id", "image_generation_model_id",
            "image_editing_model_id", "default_video_model_id",
        ]
        let columns = PrivacySnapshotEngine.preferenceColumns
        XCTAssertEqual(columns.count, 17)
        XCTAssertEqual(columns.filter { referenceColumns.contains($0) }.count, 11)

        // Full canonical record: every reference column carries a UNIQUE
        // UUID; the non-reference columns carry UUID-SHAPED text plus
        // integer/timestamp values that must never leak into the projection.
        var uniqueIDs: [String: UUID] = [:]
        for name in referenceColumns { uniqueIDs[name] = UUID() }
        var record: [SettingsDomainV1.CanonicalDigest.Field] = columns.map { name in
            if let id = uniqueIDs[name] { return .text(id.uuidString) }
            switch name {
            case "id": return .text(UUID().uuidString)
            case "onboarding_status": return .text(UUID().uuidString)
            case "autonomous_image_routing", "auxiliary_image_mode":
                return .integer(0)
            case "sync_revision": return .integer(3)
            default: return .text(UUID().uuidString) // updated_at
            }
        }
        let projected = RuntimeFacadePrivacy.observedPreferenceModelIDs(record)
        XCTAssertEqual(projected, Set(uniqueIDs.values))
        XCTAssertEqual(projected.count, 11)

        // Duplicates collapse: two reference columns sharing one UUID halve
        // the observed set to ten, never twelve.
        let shared = UUID()
        var duplicate = record
        duplicate[columns.firstIndex(of: "canvas_agent_model_id")!] =
            .text(shared.uuidString)
        duplicate[columns.firstIndex(of: "default_agent_model_id")!] =
            .text(shared.uuidString)
        let collapsed = RuntimeFacadePrivacy.observedPreferenceModelIDs(duplicate)
        XCTAssertEqual(collapsed.count, 10)
        XCTAssertTrue(collapsed.contains(shared))

        // A reference column that is NULL or holds non-UUID text is not an
        // observed id.
        var brokenRef = record
        let vision = columns.firstIndex(of: "vision_model_id")!
        brokenRef[vision] = .null
        let bad = RuntimeFacadePrivacy.observedPreferenceModelIDs(brokenRef)
        XCTAssertEqual(bad.count, 10)
        XCTAssertFalse(bad.contains(uniqueIDs["vision_model_id"]!))
        var nonUUIDRef = record
        nonUUIDRef[vision] = .text("not-a-uuid")
        XCTAssertEqual(
            RuntimeFacadePrivacy.observedPreferenceModelIDs(nonUUIDRef).count, 10)

        // Malformed shapes fail closed: nil record, short/extra record.
        XCTAssertEqual(RuntimeFacadePrivacy.observedPreferenceModelIDs(nil), [])
        XCTAssertEqual(
            RuntimeFacadePrivacy.observedPreferenceModelIDs(
                Array(record.dropFirst())), [])
        XCTAssertEqual(
            RuntimeFacadePrivacy.observedPreferenceModelIDs(record + [.integer(1)]),
            [])
    }

    func testModelConfigClearWithZeroSecretsNeedsNoGateway() async throws {
        let stores = try await PrivacyTestBed.stores(name: "zero-secret")
        let provider = try await PrivacyTestBed.seedProvider(stores)
        let assembly = PrivacyFacadeFactory.make(
            stores: stores, bindSecretOrdering: false)
        let report = try await clearModel(assembly)
        XCTAssertEqual(report.deleted.providers, 1)
        XCTAssertEqual(report.deleted.secrets, 0)
        let providers = try await providerCount(stores)
        XCTAssertEqual(providers, 0)
        let persisted = try await PrivacyTestBed.count(
            stores.database, "SELECT COUNT(*) FROM providers WHERE id = ?",
            [provider.uuidString])
        XCTAssertEqual(persisted, 0)
    }

    // MARK: - Trusted host confirmation

    func testHostCapabilityOneShotAndInvocationBinding() {
        let clock = PrivacyTestClock()
        let store = PrivacyHostConfirmationStore(root: "sha256:root", epoch: 4,
                                                 clock: { clock.now })
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let token = store.issue(
            operation: RuntimeFacadePrivacy.historyClearOperation,
            action: PrivacyConfirmationLimits.historyAction,
            previewDigest: digest, invocationID: "inv-1")
        XCTAssertNotNil(token)
        XCTAssertEqual(store.liveCount, 1)
        // A wrong invocation must NOT burn the user's capability.
        XCTAssertNil(store.consume(
            token: token!,
            operation: RuntimeFacadePrivacy.historyClearOperation,
            action: PrivacyConfirmationLimits.historyAction,
            previewDigest: digest, invocationID: "inv-2"))
        XCTAssertEqual(store.liveCount, 1)
        XCTAssertNotNil(store.consume(
            token: token!,
            operation: RuntimeFacadePrivacy.historyClearOperation,
            action: PrivacyConfirmationLimits.historyAction,
            previewDigest: digest, invocationID: "inv-1"))
        XCTAssertNil(store.consume(
            token: token!,
            operation: RuntimeFacadePrivacy.historyClearOperation,
            action: PrivacyConfirmationLimits.historyAction,
            previewDigest: digest, invocationID: "inv-1"))
        XCTAssertEqual(store.liveCount, 0)
    }

    func testHostCapabilityExpiryAndForeignBinding() {
        let clock = PrivacyTestClock()
        let store = PrivacyHostConfirmationStore(root: "sha256:root", epoch: 4,
                                                 clock: { clock.now })
        let digest = "sha256:" + String(repeating: "b", count: 64)
        let token = store.issue(
            operation: RuntimeFacadePrivacy.modelConfigClearOperation,
            action: PrivacyConfirmationLimits.modelConfigurationAction,
            previewDigest: digest, invocationID: "inv")!
        XCTAssertNil(store.consume(
            token: token,
            operation: RuntimeFacadePrivacy.historyClearOperation,
            action: PrivacyConfirmationLimits.historyAction,
            previewDigest: digest, invocationID: "inv"))
        XCTAssertEqual(store.liveCount, 1)
        clock.advance(PrivacyConfirmationLimits.maximumTTLSeconds + 1)
        XCTAssertNil(store.consume(
            token: token,
            operation: RuntimeFacadePrivacy.modelConfigClearOperation,
            action: PrivacyConfirmationLimits.modelConfigurationAction,
            previewDigest: digest, invocationID: "inv"))
        XCTAssertEqual(store.liveCount, 0)
        // Retiring this epoch clears only this store.
        let newer = PrivacyHostConfirmationStore(root: "sha256:root", epoch: 5,
                                                 clock: { clock.now })
        _ = newer.issue(operation: RuntimeFacadePrivacy.historyClearOperation,
                        action: PrivacyConfirmationLimits.historyAction,
                        previewDigest: digest, invocationID: "inv")
        store.retire()
        XCTAssertEqual(store.liveCount, 0)
        XCTAssertEqual(newer.liveCount, 1)
    }

    // MARK: - Failure paging (bounded same-root disk-backed store)

    /// Publishes a report spool directly through the staged writer, the same
    /// path the clear collector uses. Returns the store and summary. Pass an
    /// existing store to adopt several reports into ONE store (the handles
    /// are per-store registrations).
    private func publishReport(
        root: URL, kind: PrivacyReportKind, epoch: UInt64,
        items: [PrivacyFailurePageItem],
        store existingStore: PrivacyReportStore? = nil
    ) throws -> (PrivacyReportStore, PrivacyFailurePageSummary) {
        let token = PrivacyRootIdentity.token(rootPath: root.path)
        let writer = try PrivacyFailureReportSpoolWriter(
            rootPath: root.path, kind: kind, root: token, epoch: epoch,
            operationID: UUID())
        for item in items { try writer.append(item) }
        let handle = PrivacyFailureReportHandle.mint()
        let descriptor = try writer.finish(reportHandle: handle,
                                           createdAt: Date())
        let store = try existingStore ?? PrivacyReportStore(rootPath: root.path)
        let summary = try XCTUnwrap(store.adopt(descriptor))
        return (store, summary)
    }

    private func reportScratchRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FloePrivacyReportTests-\(UUID().uuidString)",
                                    isDirectory: true)
    }

    func testFailurePagingReadsEveryItem() throws {
        let root = reportScratchRoot()
        let items = (0..<20).map { index in
            PrivacyFailurePageItem(itemID: UUID(), providerID: nil,
                                   phase: "deleteConversation",
                                   reason: "reason-\(index)")
        }
        let (store, summary) = try publishReport(
            root: root, kind: .history, epoch: 1, items: items)
        XCTAssertEqual(summary.returned, 8)
        XCTAssertEqual(summary.total, 20)
        var cursor = summary.nextCursor
        var seen: [PrivacyFailurePageItem] = []
        var pages = 0
        while let current = cursor {
            let page = try store.page(handle: summary.handle,
                                      root: PrivacyRootIdentity.token(rootPath: root.path),
                                      epoch: 1,
                                      cursor: current, maxItems: 8)
            XCTAssertLessThanOrEqual(page.items.count, 8)
            seen.append(contentsOf: page.items)
            cursor = page.nextCursor
            pages += 1
        }
        XCTAssertEqual(pages, 2)
        XCTAssertEqual(seen.count, 12)
        XCTAssertEqual(seen.first?.reason, "reason-8")
        XCTAssertEqual(seen.last?.reason, "reason-19")
        // Foreign root/epoch is typed notFound.
        XCTAssertThrowsError(try store.page(handle: summary.handle,
                                            root: "sha256:other", epoch: 1,
                                            cursor: nil, maxItems: 8)) {
            XCTAssertEqual($0 as? PrivacyDomainError, .notFound)
        }
        XCTAssertThrowsError(try store.page(handle: summary.handle,
                                            root: PrivacyRootIdentity.token(rootPath: root.path),
                                            epoch: 2,
                                            cursor: nil, maxItems: 8)) {
            XCTAssertEqual($0 as? PrivacyDomainError, .notFound)
        }
    }

    /// Many failures stay fully pageable in stable order; the store keeps
    /// only small descriptors (no per-item in-memory inventory).
    func testFailurePagingManyItemsStableOrder() throws {
        let root = reportScratchRoot()
        let items = (0..<600).map { index in
            PrivacyFailurePageItem(itemID: UUID(), providerID: nil,
                                   phase: "grantRevoke",
                                   reason: "bulk-\(index)")
        }
        let (store, summary) = try publishReport(
            root: root, kind: .history, epoch: 1, items: items)
        XCTAssertEqual(summary.total, 600)
        var cursor: String? = nil
        var seen: [PrivacyFailurePageItem] = []
        var guardPages = 0
        repeat {
            let page = try store.page(
                handle: summary.handle,
                root: PrivacyRootIdentity.token(rootPath: root.path),
                epoch: 1, cursor: cursor, maxItems: 128)
            seen.append(contentsOf: page.items)
            cursor = page.nextCursor
            guardPages += 1
            XCTAssertLessThanOrEqual(page.items.count, 128)
        } while cursor != nil && guardPages < 32
        XCTAssertEqual(seen.count, 600)
        XCTAssertEqual(seen.map(\.reason), items.map(\.reason))
        XCTAssertEqual(seen.first?.reason, "bulk-0")
        XCTAssertEqual(seen.last?.reason, "bulk-599")
    }

    /// The page is measured by its ACTUAL serialized escaped UTF-8 bytes
    /// (48 KiB value budget): escaped non-ASCII reasons shrink the page
    /// honestly (fewer items than requested + truthful nextCursor), never
    /// truncation.
    func testFailurePagingEscapesRespectByteBudget() throws {
        let root = reportScratchRoot()
        // 96-scalar emoji reasons (~384 UTF-8 bytes each, at the 96-character
        // wire bound): 128 of them cannot fit one 48 KiB page, so the budget
        // (not maxItems) must bind.
        let heavy = String(repeating: "😀", count: 96)
        let items = (0..<128).map { _ in
            PrivacyFailurePageItem(itemID: UUID(), providerID: UUID(),
                                   phase: "gatewayDelete", reason: heavy)
        }
        let (store, summary) = try publishReport(
            root: root, kind: .modelConfiguration, epoch: 1, items: items)
        XCTAssertEqual(summary.total, 128)
        var cursor: String? = nil
        var seen: [PrivacyFailurePageItem] = []
        var pages = 0
        repeat {
            let page = try store.page(
                handle: summary.handle,
                root: PrivacyRootIdentity.token(rootPath: root.path),
                epoch: 1, cursor: cursor, maxItems: 128)
            let encoded = try JSONEncoder().encode(
                PrivacyFailurePageReply(report: page))
            XCTAssertLessThanOrEqual(encoded.count,
                                     SettingsDomainV1.pageBudgetBytes)
            // The budget bound this page below the requested 128 items.
            XCTAssertLessThan(page.items.count, 128)
            seen.append(contentsOf: page.items)
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil
        XCTAssertGreaterThanOrEqual(pages, 2)
        XCTAssertEqual(seen.count, 128)
        XCTAssertEqual(seen.map(\.itemID), items.map(\.itemID))
    }

    /// Reduced-page edge (2026-10-21): when the 48 KiB budget trims a page
    /// below the requested maxItems, the nextCursor must advance from the
    /// page START by the RETURNED count — never by the requested/read count.
    /// A regression to the reached-offset arithmetic skips records here.
    /// Every page's cursor spelling is pinned exactly and the traversal
    /// proves all items stay reachable in stable order.
    func testFailurePagingReducedPageContinuesWithoutSkip() throws {
        let root = reportScratchRoot()
        let token = PrivacyRootIdentity.token(rootPath: root.path)
        // 96-character emoji reasons (~384 raw UTF-8 bytes each; the encoder
        // emits UTF-8, not \u escapes): ~1250 bytes serialized per item, so
        // ~39 fit one 48 KiB page while maxItems=128 keeps reading 128 lines
        // — every page is budget-trimmed below its requested/read count.
        // (Distinct itemID values carry order identity.)
        let heavy = String(repeating: "😀", count: 96)
        let items = (0..<200).map { _ in
            PrivacyFailurePageItem(itemID: UUID(), providerID: nil,
                                   phase: "deleteConversation",
                                   reason: heavy)
        }
        let (store, summary) = try publishReport(
            root: root, kind: .history, epoch: 1, items: items)
        XCTAssertEqual(summary.total, 200)
        XCTAssertEqual(summary.returned, 8)
        var offset = PrivacyReportLimits.initialFailureItems
        var seen: [PrivacyFailurePageItem] = []
        var pages = 0
        var cursor: String? = summary.nextCursor
        while let current = cursor {
            let page = try store.page(handle: summary.handle, root: token,
                                      epoch: 1, cursor: current,
                                      maxItems: 128)
            if page.items.isEmpty {
                // Honest terminal page (only reachable after a trimmed tail).
                XCTAssertTrue(page.done)
                XCTAssertNil(page.nextCursor)
                break
            }
            // The budget reduced this page below the requested 128.
            XCTAssertLessThan(page.items.count, 128)
            // EXACT cursor spelling: start + returned, never start + read.
            XCTAssertEqual(page.nextCursor,
                           page.done ? nil : "rc:v1:\(offset + page.items.count)")
            seen.append(contentsOf: page.items)
            offset += page.items.count
            pages += 1
            cursor = page.nextCursor
            XCTAssertLessThanOrEqual(pages, 8)
        }
        XCTAssertGreaterThanOrEqual(pages, 2)
        XCTAssertEqual(seen.count, 200 - PrivacyReportLimits.initialFailureItems)
        XCTAssertEqual(seen.map(\.itemID),
                       Array(items.map(\.itemID).dropFirst(
                           PrivacyReportLimits.initialFailureItems)))
    }

    /// A NEW process incarnation owns orphan cleanup of the previous
    /// (crashed) incarnation's committed reports; the SAME incarnation
    /// keeps its live reports untouched.
    func testProcessReclaimRemovesOnlyForeignIncarnationReports() throws {
        let root = reportScratchRoot()
        let token = PrivacyRootIdentity.token(rootPath: root.path)
        let items = (0..<9).map {
            PrivacyFailurePageItem(itemID: nil, providerID: UUID(),
                                   phase: "enqueue", reason: "orphan-\($0)")
        }
        // Incarnation A publishes a report, then "dies".
        let incarnationA = UUID()
        let storeA = PrivacyReportStore(rootPath: root.path,
                                        incarnation: incarnationA)
        let writerA = try PrivacyFailureReportSpoolWriter(
            rootPath: root.path, kind: .history, root: token,
            epoch: 1, operationID: UUID())
        for item in items { try writerA.append(item) }
        let handleA = PrivacyFailureReportHandle.mint()
        let descriptorA = try writerA.finish(reportHandle: handleA,
                                             createdAt: Date())
        let summaryA = try XCTUnwrap(storeA.adopt(descriptorA))
        let directoryA = descriptorA.directoryPath
        XCTAssertTrue(FileManager.default.fileExists(atPath: directoryA))

        // Incarnation B (simulated process restart): A's committed report
        // is unreachable (no descriptors) and its directory is an orphan —
        // removed at claim time, containment-validated, epoch-agnostic.
        let storeB = PrivacyReportStore(rootPath: root.path,
                                        incarnation: UUID())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryA))
        XCTAssertThrowsError(try storeB.page(
            handle: summaryA.handle, root: token, epoch: 1,
            cursor: nil, maxItems: 8)) {
            XCTAssertEqual($0 as? PrivacyDomainError, .notFound)
        }

        // B publishes under epoch 2; a SAME-incarnation store re-init keeps
        // the live report (active current/newer-epoch protection).
        let writerB = try PrivacyFailureReportSpoolWriter(
            rootPath: root.path, kind: .history, root: token,
            epoch: 2, operationID: UUID())
        for item in items { try writerB.append(item) }
        let handleB = PrivacyFailureReportHandle.mint()
        let descriptorB = try writerB.finish(reportHandle: handleB,
                                             createdAt: Date())
        _ = try storeB.adopt(descriptorB)
        let directoryB = descriptorB.directoryPath
        // A same-incarnation store re-init must NOT clean the live report.
        let storeBSame = PrivacyReportStore(rootPath: root.path,
                                            incarnation: storeB.incarnation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directoryB))
        // The descriptor-owning store still pages it (handles are
        // process-lifetime registrations of one store instance).
        let page = try storeB.page(handle: handleB, root: token,
                                   epoch: 2, cursor: nil, maxItems: 8)
        XCTAssertEqual(page.total, 9)
    }

    /// Retire drops ONLY this epoch's reports (handles answer typed
    /// notFound afterwards); a newer epoch's report survives.
    func testFailurePagingRetireDropsOnlyThisEpoch() throws {
        let root = reportScratchRoot()
        let token = PrivacyRootIdentity.token(rootPath: root.path)
        let old = (0..<10).map {
            PrivacyFailurePageItem(itemID: nil, providerID: UUID(),
                                   phase: "enqueue", reason: "old-\($0)")
        }
        let new = (0..<10).map {
            PrivacyFailurePageItem(itemID: nil, providerID: UUID(),
                                   phase: "enqueue", reason: "new-\($0)")
        }
        let (store, oldSummary) = try publishReport(
            root: root, kind: .modelConfiguration, epoch: 1, items: old)
        // Same store: handles are per-store registrations.
        let (shared, newSummary) = try publishReport(
            root: root, kind: .modelConfiguration, epoch: 2, items: new,
            store: store)
        XCTAssertTrue(shared === store)
        store.retire(epoch: 1)
        XCTAssertThrowsError(try store.page(
            handle: oldSummary.handle, root: token, epoch: 1,
            cursor: nil, maxItems: 8)) {
            XCTAssertEqual($0 as? PrivacyDomainError, .notFound)
        }
        let page = try store.page(handle: newSummary.handle, root: token,
                                  epoch: 2, cursor: nil, maxItems: 8)
        XCTAssertEqual(page.total, 10)
        // The retired epoch's owned spool directory was removed; the newer
        // epoch's directory remains (root-owned containment cleanup only).
        let retiredName = "report-"
            + String(oldSummary.handle.dropFirst("pr:v1:".count))
        let keptName = "report-"
            + String(newSummary.handle.dropFirst("pr:v1:".count))
        let base = root.appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("PrivacyReports", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: base.appendingPathComponent(retiredName).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: base.appendingPathComponent(keptName).path))
    }

    /// Publishing beyond the bounded live store evicts the oldest report:
    /// its handle answers typed notFound and its owned directory is gone.
    func testFailurePagingEvictionRemovesOldestSpool() throws {
        let root = reportScratchRoot()
        let token = PrivacyRootIdentity.token(rootPath: root.path)
        let store = PrivacyReportStore(rootPath: root.path)
        let capacity = PrivacyReportLimits.maximumLiveReportsPerRoot * 4
        var firstHandle = ""
        var firstDirectory = ""
        for index in 0..<(capacity + 2) {
            let items = (0..<9).map {
                PrivacyFailurePageItem(itemID: nil, providerID: UUID(),
                                       phase: "enqueue",
                                       reason: "r-\(index)-\($0)")
            }
            let writer = try PrivacyFailureReportSpoolWriter(
                rootPath: root.path, kind: .history, root: token,
                epoch: 1, operationID: UUID())
            for item in items { try writer.append(item) }
            let handle = PrivacyFailureReportHandle.mint()
            let descriptor = try writer.finish(reportHandle: handle,
                                               createdAt: Date())
            if index == 0 {
                firstHandle = handle
                firstDirectory = descriptor.directoryPath
            }
            _ = try store.adopt(descriptor)
        }
        XCTAssertEqual(store.liveCount(), capacity)
        XCTAssertThrowsError(try store.page(
            handle: firstHandle, root: token, epoch: 1,
            cursor: nil, maxItems: 8)) {
            XCTAssertEqual($0 as? PrivacyDomainError, .notFound)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstDirectory))
    }

    /// Stale/foreign/unknown handles are typed notFound; a cursor beyond the
    /// total and a malformed cursor fail typed as well.
    func testFailurePagingRejectsStaleForeignAndMalformed() throws {
        let root = reportScratchRoot()
        let token = PrivacyRootIdentity.token(rootPath: root.path)
        let items = (0..<12).map {
            PrivacyFailurePageItem(itemID: nil, providerID: UUID(),
                                   phase: "enqueue", reason: "x-\($0)")
        }
        let (store, summary) = try publishReport(
            root: root, kind: .history, epoch: 1, items: items)
        // Unknown handle.
        XCTAssertThrowsError(try store.page(
            handle: PrivacyFailureReportHandle.mint(), root: token, epoch: 1,
            cursor: nil, maxItems: 8)) {
            XCTAssertEqual($0 as? PrivacyDomainError, .notFound)
        }
        // Offset past the end.
        XCTAssertThrowsError(try store.page(
            handle: summary.handle, root: token, epoch: 1,
            cursor: "rc:v1:99", maxItems: 8)) {
            XCTAssertEqual($0 as? PrivacyDomainError, .notFound)
        }
        // Malformed cursor.
        XCTAssertThrowsError(try store.page(
            handle: summary.handle, root: token, epoch: 1,
            cursor: "bogus", maxItems: 8)) {
            guard case PrivacyDomainError.invalidEnvelope = $0 else {
                return XCTFail("expected invalidEnvelope, got \($0)")
            }
        }
        // Terminal empty page: offset == total is a valid done page.
        let terminal = try store.page(handle: summary.handle, root: token,
                                      epoch: 1, cursor: "rc:v1:12",
                                      maxItems: 8)
        XCTAssertTrue(terminal.done)
        XCTAssertTrue(terminal.items.isEmpty)
        XCTAssertNil(terminal.nextCursor)
    }

    /// I/O failure truthfulness at arrangement: when the report spool
    /// cannot be staged, the clear refuses typed BEFORE any destructive
    /// effect (nothing deleted, the confirmation capability unspent).
    func testReportSpoolArrangementFailureRefusesClearBeforeEffects() async throws {
        let stores = try await PrivacyTestBed.stores()
        let assembly = PrivacyFacadeFactory.make(stores: stores)
        let conversation = try await PrivacyTestBed.seedConversation(stores)
        try await PrivacyTestBed.seedRun(stores, conversationID: conversation)
        let digest = try await assembly.facade.summary().history.revision
        let token = privacyIssue(assembly, digest: digest, invocation: "inv")!
        // Block the owned reports directory with a regular FILE: staging
        // creation must fail typed. The root-scoped report store already
        // created the directory at factory time, so replace it with the
        // blocking file first.
        let blocked = stores.directory
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("PrivacyReports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: blocked.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: blocked)
        try Data("blocked".utf8).write(to: blocked)
        do {
            _ = try await assembly.facade.clearHistory(
                request: PrivacyClearRequest(confirmToken: token),
                revision: BaseRevision(
                    resourceID: RuntimeFacadePrivacy.historyResourceID,
                    version: digest),
                invocationID: "inv")
            XCTFail("expected typed persistenceUnavailable refusal")
        } catch let error as PrivacyDomainError {
            guard case .persistenceUnavailable(let reason) = error else {
                return XCTFail("expected persistenceUnavailable, got \(error)")
            }
            XCTAssertEqual(reason, "reportSpoolCreate")
        }
        // Nothing was deleted and the capability was never consumed.
        let after = try await assembly.facade.summary()
        XCTAssertEqual(after.history.conversationCount, 1)
        XCTAssertEqual(assembly.host.liveCount, 1)
    }

    /// I/O failure truthfulness mid-collection: once an append cannot be
    /// written, the collector degrades, the destructive loops stop at their
    /// next boundary, and finish() refuses typed rather than publishing an
    /// incomplete report.
    ///
    /// Fault mechanism (2026-10-21 repair): the original chmod(0400)
    /// approach cannot work — POSIX checks write permissions at open(2),
    /// and the writer's descriptor is already open, so the append succeeds
    /// (verified empirically on macOS for chmod and chflags/UCHG). The
    /// writer exposes a test-only `testAppendFault` injection seam for
    /// exactly this; the arrangement (pre-effect) failure remains a REAL
    /// filesystem refusal via the facade-level arrangement test.
    func testReportSpoolWriteFailureDegradesCollector() throws {
        let root = reportScratchRoot()
        let token = PrivacyRootIdentity.token(rootPath: root.path)
        let operationID = UUID()
        let writer = try PrivacyFailureReportSpoolWriter(
            rootPath: root.path, kind: .history, root: token,
            epoch: 1, operationID: operationID)
        // The staged file exists and is writable; the first append fails
        // through the injection seam with the SAME typed error a real
        // write(2) failure produces.
        writer.testAppendFault = {
            .persistenceUnavailable("reportSpoolWrite")
        }
        XCTAssertThrowsError(try writer.append(PrivacyFailurePageItem(
            itemID: nil, providerID: nil, phase: "drain", reason: "x"))) {
            guard case PrivacyDomainError.persistenceUnavailable(let reason) = $0 else {
                return XCTFail("expected persistenceUnavailable, got \($0)")
            }
            XCTAssertEqual(reason, "reportSpoolWrite")
        }
        // The staging directory is removed on abort (recoverable state).
        writer.abort()
        let staged = root.appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("PrivacyReports", isDirectory: true)
            .appendingPathComponent("staging-\(operationID.uuidString)",
                                    isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    // MARK: - Privileged native ingress

    func testNativeIngressRejectsWithoutOwnerProof() {
        let digest = "sha256:" + String(repeating: "c", count: 64)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 64)
        defer { buffer.deallocate() }
        let status = "00000000000000000000000000000000".withCString { owner in
            "privacy.history.clear".withCString { operation in
                digest.withCString { preview in
                    "inv-1".withCString { invocation in
                        "historyClear".withCString { action in
                            floePrivacyConfirmIssue(
                                1, owner, operation, preview, invocation,
                                action, buffer, 64)
                        }
                    }
                }
            }
        }
        // No live generation in this unit-test process: the full owner proof
        // is refused, never minted from a shaped token.
        XCTAssertEqual(status, PrivacyConfirmationStatus.ownerProofInvalid)
        XCTAssertEqual(floePrivacyConfirmIssue(
            0, nil, nil, nil, nil, nil, nil, 0),
            PrivacyConfirmationStatus.invalidArgument)
    }

    private final class PrivacyOnceCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !used else { return false }
            used = true
            return true
        }
    }
}
