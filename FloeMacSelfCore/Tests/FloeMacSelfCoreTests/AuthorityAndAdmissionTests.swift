// SPDX-License-Identifier: MPL-2.0
//
// Authority-lock, durable admission, crash reconciliation and shutdown
// regression tests. Every fixture is a unique 0700 temporary directory. A
// fixture that intentionally leaves an unresolved admission row is retained as
// evidence; the helper never removes a failing or unknown fixture.

import Foundation
import Darwin
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloeSecurity
import FloePersistence
import FloeAgentRuntime
@testable import FloeMacSelfCore

@Suite("Mac self-core authority gate and verified primitive", .serialized)
struct MacSelfAuthorityLockTests {
    @Test("The production gate refuses before reading, creating or changing any path")
    func productionGateRefusesWithoutTouchingFiles() async throws {
        try await withSelfCoreTempDirectory { root in
            let databaseURL = root.appendingPathComponent("authority.sqlite")
            let lockURL = root.appendingPathComponent(
                "authority.sqlite.floe-self-authority.lock"
            )
            try Data("user-database-sentinel".utf8).write(to: databaseURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: databaseURL.path
            )
            try Data("user-lock-sentinel".utf8).write(to: lockURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: lockURL.path
            )
            let before = try AuthorityPrimitiveChecks.snapshot(root)
            let owner = FloeMacSelfHostIdentity(displayName: "AuthorityGateFixture")

            do {
                _ = try FloeMacSelfAuthorityLock(databaseURL: databaseURL, owner: owner)
                Issue.record("The production authority gate must remain closed")
            } catch let error as FloeMacSelfCoreError {
                #expect(error == .authorityLockUnsafe("ownership_not_verified"))
            } catch {
                Issue.record("Unexpected authority gate error: \(error)")
            }

            let after = try AuthorityPrimitiveChecks.snapshot(root)
            #expect(after == before)
        }
    }

    @Test("The production gate does not create a missing database or lock")
    func productionGateCreatesNothing() async throws {
        try await withSelfCoreTempDirectory { root in
            let databaseURL = root.appendingPathComponent("missing.sqlite")
            let before = try AuthorityPrimitiveChecks.snapshot(root)
            let owner = FloeMacSelfHostIdentity(displayName: "AuthorityGateFixture")

            do {
                _ = try FloeMacSelfAuthorityLock(databaseURL: databaseURL, owner: owner)
                Issue.record("The production authority gate must remain closed")
            } catch let error as FloeMacSelfCoreError {
                #expect(error == .authorityLockUnsafe("ownership_not_verified"))
            } catch {
                Issue.record("Unexpected authority gate error: \(error)")
            }

            let after = try AuthorityPrimitiveChecks.snapshot(root)
            #expect(after == before)
        }
    }

    @Test("Verified authority primitive checks")
    func verifiedAuthorityPrimitiveChecks() throws {
        try AuthorityPrimitiveChecks.run(selfExecutable: nil)
    }
}

