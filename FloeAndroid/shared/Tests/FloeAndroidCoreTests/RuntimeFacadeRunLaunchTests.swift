// SPDX-License-Identifier: MPL-2.0
//
// RB-4 launch-path tests. AUTHORED, NOT EXECUTED. These call the REAL
// public service paths (domain wire methods over REAL file-backed stores,
// the REAL ConversationRunService and the reviewed mailbox/pump objects);
// only the model stream is a scripted double.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloePersistence
import FloeAgentRuntime
import FloeSecurity
@testable import FloeAndroidCore

final class RuntimeFacadeRunLaunchTests: XCTestCase {
    private var fixture: RunDomainFixture!

    override func setUp() async throws {
        fixture = try await RunDomainFixture.make()
    }

    override func tearDown() async throws {
        RunDomainFacade.uninstall()
        await fixture?.tearDown()
        fixture = nil
    }

    private func startReply(_ domain: FacadeRunDomain, fixture: RunDomainFixture,
                            conversationID: UUID, goal: String = "hello world",
                            mode: String = "chat",
                            receipt: String = "op:v1:" + String(repeating: "a", count: 32)) async
        -> RunDomainReply {
        let revision = try! await fixture.revision(conversationID: conversationID)
        let envelope = fixture.launchEnvelope(
            conversationID: conversationID,
            payload: fixture.startPayload(goal: goal, mode: mode),
            revisionVersion: revision,
            correlation: receipt)
        return await domain.start(envelope: envelope, receipt: receipt,
                                  correlation: receipt)
    }

    func testChatLaunchSucceedsThroughOriginalEngine() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let reply = await startReply(domain, fixture: fixture,
                                     conversationID: conversationID,
                                     goal: "stream me a sentence")
        guard case .mutationAccepted(let detail) = reply.outcome else {
            return XCTFail("expected accepted, got \(reply.outcome)")
        }
        let runID = try XCTUnwrap(UUID(uuidString: detail["runID"] ?? ""))
        // The ORIGINAL service drove the scripted stream to its real
        // durable terminal through the ORIGINAL stores.
        let state = await waitDurableTerminal(fixture: fixture, runID: runID)
        XCTAssertEqual(state, "completed")
        let events = try await fixture.durableEvents(runID)
        XCTAssertTrue(events.contains { $0.kind == .assistantText })
        XCTAssertTrue(events.contains { $0.kind == .terminal })
        // Ownership retired: exact tokens detached at real completion. The
        // terminal P8 feed is an owned maintenance Task (RUN-S3 repair), so
        // observe the CONVERGED zero — never a transient lease window.
        let registryEpoch = fixture.epoch
        let clean = await pollFor {
            RuntimeOwnedWorkRegistry.shared.count(for: registryEpoch) == 0
        }
        XCTAssertTrue(clean)
        let owned = await domain.owners(conversationID: conversationID)
        XCTAssertTrue(owned.isEmpty)
    }

    func testIdentityPublicationTimingReceiptVersusPrepared() async throws {
        // The queue receipt NEVER carries domain identity; the REAL ids
        // appear only in the async prepared/started stages appended after
        // the atomic prepare committed.
        let conversationID = try await fixture.makeOrdinaryConversation()
        let receipt = fixture.effects.register(correlationID: "corr:pub")
        XCTAssertNotNil(receipt)
        let domain = fixture.makeDomain()
        let reply = await startReply(domain, fixture: fixture,
                                     conversationID: conversationID,
                                     receipt: receipt!)
        _ = reply
        let items = pollEffects(fixture.effects, receipt: receipt!)
        let kinds = items.map(\.kind)
        XCTAssertEqual(kinds.first, .prepared,
                       "prepared must be the FIRST stage after the commit")
        XCTAssertTrue(kinds.contains(.started))
        XCTAssertLessThan(kinds.firstIndex(of: .prepared)!,
                          kinds.firstIndex(of: .started)!)
        // prepared detail carries the REAL conversation/run identity —
        // never the mint probe.
        let prepared = items.first { $0.kind == .prepared }!
        XCTAssertEqual(prepared.detail?["conversationID"], conversationID.uuidString)
        XCTAssertNotEqual(prepared.detail?["runID"],
                          RunStartTaskQuery.mintProbe.uuidString)
    }

    func testPrePrepareFailureLeavesNoDurableEffectC0() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        // Transport unqualified: refusal BEFORE the atomic commit.
        let domain = fixture.makeDomain(transportQualified: false)
        let reply = await startReply(domain, fixture: fixture,
                                     conversationID: conversationID)
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("expected rejected")
        }
        XCTAssertEqual(error, RunDomainError(.transportUnavailable, .transportNotQualified))
        // C0 proof: no run row was created for this launch.
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        XCTAssertEqual(runs.count, 1) // only the seeding run
        XCTAssertEqual(RuntimeOwnedWorkRegistry.shared.count(for: fixture.epoch), 0)
    }

    func testMissingSecretNeverDispatchesProviderRequest() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        // Point the fixture provider at an unseeded secret reference.
        var provider = fixture.providerProfile
        provider.secretRef = SecretReference(keychainAccount: "unseeded-account",
                                             synchronizable: false)
        try await fixture.modelStore.saveProvider(provider)
        let domain = fixture.makeDomain()
        let reply = await startReply(domain, fixture: fixture,
                                     conversationID: conversationID)
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("expected credentialUnavailable")
        }
        XCTAssertEqual(error.code, .credentialUnavailable)
        XCTAssertEqual(error.reason, .secretMissing)
        // NO provider request happened: the scripted adapter never saw a
        // dispatch and no run row exists.
        XCTAssertEqual(fixture.adapter.requestCount, 0)
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        XCTAssertEqual(runs.count, 1)
    }

    func testGatewayUnregisteredRefusesOrdinaryLaunch() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        SecretGatewayRegistry.shared.unregister()
        let domain = fixture.makeDomain()
        let reply = await startReply(domain, fixture: fixture,
                                     conversationID: conversationID)
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("expected typed credential refusal")
        }
        // Unregistered gateway reads as secretMissing through the typed
        // resolver: anonymous fallback is structurally impossible.
        XCTAssertEqual(error.code, .credentialUnavailable)
    }

    func testLocalModelProfileRefusedNoLocalInference() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        var local = fixture.providerProfile
        local.kind = .local
        local.id = UUID()
        local.secretRef = nil
        try await fixture.modelStore.saveProvider(local)
        var model = fixture.modelProfile
        model.providerID = local.id
        model.id = UUID()
        try await fixture.modelStore.saveModel(model)
        let envelope = fixture.launchEnvelope(
            conversationID: conversationID,
            payload: [
                "goal": "hi", "mode": "chat",
                "providerID": local.id.uuidString, "modelID": model.id.uuidString,
                "approvalMode": "ask",
            ],
            revisionVersion: try await fixture.revision(conversationID: conversationID),
            correlation: "corr:local")
        let reply = await fixture.makeDomain().start(envelope: envelope,
                                                     receipt: "op:v1:" + String(repeating: "b", count: 32),
                                                     correlation: "corr:local")
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("expected unsupportedRole refusal")
        }
        XCTAssertEqual(error.reason, .localInferenceUnsupported)
    }

    func testStagingUnboundRefusesHandlesBeforeEffects() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        fixture.staging.refuse = true
        var payload = fixture.startPayload(goal: "with attachment")
        payload["stagedAttachments"] = ["lease-001"]
        let envelope = fixture.launchEnvelope(
            conversationID: conversationID, payload: payload,
            revisionVersion: try await fixture.revision(conversationID: conversationID),
            correlation: "corr:stage")
        let reply = await fixture.makeDomain().start(
            envelope: envelope, receipt: "op:v1:" + String(repeating: "c", count: 32),
            correlation: "corr:stage")
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("expected capabilityNotUsable")
        }
        XCTAssertEqual(error.code, .capabilityNotUsable)
        // Refusal happened pre-prepare: still only the seeding run.
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        XCTAssertEqual(runs.count, 1)
    }

    func testImageHandlesRefusedUntilAttachmentQualification() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        fixture.staging.imageHandles = ["lease-img"]
        var payload = fixture.startPayload(goal: "look at this image")
        payload["stagedAttachments"] = ["lease-img"]
        let envelope = fixture.launchEnvelope(
            conversationID: conversationID, payload: payload,
            revisionVersion: try await fixture.revision(conversationID: conversationID),
            correlation: "corr:img")
        let reply = await fixture.makeDomain().start(
            envelope: envelope, receipt: "op:v1:" + String(repeating: "d", count: 32),
            correlation: "corr:img")
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("expected image refusal")
        }
        XCTAssertEqual(error.code, .capabilityNotUsable)
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        XCTAssertEqual(runs.count, 1)
    }

    func testRequestedEnvironmentRoleWithoutProofRefused() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        var payload = fixture.startPayload(goal: "use the env")
        payload["environmentID"] = UUID().uuidString
        let envelope = fixture.launchEnvelope(
            conversationID: conversationID, payload: payload,
            revisionVersion: try await fixture.revision(conversationID: conversationID),
            correlation: "corr:env")
        let reply = await fixture.makeDomain().start(
            envelope: envelope, receipt: "op:v1:" + String(repeating: "e", count: 32),
            correlation: "corr:env")
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("expected unsupportedRole")
        }
        XCTAssertEqual(error.reason, .environmentRoleUnresolvable)
    }

    func testStagedDocumentHandleConsumedThroughOriginalPrepare() async throws {
        // The ONLY atomic attachment insertion stays inside the original
        // prepare transaction (attachment-lane handshake consumed here).
        let conversationID = try await fixture.makeOrdinaryConversation()
        fixture.staging.unknownHandles = []
        var payload = fixture.startPayload(goal: "edit the staged file")
        payload["stagedAttachments"] = ["lease-doc-1"]
        let revision = try await fixture.revision(conversationID: conversationID)
        let envelope = fixture.launchEnvelope(
            conversationID: conversationID, payload: payload,
            revisionVersion: revision, correlation: "corr:doc")
        let reply = await fixture.makeDomain().start(
            envelope: envelope, receipt: "op:v1:" + String(repeating: "f", count: 32),
            correlation: "corr:doc")
        guard case .mutationAccepted(let detail) = reply.outcome else {
            return XCTFail("expected accepted; got \(reply.outcome)")
        }
        let runID = try XCTUnwrap(UUID(uuidString: detail["runID"] ?? ""))
        _ = await waitDurableTerminal(fixture: fixture, runID: runID)
        // The attachment row exists bound to the committed user message.
        let attachments = try await fixture.conversationStore
            .attachments(conversationID: conversationID)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.conversationID, conversationID)
        XCTAssertNotNil(attachments.first?.messageID)
        let attachment = try XCTUnwrap(attachments.first)
        let providerRequest = try XCTUnwrap(fixture.adapter.lastRequest)
        XCTAssertTrue(providerRequest.messages.contains {
            $0.role == "user" && $0.content.contains("[Attachment: \(attachment.displayName)]")
        }, "the initial provider turn must see the committed attachment name")
        let messages = try await fixture.conversationStore.messages(conversationID: conversationID)
        let userMessage = try XCTUnwrap(messages.first { $0.id == attachment.messageID })
        XCTAssertEqual(userMessage.content, "edit the staged file",
                       "provider-only attachment context must not rewrite persisted user text")
    }

    func testStartTaskCreateIntentMintsAfterAtomicCommit() async throws {
        let domain = fixture.makeDomain()
        let receipt = fixture.effects.register(correlationID: "corr:newtask")
        XCTAssertNotNil(receipt)
        let envelope = RunCommandEnvelope(object: [
            "schema": BridgeV3.commandSchema,
            "scope": BridgeV3.Scope.launch.rawValue,
            "command": "run.startTask",
            "stateful": true,
            "createIntent": true,
            "correlationID": "corr:newtask",
            "payload": [
                "title": "Fresh task",
                "goal": "begin a brand new conversation",
                "mode": "chat",
                "providerID": fixture.providerID.uuidString,
                "modelID": fixture.modelID.uuidString,
                "approvalMode": "ask",
            ],
        ])
        let reply = await domain.startTask(envelope: envelope, receipt: receipt!,
                                           correlation: "corr:newtask")
        guard case .mutationAccepted(let detail) = reply.outcome else {
            return XCTFail("expected accepted; got \(reply.outcome)")
        }
        let runID = try XCTUnwrap(UUID(uuidString: detail["runID"] ?? ""))
        _ = await waitDurableTerminal(fixture: fixture, runID: runID)
        let items = pollEffects(fixture.effects, receipt: receipt!)
        let prepared = items.first { $0.kind == .prepared }
        let conversationID = try XCTUnwrap(
            UUID(uuidString: prepared?.detail?["conversationID"] ?? ""))
        XCTAssertNotEqual(conversationID, RunStartTaskQuery.mintProbe)
        // One atomic commit created conversation + privateTask workspace +
        // run + user message + the sequence-1 status event (original
        // semantics, all-or-nothing).
        let record = try unwrapAsync(await fixture.runStore.run(id: runID))
        XCTAssertEqual(record.conversationID, conversationID)
        let firstEvents = try await fixture.runStore.events(runID: runID, afterSequence: 0,
                                                            limit: 1)
        XCTAssertEqual(firstEvents.first?.sequence, 1)
        let messages = try await fixture.conversationStore.messages(conversationID: conversationID)
        XCTAssertTrue(messages.contains { $0.role == "user" && $0.runID == runID })
    }

    func testGoalAndPlanModesLaunchRealEngineModesWithoutNewCommands() async throws {
        for mode in ["plan", "goal"] {
            let domain = fixture.makeDomain()
            let receipt = fixture.effects.register(correlationID: "corr:mode-\(mode)")
            let envelope = RunCommandEnvelope(object: [
                "schema": BridgeV3.commandSchema,
                "scope": BridgeV3.Scope.launch.rawValue,
                "command": "run.startTask",
                "stateful": true,
                "createIntent": true,
                "correlationID": "corr:mode-\(mode)",
                "payload": [
                    "title": "mode \(mode)",
                    "goal": "exercise the \(mode) engine mode",
                    "mode": mode,
                    "providerID": fixture.providerID.uuidString,
                    "modelID": fixture.modelID.uuidString,
                    "approvalMode": "ask",
                ],
            ])
            let reply = await domain.startTask(envelope: envelope, receipt: receipt!,
                                               correlation: "corr:mode-\(mode)")
            guard case .mutationAccepted = reply.outcome else {
                return XCTFail("mode \(mode) must launch through the SAME command")
            }
        }
    }

    func testGoalModeWithoutIntelligenceStoreRefusedBeforePrepare() async throws {
        var components = fixture.components()
        components.durable = RunPersistenceBundle(
            identity: .ordinary,
            conversations: fixture.conversationStore,
            runs: fixture.runStore,
            runningInputs: fixture.inputStore,
            launches: fixture.launchStore,
            childRuns: fixture.childStore,
            intelligence: nil)
        let domain = fixture.makeCustomDomain(components)
        let conversationID = try await fixture.makeOrdinaryConversation()
        let envelope = fixture.launchEnvelope(
            conversationID: conversationID,
            payload: fixture.startPayload(goal: "durable goal", mode: "goal"),
            revisionVersion: try await fixture.revision(conversationID: conversationID),
            correlation: "corr:nogoal")
        let reply = await domain.start(envelope: envelope,
                                       receipt: "op:v1:" + String(repeating: "1", count: 32),
                                       correlation: "corr:nogoal")
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("expected goal refusal")
        }
        XCTAssertEqual(error.reason, .goalModeUnsupportedStore)
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        XCTAssertEqual(runs.count, 1)
    }

    func testIngressCapturedSecretWithoutNormalizerRefusedPreEffect() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        var components = fixture.components()
        components.credentialNormalizer = nil
        let domain = fixture.makeCustomDomain(components)
        let reply = await startReply(domain, fixture: fixture,
                                     conversationID: conversationID,
                                     goal: "connect with api key: supersecretvalue123")
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("expected normalizer refusal")
        }
        XCTAssertEqual(error, RunDomainError(.needsConfiguration, .normalizerUnbound))
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        XCTAssertEqual(runs.count, 1)
    }

    func testOrdinaryLaunchRequiresVaultNormalizer() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        var components = fixture.components()
        components.credentialNormalizer = nil
        let domain = fixture.makeCustomDomain(components)
        let reply = await startReply(domain, fixture: fixture,
                                     conversationID: conversationID)
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("expected normalizerUnbound")
        }
        XCTAssertEqual(error.reason, .normalizerUnbound)
    }

    func testAbsentCorpusRefusesBeforeEffectsNeverFakeGate() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeAbsentCorpusDomain()
        let reply = await startReply(domain, fixture: fixture,
                                     conversationID: conversationID)
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("expected corpus refusal")
        }
        XCTAssertEqual(error.reason, .corpusAbsent)
    }

    func testStaleConversationRevisionRefusedBeforeCommit() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let envelope = fixture.launchEnvelope(
            conversationID: conversationID,
            payload: fixture.startPayload(goal: "stale host"),
            revisionVersion: "stale-digest",
            correlation: "corr:stale")
        let reply = await fixture.makeDomain().start(
            envelope: envelope, receipt: "op:v1:" + String(repeating: "2", count: 32),
            correlation: "corr:stale")
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("expected staleRevision")
        }
        XCTAssertEqual(error, RunDomainError(.staleRevision, .revisionMismatch))
        let runs = try await fixture.runStore.runs(conversationID: conversationID)
        XCTAssertEqual(runs.count, 1)
    }

    func testNotesPurposeConversationInvisible() async throws {
        // A purpose != 'ordinary' row answers exactly like absence (RB3
        // indistinguishability): insert one directly through GRDB.
        let notesID = UUID()
        try await fixture.database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO conversations (id, title, created_at, updated_at, mode,
                                               purpose, title_origin)
                    VALUES (?, 'notes', ?, ?, 'chat', 'notes', 'manual')
                    """,
                arguments: [notesID.uuidString,
                            RunWireDate.encode(Date()), RunWireDate.encode(Date())])
        }
        let envelope = fixture.launchEnvelope(
            conversationID: notesID, payload: fixture.startPayload(goal: "notes host"),
            revisionVersion: "anything", correlation: "corr:notes")
        let reply = await fixture.makeDomain().start(
            envelope: envelope, receipt: "op:v1:" + String(repeating: "3", count: 32),
            correlation: "corr:notes")
        guard case .rejected(let error) = reply.outcome else {
            return XCTFail("expected invisible refusal")
        }
        XCTAssertEqual(error, RunDomainError(.notFound, .conversationMissing))
    }

    func testSecondLaunchWhileFirstRunLiveUsesFreshRevisionAndDistinctRows() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        // First launch stalls inside the provider stream (stall AFTER the
        // first delta, gate never released until the end).
        let gate = RunGateBox()
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "alpha partial")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: 0)
        let replyA = await startReply(domain, fixture: fixture,
                                      conversationID: conversationID,
                                      goal: "alpha")
        guard case .mutationAccepted(let detailA) = replyA.outcome else {
            return XCTFail("alpha must launch")
        }
        let runA = try XCTUnwrap(UUID(uuidString: detailA["runID"] ?? ""))
        // While alpha is STILL live (owner handedOff), a second honest send
        // uses the CURRENT revision (snapshot-exposed) and commits its own
        // atomic preparation: distinct run + message rows, never merged.
        let revisionNow = try await fixture.revision(conversationID: conversationID)
        let envelopeB = fixture.launchEnvelope(
            conversationID: conversationID,
            payload: fixture.startPayload(goal: "beta"),
            revisionVersion: revisionNow, correlation: "corr-b")
        let replyB = await domain.start(envelope: envelopeB,
                                        receipt: "op:v1:" + String(repeating: "b", count: 32),
                                        correlation: "corr-b")
        guard case .mutationAccepted(let detailB) = replyB.outcome else {
            return XCTFail("beta must launch against the fresh revision")
        }
        let runB = try XCTUnwrap(UUID(uuidString: detailB["runID"] ?? ""))
        XCTAssertNotEqual(runA, runB)
        let owned = await domain.owners(conversationID: conversationID)
        XCTAssertEqual(Set(owned.map(\.runID)), [runA, runB])
        gate.release()
        _ = await waitDurableTerminal(fixture: fixture, runID: runA)
        _ = await waitDurableTerminal(fixture: fixture, runID: runB)
    }

    func testStaleRevisionSecondSendRefusedWhileFirstLive() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let gate = RunGateBox()
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "alpha partial")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: 0)
        let stale = try await fixture.revision(conversationID: conversationID)
        _ = await startReply(domain, fixture: fixture, conversationID: conversationID,
                             goal: "alpha")
        // A second send replaying the PRE-FIRST-COMMIT digest must be
        // refused typed (the row changed under the caller's view).
        let envelope = fixture.launchEnvelope(
            conversationID: conversationID,
            payload: fixture.startPayload(goal: "beta-stale"),
            revisionVersion: stale, correlation: "corr-b-stale")
        let reply = await domain.start(envelope: envelope,
                                       receipt: "op:v1:" + String(repeating: "c", count: 32),
                                       correlation: "corr-b-stale")
        guard case .rejected(let error) = reply.outcome else {
            gate.release()
            return XCTFail("expected staleRevision refusal")
        }
        XCTAssertEqual(error.code, .staleRevision)
        gate.release()
    }
}