@Suite("Mac self-core durable admission")
struct DurableAdmissionTests {
    @Test("Admission phases are compare-and-set and stop intent never clears the row")
    func admissionCASPhases() async throws {
        let root = try makeSelfCoreEvidenceRoot(prefix: "admission-cas")
        let databaseURL = root.appendingPathComponent("cas.sqlite")
        let seeded = try await makeSeededDatabase(at: databaseURL)
        let store = FloeMacSelfAdmissionStore(database: seeded.database, authorityLock: nil)
        let conversationID = UUID()
        let runID = UUID()
        let owner = FloeMacSelfHostIdentity(displayName: "AdmissionCAS")

        let admitted = try await store.admit(
            conversationID: conversationID,
            runID: runID,
            owner: owner
        )
        #expect(admitted.phase == .admitting)
        #expect(admitted.epoch == 1)

        let duplicate = await selfCoreError {
            _ = try await store.admit(conversationID: conversationID, runID: runID, owner: owner)
        }
        #expect(duplicate == .conversationBusy(conversationID))

        let differentRun = await selfCoreError {
            _ = try await store.admit(conversationID: conversationID, runID: UUID(), owner: owner)
        }
        #expect(differentRun == .admissionUnknown(conversationID))

        let wrongEpoch = await selfCoreError {
            try await store.markPrepared(conversationID: conversationID, runID: runID, epoch: admitted.epoch + 1)
        }
        #expect(wrongEpoch == .admissionConflict(conversationID))

        try await store.markPrepared(conversationID: conversationID, runID: runID, epoch: admitted.epoch)
        let prepared = try #require(try await store.record(conversationID: conversationID))
        #expect(prepared.phase == .prepared)

        let wrongDispatch = try await store.requestDispatch(
            conversationID: conversationID,
            runID: runID,
            epoch: admitted.epoch + 1
        )
        #expect(wrongDispatch == .conflict)
        let dispatch = try await store.requestDispatch(
            conversationID: conversationID,
            runID: runID,
            epoch: admitted.epoch
        )
        #expect(dispatch == .admitted)

        let firstStop = try #require(try await store.recordStopIntent(
            conversationID: conversationID,
            runID: runID,
            epoch: admitted.epoch
        ))
        let secondStop = try #require(try await store.recordStopIntent(
            conversationID: conversationID,
            runID: runID,
            epoch: admitted.epoch
        ))
        #expect(secondStop > firstStop)

        let repeatDispatch = try await store.requestDispatch(
            conversationID: conversationID,
            runID: runID,
            epoch: admitted.epoch
        )
        #expect(repeatDispatch == .conflict)

        try await store.markSettled(
            conversationID: conversationID,
            runID: runID,
            epoch: admitted.epoch,
            confirmed: false,
            detail: "unit-test"
        )
        let settled = try #require(try await store.record(conversationID: conversationID))
        #expect(settled.phase == .settledUnconfirmed)
        let unresolved = try await store.unresolvedAdmissions()
        #expect(unresolved.contains { $0.conversationID == conversationID && $0.runID == runID })

        let stopAfterSettlement = try await store.recordStopIntent(
            conversationID: conversationID,
            runID: runID,
            epoch: admitted.epoch
        )
        #expect(stopAfterSettlement == nil)
        let releasePrePrepare = try await store.releasePrePrepare(
            conversationID: conversationID,
            runID: runID,
            epoch: admitted.epoch
        )
        #expect(!releasePrePrepare)
        let abandonSettled = await selfCoreError {
            try await store.abandonUnstartedAdmission(
                conversationID: conversationID,
                runID: runID,
                epoch: admitted.epoch
            )
        }
        #expect(abandonSettled == .admissionUnknown(conversationID))

        try await seeded.database.close()
        _ = root
    }

    @Test("A crash between durable claim and prepare blocks automatic retry until explicit reconciliation")
    func prePrepareCrashBlocksRetry() async throws {
        let root = try makeSelfCoreEvidenceRoot(prefix: "pre-prepare-crash")
        let databaseURL = root.appendingPathComponent("crash.sqlite")
        let seeded = try await makeSeededDatabase(at: databaseURL)
        let workspaceID = UUID()
        try await seeded.workspace.saveWorkspace(WorkspaceRecord(
            id: workspaceID,
            name: "Crash workspace",
            rootBookmark: Data(),
            kind: .project
        ))
        let conversationID = UUID()
        let runID = UUID()
        let store = FloeMacSelfAdmissionStore(database: seeded.database, authorityLock: nil)
        _ = try await store.admit(
            conversationID: conversationID,
            runID: runID,
            owner: FloeMacSelfHostIdentity(displayName: "CrashSeed")
        )
        try await seeded.database.close()
        let provenance = try makeHostProvenance(databaseURL: databaseURL)

        let runtime = try FloeMacSelfRuntime(
            databaseURL: databaseURL,
            owner: FloeMacSelfHostIdentity(displayName: "CrashRecovery"),
            provenance: provenance
        )
        _ = try await runtime.bootstrap()
        let (binding, _) = SelfCoreFixture.makeProviderBinding(scripts: [[
            .textDelta(.init(text: "Reconciled run completed.")),
            .completed(.init(stopReason: .endTurn)),
        ]])
        let blocked = await selfCoreError {
            _ = try await runtime.startSession(
                FloeMacSelfSessionRequest(
                    newConversationID: conversationID,
                    workspaceID: workspaceID,
                    goal: "Automatic replay must not start"
                ),
                provider: binding
            )
        }
        #expect(blocked == .admissionUnknown(conversationID))
        #expect(try await runtime.nonTerminalRuns().isEmpty)

        let wrongIdentity = await selfCoreError {
            try await runtime.abandonUnstartedAdmission(
                conversationID: conversationID,
                runID: UUID(),
                expectedEpoch: 1
            )
        }
        #expect(wrongIdentity == .admissionUnknown(conversationID))
        try await runtime.abandonUnstartedAdmission(
            conversationID: conversationID,
            runID: runID,
            expectedEpoch: 1
        )

        let handle = try await runtime.startSession(
            FloeMacSelfSessionRequest(
                newConversationID: conversationID,
                workspaceID: workspaceID,
                goal: "Start after explicit reconciliation"
            ),
            provider: binding
        )
        let terminal = try #require(await handle.waitForTerminal(timeout: 15))
        #expect(terminal.confirmed)
        let close = try await handle.close()
        #expect(close.terminalConfirmed)
        let shutdown = try await runtime.shutdown(cancelActive: false)
        #expect(shutdown.databaseClosed)
        #expect(shutdown.retainedAdmissionConversationIDs.isEmpty)
        _ = root
    }

    @Test("A crash after durable dispatch intent blocks automatic retry and is retained by shutdown")
    func dispatchIntentCrashBlocksRetry() async throws {
        let root = try makeSelfCoreEvidenceRoot(prefix: "dispatch-crash")
        let databaseURL = root.appendingPathComponent("dispatch.sqlite")
        let seeded = try await makeSeededDatabase(at: databaseURL)
        let workspaceID = UUID()
        try await seeded.workspace.saveWorkspace(WorkspaceRecord(
            id: workspaceID,
            name: "Dispatch workspace",
            rootBookmark: Data(),
            kind: .project
        ))
        let (seedBinding, _) = SelfCoreFixture.makeProviderBinding(scripts: [])
        let conversationID = UUID()
        let runID = UUID()
        // Seed in the exact order the runtime performs: the durable admission
        // is the claim that arbitrates execution, so it must exist before the
        // launch store prepares the run. A crash after dispatch intent then
        // leaves a `starting` row that blocks automatic replay.
        let store = FloeMacSelfAdmissionStore(database: seeded.database, authorityLock: nil)
        let admitted = try await store.admit(
            conversationID: conversationID,
            runID: runID,
            owner: FloeMacSelfHostIdentity(displayName: "DispatchSeed")
        )
        _ = try await seeded.launch.prepare(RunLaunchRequest(
            newConversationID: conversationID,
            conversationTitle: "Dispatch crash",
            runID: runID,
            goal: "Prepared but never dispatched",
            workspaceID: workspaceID,
            conversationMode: "chat",
            providerName: seedBinding.provider.displayName,
            modelName: seedBinding.model.displayName,
            providerProfile: seedBinding.provider,
            modelProfile: seedBinding.model,
            startedAt: Date()
        ))
        try await store.markPrepared(
            conversationID: conversationID,
            runID: runID,
            epoch: admitted.epoch
        )
        let dispatchedIntent = try await store.requestDispatch(
            conversationID: conversationID,
            runID: runID,
            epoch: admitted.epoch
        )
        #expect(dispatchedIntent == .admitted)
        try await seeded.database.close()
        let provenance = try makeHostProvenance(databaseURL: databaseURL)

        let runtime = try FloeMacSelfRuntime(
            databaseURL: databaseURL,
            owner: FloeMacSelfHostIdentity(displayName: "DispatchRecovery"),
            provenance: provenance
        )
        _ = try await runtime.bootstrap()
        let (binding, _) = SelfCoreFixture.makeProviderBinding(scripts: [])
        let blocked = await selfCoreError {
            _ = try await runtime.startSession(
                FloeMacSelfSessionRequest(
                    conversationID: conversationID,
                    goal: "Automatic replay must not start"
                ),
                provider: binding
            )
        }
        #expect(blocked == .admissionUnknown(conversationID))
        let runs = try await runtime.recentRuns(conversationID: conversationID, limit: 10)
        #expect(runs.count == 1)
        #expect(runs.first?.id == runID)
        #expect(runs.first?.state == "preparing")

        let shutdown = try await runtime.shutdown(cancelActive: false)
        #expect(shutdown.databaseClosed)
        #expect(shutdown.admissionInventoryAvailable)
        #expect(shutdown.retainedAdmissionConversationIDs == [conversationID])
        _ = root
    }

    @Test("A strictly confirmed terminal run permits a new admission for the same conversation")
    func confirmedTerminalAllowsReplacement() async throws {
        try await withSelfCoreTempDirectory { root in
            let databaseURL = root.appendingPathComponent("replacement.sqlite")
            let seeded = try await makeSeededDatabase(at: databaseURL)
            let workspaceID = UUID()
            try await seeded.workspace.saveWorkspace(WorkspaceRecord(
                id: workspaceID,
                name: "Replacement workspace",
                rootBookmark: Data(),
                kind: .project
            ))
            let (seedBinding, _) = SelfCoreFixture.makeProviderBinding(scripts: [])
            let conversationID = UUID()
            let firstRunID = UUID()
            let prepared = try await seeded.launch.prepare(RunLaunchRequest(
                newConversationID: conversationID,
                conversationTitle: "Replacement",
                runID: firstRunID,
                goal: "First completed run",
                workspaceID: workspaceID,
                conversationMode: "chat",
                providerName: seedBinding.provider.displayName,
                modelName: seedBinding.model.displayName,
                providerProfile: seedBinding.provider,
                modelProfile: seedBinding.model,
                startedAt: Date()
            ))
            let conversationStore = SQLiteConversationStore(database: seeded.database)
            let runStore = SQLiteRunStore(database: seeded.database)
            let assistantID = UUID()
            let assistantText = "First answer"
            try await conversationStore.appendMessage(PersistedMessage(
                id: assistantID,
                conversationID: conversationID,
                role: "assistant",
                content: assistantText,
                createdAt: Date(),
                parts: [MessagePart(
                    messageID: assistantID,
                    partIndex: 0,
                    kind: .text,
                    text: assistantText
                )],
                runID: firstRunID
            ))
            try await runStore.updateRunState(
                id: firstRunID,
                state: "completed",
                endedAt: Date()
            )
            try await runStore.appendEvent(
                runID: firstRunID,
                kind: .terminal,
                payloadJSON: #"{"stopReason":"endTurn","finalMessageID":"\#(assistantID.uuidString)"}"#
            )
            let store = FloeMacSelfAdmissionStore(database: seeded.database, authorityLock: nil)
            let firstReceipt = try await store.terminalReceipt(
                conversationID: conversationID,
                runID: firstRunID,
                expectedUserMessageID: prepared.userMessage.id
            )
            #expect(firstReceipt.confirmed)
            let admitted = try await store.admit(
                conversationID: conversationID,
                runID: firstRunID,
                owner: FloeMacSelfHostIdentity(displayName: "ReplacementSeed")
            )
            try await store.markPrepared(
                conversationID: conversationID,
                runID: firstRunID,
                epoch: admitted.epoch
            )
            try await store.markSettled(
                conversationID: conversationID,
                runID: firstRunID,
                epoch: admitted.epoch,
                confirmed: true,
                detail: "completed"
            )
            try await seeded.database.close()
            let provenance = try makeHostProvenance(databaseURL: databaseURL)

            let runtime = try FloeMacSelfRuntime(
                databaseURL: databaseURL,
                owner: FloeMacSelfHostIdentity(displayName: "ReplacementRuntime"),
                provenance: provenance
            )
            _ = try await runtime.bootstrap()
            let (binding, _) = SelfCoreFixture.makeProviderBinding(scripts: [[
                .textDelta(.init(text: "Second run completed.")),
                .completed(.init(stopReason: .endTurn)),
            ]])
            let handle = try await runtime.startSession(
                FloeMacSelfSessionRequest(
                    conversationID: conversationID,
                    goal: "Second run in the same conversation"
                ),
                provider: binding
            )
            let terminal = try #require(await handle.waitForTerminal(timeout: 15))
            #expect(terminal.confirmed)
            #expect(handle.identity.admissionEpoch == 2)
            let secondAdmission = try #require(try await runtime.admissionRecord(conversationID: conversationID))
            #expect(secondAdmission.epoch == 2)
            #expect(secondAdmission.previousRunID == firstRunID)
            _ = try await handle.close()
            let shutdown = try await runtime.shutdown(cancelActive: false)
            #expect(shutdown.databaseClosed)
            #expect(shutdown.retainedAdmissionConversationIDs.isEmpty)
        }
    }

    @Test("Concurrent shutdown calls are serialized and close the database once")
    func concurrentShutdownIsSerialized() async throws {
        try await withSelfCoreFixture { fixture in
            let (provider, _) = fixture.makeProvider(
                scripts: [[
                    .textDelta(.init(text: "Shutdown race.")),
                    .completed(.init(stopReason: .endTurn)),
                ]],
                holdFirstEvent: true
            )
            let handle = try await fixture.runtime.startSession(
                fixture.newConversationRequest(goal: "Concurrent shutdown"),
                provider: provider
            )
            let running = await eventually { await handle.phase() == .running }
            #expect(running)

            async let first = fixture.shutdown(cancelActive: true, timeout: 10)
            async let second = fixture.shutdown(cancelActive: true, timeout: 10)
            let firstReceipt = try await first
            let secondReceipt = try await second
            let receipts = [firstReceipt, secondReceipt]
            #expect(receipts.allSatisfy { $0.databaseClosed })
            #expect(receipts.contains { !$0.alreadyClosed })
            let realClosures = receipts.filter { !$0.alreadyClosed }
            if realClosures.count == 2 {
                #expect(realClosures[0].closedSessionCount == realClosures[1].closedSessionCount)
                #expect(realClosures[0].preservedRunIDs == realClosures[1].preservedRunIDs)
            }
        }
    }
}
