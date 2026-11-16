// SPDX-License-Identifier: MPL-2.0
//
// Native typed user-stop settlement tests. AUTHORED, NOT EXECUTED in the
// source-only lane. They use the REAL original database/stores/runtime from
// `RunDomainFixture`; only the provider stream is a scripted test double.
//
// These tests deliberately do NOT treat a state name, a localized checkpoint
// reason or a live-owner absence as a stop proof. They assert the typed
// settlement row, the incarnation binding, the cold read-back and the
// resurrection fences (old Stop vs new retry, old retry vs new Stop).
import XCTest
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloePersistence
import FloeAgentRuntime
import FloeSecurity
@testable import FloeAndroidCore

final class RunStopSettlementTests: XCTestCase {
    private var fixture: RunDomainFixture!

    override func setUp() async throws {
        fixture = try await RunDomainFixture.make()
    }

    override func tearDown() async throws {
        RunDomainFacade.uninstall()
        await fixture?.tearDown()
        fixture = nil
    }

    // MARK: - Helpers

    private func startStalledRun(_ domain: FacadeRunDomain,
                                 conversationID: UUID,
                                 goal: String) async throws
        -> (runID: UUID, gate: RunGateBox, state: String) {
        let gate = RunGateBox()
        let index = fixture.adapter.requestCount
        fixture.adapter.enqueue(script: .init(events: [
            .textDelta(.init(text: "mid stream")),
            .completed(.init(stopReason: .endTurn)),
        ], stallAfter: 1, gate: gate), forRequest: index)
        let revision = try await fixture.revision(conversationID: conversationID)
        let receipt = "op:v1:"
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let reply = await domain.start(
            envelope: fixture.launchEnvelope(
                conversationID: conversationID,
                payload: fixture.startPayload(goal: goal),
                revisionVersion: revision,
                correlation: "corr-stop-start"),
            receipt: receipt, correlation: "corr-stop-start")
        guard case .mutationAccepted(let detail) = reply.outcome,
              let runID = UUID(uuidString: detail["runID"] ?? "") else {
            throw NSError(domain: "stop-fixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(reply.outcome)"])
        }
        let streaming = await pollFor(timeoutSeconds: 8) {
            await domain.liveService(runID)?.snapshot().stateName == "streamingModel"
        }
        XCTAssertTrue(streaming, "the runtime must really be streaming before Stop")
        let state = (try await fixture.runState(runID)) ?? "streamingModel"
        return (runID, gate, state)
    }

    private func cancelEnvelope(conversationID: UUID, runID: UUID,
                                state: String,
                                correlation: String) -> RunCommandEnvelope {
        fixture.executionEnvelope(
            command: "run.cancel", conversationID: conversationID, runID: runID,
            payload: ["expectedState": state], correlation: correlation,
            revision: ["resourceID": RunWireRevision.runResourceID(runID),
                       "version": state])
    }

    private func snapshotFields(_ domain: FacadeRunDomain,
                                conversationID: UUID, runID: UUID) async
        -> [String: SettingsDomainV1.JSONValue]? {
        let reply = await domain.snapshot(envelope: fixture.executionEnvelope(
            command: "run.snapshot", conversationID: conversationID, runID: runID,
            payload: nil, correlation: "corr-stop-snapshot"))
        guard case .completedPage(let page, _) = reply.outcome,
              case .object(let fields) = page.object else { return nil }
        return fields
    }

    private func statusObjects(_ runID: UUID) async throws -> [[String: Any]] {
        let events = try await fixture.durableEvents(runID)
        return events.compactMap { event -> [String: Any]? in
            guard event.kind == .status,
                  let data = event.payloadJSON.data(using: .utf8) else {
                return nil
            }
            return (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any]
        }
    }

    private func settlementObjects(_ runID: UUID) async throws
        -> [[String: Any]] {
        let objects = try await statusObjects(runID)
        return objects.compactMap {
            $0["floeStopSettlement"] as? [String: Any]
        }
    }

    /// Writes a REAL activation marker for a manually seeded run so the
    /// incarnation is provable exactly like a production launch/resume.
    @discardableResult
    private func appendActivationMarker(runID: UUID,
                                        conversationID: UUID) async throws
        -> RunIncarnation {
        let proof: String = try await fixture.database.writer { db in
            guard let value = try RunActivationIdentity.current(
                db: db, conversationID: conversationID) else {
                throw FloeError.storageCorrupted("activation owner disappeared")
            }
            return value
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            "state": "preparing",
            "floeActivation": [
                "version": 1, "kind": "user", "proof": proof,
            ],
        ], options: [.sortedKeys])
        _ = try await fixture.runStore.appendEvent(
            runID: runID, kind: .status,
            payloadJSON: String(decoding: payload, as: UTF8.self))
        let identity = try await fixture.runStore.stopIdentity(
            runID: runID, conversationID: conversationID)
        return try XCTUnwrap(identity?.incarnation,
                             "a written activation must produce an incarnation")
    }

    private func seedCheckpointedRun(conversationID: UUID,
                                     goal: String) async throws -> UUID {
        let runID = UUID()
        try await fixture.runStore.saveRun(RunRecord(
            id: runID, conversationID: conversationID,
            state: "checkpointed", goal: goal,
            startedAt: Date().addingTimeInterval(-120), endedAt: Date(),
            providerID: fixture.providerID, modelID: fixture.modelID,
            conversationMode: "chat"))
        return runID
    }

    // MARK: - Live runtime cancel

    func testLiveCancelWritesTypedSettlementAndColdReadbackProvesIt() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let domain = fixture.makeDomain()
        let (runID, gate, state) = try await startStalledRun(
            domain, conversationID: conversationID, goal: "typed stop")
        XCTAssertFalse(FacadeRunDomain.terminalRunStates.contains(state))

        let reply = await domain.cancel(envelope: cancelEnvelope(
            conversationID: conversationID, runID: runID, state: state,
            correlation: "corr-typed-stop"))
        guard case .mutationAccepted(let detail) = reply.outcome else {
            gate.release()
            return XCTFail("live cancel must be accepted, got \(reply.outcome)")
        }
        if detail["ownerPhase"] != "none" || detail["liveProducer"] == "true" {
            XCTAssertEqual(detail["settled"], "false")
            XCTAssertEqual(detail["cancel"], "requested")
        }

        let typedObjects = try await settlementObjects(runID)
        let typed = try XCTUnwrap(typedObjects.last,
                                  "the settlement row must be durable")
        let settlementID = try XCTUnwrap(typed["settlementID"] as? String).lowercased()
        XCTAssertEqual(typed["path"] as? String, "liveCancel")
        XCTAssertEqual(typed["reasonKey"] as? String,
                       FacadeRunDomain.parkedUserStopReason)
        XCTAssertEqual(typed["expectedState"] as? String, "checkpointed")
        XCTAssertEqual(typed["ownerAbsent"] as? Bool, true)
        let typedIncarnation = try XCTUnwrap(
            typed["incarnation"] as? [String: Any])
        let incarnation = try XCTUnwrap(typedIncarnation["proof"] as? String)
        XCTAssertEqual(incarnation.count, 64)
        XCTAssertEqual((typed["settlementDigest"] as? String)?.count, 64)
        let statusPayloads = try await statusObjects(runID)
        let statusStates = statusPayloads.compactMap { $0["state"] as? String }
        XCTAssertTrue(statusStates.contains("checkpointed"))

        gate.release()
        let retired = await pollFor(timeoutSeconds: 8) {
            await domain.ownership(runID: runID) == nil
        }
        XCTAssertTrue(retired, "the real producer must retire after the stop")

        // Cold/hot authoritative snapshot: explicit object, not a null field
        // and not the localized checkpoint reason.
        let fieldsValue = await snapshotFields(
            domain, conversationID: conversationID, runID: runID)
        let fields = try XCTUnwrap(fieldsValue)
        XCTAssertEqual(fields["liveOwner"] ?? .null, .boolean(false))
        guard case .object(let stop) = fields["stopSettlement"] else {
            return XCTFail("stopSettlement object required")
        }
        XCTAssertEqual(stop["settled"] ?? .null, .boolean(true))
        XCTAssertEqual(stop["currentIncarnation"] ?? .null, .boolean(true))
        XCTAssertEqual(stop["settlementID"] ?? .null, .string(settlementID))
        XCTAssertEqual(stop["incarnation"] ?? .null, .string(incarnation))
        XCTAssertEqual(stop["path"] ?? .null, .string("liveCancel"))
        XCTAssertEqual(stop["reasonKey"] ?? .null,
                       .string(FacadeRunDomain.parkedUserStopReason))

        // A second Stop is answered from the SAME durable proof.
        let again = await domain.cancel(envelope: cancelEnvelope(
            conversationID: conversationID, runID: runID,
            state: "checkpointed", correlation: "corr-typed-stop-again"))
        guard case .mutationAccepted(let second) = again.outcome else {
            return XCTFail("second Stop must answer from the settlement, got \(again.outcome)")
        }
        XCTAssertEqual(second["cancel"], "alreadySettled")
        XCTAssertEqual(second["settled"], "true")
        XCTAssertEqual(second["settlementID"], settlementID)
        XCTAssertEqual(second["incarnation"], incarnation)
    }

    // MARK: - Localized reason is not proof

    func testLocalizedCheckpointReasonAloneNeverProducesATypedSettlement() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let runID = try await seedCheckpointedRun(
            conversationID: conversationID, goal: "legacy localized stop")
        let _ = try await appendActivationMarker(
            runID: runID, conversationID: conversationID)
        let localized = "The task was stopped by you"
        let payload = try JSONSerialization.data(withJSONObject: [
            "state": "checkpointed", "reason": localized,
        ], options: [.sortedKeys])
        _ = try await fixture.runStore.appendEvent(
            runID: runID, kind: .status,
            payloadJSON: String(decoding: payload, as: UTF8.self))

        let readbackValue = try await fixture.runStore
            .latestStopSettlement(runID: runID,
                                  conversationID: conversationID)
        let readback = try XCTUnwrap(readbackValue)
        XCTAssertNil(readback.settlement)
        XCTAssertFalse(readback.isSettled,
                       "a localized reason must never be a settled proof")
        XCTAssertTrue(readback.isValid)

        let fieldsValue = await snapshotFields(
            fixture.makeDomain(), conversationID: conversationID, runID: runID)
        let fields = try XCTUnwrap(fieldsValue)
        guard case .object(let stop) = fields["stopSettlement"] else {
            return XCTFail("an explicit stopSettlement object is required")
        }
        XCTAssertEqual(stop["settled"] ?? .null, .boolean(false))
        XCTAssertEqual(stop["reason"] ?? .null, .string("none"))

        let settlements = try await settlementObjects(runID)
        XCTAssertTrue(settlements.isEmpty,
                      "no settlement row may be fabricated from the reason")
    }

    // MARK: - Parked dependency stop

    func testParkedDependencyStopWritesTypedSettlementAtomically() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let jobID = UUID()
        let runID = try await seedCheckpointedRun(
            conversationID: conversationID, goal: "parked stop")
        let goal = "parked stop"
        try await fixture.checkpoints.save(AgentCheckpoint(
            runID: runID, conversationID: conversationID,
            state: .preparing(.init(goal: goal)),
            messages: [ConversationMessage(role: "user", content: goal)],
            schemaVersion: DatabaseManager.currentSchemaVersion))
        let incarnation = try await appendActivationMarker(
            runID: runID, conversationID: conversationID)
        let park = try JSONSerialization.data(withJSONObject: [
            "state": "checkpointed",
            "reason": "awaiting.finite.job:" + jobID.uuidString,
        ], options: [.sortedKeys])
        _ = try await fixture.runStore.appendEvent(
            runID: runID, kind: .status,
            payloadJSON: String(decoding: park, as: UTF8.self))
        let dependencies = SQLiteRunDependencyStore(database: fixture.database)
        try await dependencies.register(RunDependencyRecord(
            jobID: jobID, runID: runID,
            conversationID: conversationID, kind: "job"))

        let database = fixture.database
        var components = fixture.components()
        components.runDependencyEdges = G02RunDependencyEdgeReader(
            database: database)
        components.commitParkedRunStop = { runID, conversationID, expected in
            await G02ParkedRunStopCommitter(database: database).commit(
                runID: runID, conversationID: conversationID,
                expectedState: expected)
        }
        components.commitParkedRunStopSettlement = {
            runID, conversationID, expected, expectedIncarnation, expectedStatusSequence in
            await G02ParkedRunStopCommitter(database: database).commitTyped(
                runID: runID, conversationID: conversationID,
                expectedState: expected,
                expectedIncarnation: expectedIncarnation,
                expectedStatusSequence: expectedStatusSequence)
        }
        components.cancelParkedRunJobs = { _, _, _ in [jobID] }
        let domain = fixture.makeCustomDomain(components)

        let stopped = await domain.stopAwaitingDependency(
            runID: runID, conversationID: conversationID)
        guard case .settled(let cancelled, let settlement) = stopped else {
            return XCTFail("parked stop must produce a typed settlement, got \(stopped)")
        }
        XCTAssertEqual(cancelled, [jobID])
        XCTAssertEqual(settlement.path, .parkedDependency)
        XCTAssertEqual(settlement.incarnation.proof, incarnation.proof)
        XCTAssertEqual(settlement.reasonKey,
                       FacadeRunDomain.parkedUserStopReason)
        XCTAssertEqual(settlement.expectedState, "checkpointed")
        XCTAssertTrue(settlement.ownerAbsent)
        let durableState = try await fixture.runState(runID)
        XCTAssertEqual(durableState, "checkpointed")
        let typedObjects = try await settlementObjects(runID)
        let typed = try XCTUnwrap(typedObjects.last)
        XCTAssertEqual(typed["path"] as? String, "parkedDependency")
        let readbackValue = try await fixture.runStore
            .latestStopSettlement(runID: runID,
                                  conversationID: conversationID)
        let readback = try XCTUnwrap(readbackValue)
        XCTAssertTrue(readback.isSettled)
        XCTAssertTrue(readback.isCurrentIncarnation)
        guard case .object(let parkedProjection) = RunStopSettlementWire.snapshotValue(
            readback, currentOwnerPresent: false, currentOwnerPhase: "none",
            currentLiveProducer: false) else {
            return XCTFail("expected parked stop projection")
        }
        XCTAssertEqual(parkedProjection["settled"], .boolean(false))
        XCTAssertEqual(parkedProjection["reason"], .string("jobsUnverified"))

        // A second Stop through the ordinary wire path reads the cold
        // settlement first, even though the run is no longer "awaiting" a
        // dependency. The old wire `alreadyRequested`/runNotRetryable answer
        // is replaced by the exact proof.
        let again = await domain.cancel(envelope: cancelEnvelope(
            conversationID: conversationID, runID: runID,
            state: "checkpointed", correlation: "corr-parked-stop-again"))
        guard case .mutationAccepted(let second) = again.outcome else {
            return XCTFail("a duplicate Stop must read the same proof, got \(again.outcome)")
        }
        XCTAssertEqual(second["cancel"], "requested")
        XCTAssertEqual(second["settled"], "false")
        let settledRows = try await settlementObjects(runID)
        XCTAssertEqual(settledRows.count, 1,
                       "a duplicate Stop must never append a second settlement")
    }

    // MARK: - Incarnation competition (store authority)

    func testOldStopCannotSettleANewerIncarnation() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let runID = try await seedCheckpointedRun(
            conversationID: conversationID, goal: "incarnation race")
        let first = try await appendActivationMarker(
            runID: runID, conversationID: conversationID)

        let secondProofValue = try await fixture.runStore
            .beginUserResume(
                runID: runID, conversationID: conversationID,
                expectedState: "checkpointed",
                expectedIncarnation: first.proof,
                observedSettlementSequence: nil)
        let secondProof = try XCTUnwrap(secondProofValue)
        let secondIdentity = try await fixture.runStore.stopIdentity(
            runID: runID, conversationID: conversationID)
        let second = try XCTUnwrap(secondIdentity?.incarnation)
        XCTAssertNotEqual(first.proof, second.proof)
        XCTAssertEqual(secondProof.proof.count, 64)
        // A later park of the SAME run now belongs to the second incarnation.
        try await fixture.runStore.updateRunState(
            id: runID, state: "checkpointed", endedAt: Date())

        let oldStop = try await fixture.runStore.commitParkedUserStop(
            runID: runID, conversationID: conversationID,
            expectedState: "checkpointed",
            expectedIncarnation: first)
        guard case .staleIncarnation = oldStop else {
            return XCTFail("an old incarnation's Stop must be stale, got \(oldStop)")
        }
        let staleSettlements = try await settlementObjects(runID)
        XCTAssertTrue(staleSettlements.isEmpty,
                      "a stale Stop writes nothing")
        let staleRuntime = try await fixture.runStore.commitRuntimeUserStop(
            runID: runID, conversationID: conversationID,
            expectedIncarnation: first)
        guard case .staleIncarnation = staleRuntime else {
            return XCTFail("old runtime settlement must be stale, got \(staleRuntime)")
        }

        let currentStop = try await fixture.runStore.commitParkedUserStop(
            runID: runID, conversationID: conversationID,
            expectedState: "checkpointed",
            expectedIncarnation: second)
        guard case .settled(let settlement) = currentStop else {
            return XCTFail("the current incarnation must settle, got \(currentStop)")
        }
        XCTAssertEqual(settlement.incarnation.proof, second.proof)
        let duplicate = try await fixture.runStore.commitParkedUserStop(
            runID: runID, conversationID: conversationID,
            expectedState: "checkpointed",
            expectedIncarnation: second)
        guard case .alreadySettled(let same) = duplicate else {
            return XCTFail("duplicate settlement expected, got \(duplicate)")
        }
        XCTAssertEqual(same.settlementID, settlement.settlementID)
        let readbackValue = try await fixture.runStore
            .latestStopSettlement(runID: runID,
                                  conversationID: conversationID)
        let readback = try XCTUnwrap(readbackValue)
        XCTAssertTrue(readback.isSettled)
        XCTAssertEqual(readback.settlement?.settlementID,
                       settlement.settlementID)
    }

    func testNewerStopFencesInFlightRetryButExplicitContinueReopensSettledRun() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let runID = try await seedCheckpointedRun(
            conversationID: conversationID, goal: "retry watermark")
        let first = try await appendActivationMarker(
            runID: runID, conversationID: conversationID)
        let stop = try await fixture.runStore.commitParkedUserStop(
            runID: runID, conversationID: conversationID,
            expectedState: "checkpointed",
            expectedIncarnation: first)
        guard case .settled(let settlement) = stop else {
            return XCTFail("initial stop expected, got \(stop)")
        }

        // A retry command that began BEFORE the stop (observed watermark nil)
        // must lose to the newer stop and write nothing.
        let inFlight = try await fixture.runStore.beginUserResume(
            runID: runID, conversationID: conversationID,
            expectedState: "checkpointed",
            expectedIncarnation: first.proof,
            observedSettlementSequence: nil)
        XCTAssertNil(inFlight,
                     "a newer stop must fence an older in-flight retry")
        let stillCheckpointed = try await fixture.runStore.run(id: runID)?.state
        XCTAssertEqual(stillCheckpointed, "checkpointed")

        // An explicit Continue begun AFTER the stop is legitimate: the stop
        // watermark it observed is exactly the settlement that already
        // settled the run.
        let resumedValue = try await fixture.runStore
            .beginUserResume(
                runID: runID, conversationID: conversationID,
                expectedState: "checkpointed",
                expectedIncarnation: first.proof,
                observedSettlementSequence: settlement.sequence)
        let resumed = try XCTUnwrap(resumedValue)
        let secondIdentity = try await fixture.runStore.stopIdentity(
            runID: runID, conversationID: conversationID)
        let second = try XCTUnwrap(secondIdentity?.incarnation)
        XCTAssertNotEqual(second.proof, first.proof)
        XCTAssertEqual(resumed.proof.count, 64)

        // The old settlement is now historical, never presented as current.
        try await fixture.runStore.updateRunState(
            id: runID, state: "checkpointed", endedAt: Date())
        let historicalValue = try await fixture.runStore
            .latestStopSettlement(runID: runID,
                                  conversationID: conversationID)
        let historical = try XCTUnwrap(historicalValue)
        XCTAssertFalse(historical.isSettled)
        XCTAssertFalse(historical.isCurrentIncarnation)
        XCTAssertEqual(historical.settlement?.settlementID,
                       settlement.settlementID)

        // A stale source incarnation cannot resume over the newer one.
        try await fixture.runStore.updateRunState(
            id: runID, state: "checkpointed", endedAt: Date())
        let staleRetry = try await fixture.runStore.beginUserResume(
            runID: runID, conversationID: conversationID,
            expectedState: "checkpointed",
            expectedIncarnation: first.proof,
            observedSettlementSequence: settlement.sequence)
        XCTAssertNil(staleRetry,
                     "the parked source incarnation is no longer current")
    }

    func testUnboundAndCorruptSettlementCannotResume() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let runID = try await seedCheckpointedRun(
            conversationID: conversationID, goal: "unbound retry")
        let unbound = try await fixture.runStore.beginUserResume(
            runID: runID, conversationID: conversationID,
            expectedState: "checkpointed", expectedIncarnation: nil,
            observedSettlementSequence: nil)
        XCTAssertNil(unbound)
        let source = try await appendActivationMarker(
            runID: runID, conversationID: conversationID)
        _ = try await fixture.runStore.appendEvent(
            runID: runID, kind: .status,
            payloadJSON: "{\"state\":\"checkpointed\",\"floeStopSettlement\":{}}")
        do {
            _ = try await fixture.runStore.stopIdentity(
                runID: runID, conversationID: conversationID)
            XCTFail("a corrupt settlement is not an absent settlement")
        } catch { }
        do {
            _ = try await fixture.runStore.beginUserResume(
                runID: runID, conversationID: conversationID,
                expectedState: "checkpointed", expectedIncarnation: source.proof,
                observedSettlementSequence: nil)
            XCTFail("a corrupt settlement must fence retry")
        } catch { }
        let current = try await fixture.runStore.run(id: runID)
        XCTAssertEqual(current?.state, "checkpointed")
    }

    func testDependencyResumeAtomicallyRejectsNewerStatus() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let runID = try await seedCheckpointedRun(
            conversationID: conversationID, goal: "park fence")
        let source = try await appendActivationMarker(
            runID: runID, conversationID: conversationID)
        let park = try await fixture.runStore.appendEvent(
            runID: runID, kind: .status,
            payloadJSON: "{\"state\":\"checkpointed\",\"reason\":\"awaiting.finite.job\"}")
        _ = try await fixture.runStore.appendEvent(
            runID: runID, kind: .status,
            payloadJSON: "{\"state\":\"checkpointed\",\"reason\":\"stopped\"}")
        let result = try await fixture.runStore.beginDependencyResume(
            runID: runID, conversationID: conversationID,
            expectedIncarnation: source.proof, observedSettlementSequence: nil,
            expectedParkSequence: park.sequence)
        XCTAssertNil(result)
        let current = try await fixture.runStore.run(id: runID)
        XCTAssertEqual(current?.state, "checkpointed")
    }

    func testLegacyExplicitContinueBootstrapsWithinResumeTransaction() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let runID = try await seedCheckpointedRun(
            conversationID: conversationID, goal: "legacy continuation")
        let beforeValue = try await fixture.runStore.stopIdentity(
            runID: runID, conversationID: conversationID)
        let before = try XCTUnwrap(beforeValue)
        XCTAssertNil(before.incarnation)
        let resumed = try await fixture.runStore.beginVerifiedUserResume(
            runID: runID, conversationID: conversationID,
            expectedState: before.state, expectedIncarnation: nil,
            observedSettlementSequence: before.latestSettlementSequence,
            expectedStatusSequence: before.latestStatusSequence)
        XCTAssertNotNil(resumed)
        let events = try await statusObjects(runID)
        XCTAssertEqual(events.filter { $0["floeLegacyBootstrap"] != nil }.count, 1)
        XCTAssertEqual(events.compactMap { $0["floeActivation"] as? [String: Any] }
            .filter { ($0["kind"] as? String) == "userResume" }.count, 1)
        let readback = try await fixture.runStore.latestStopSettlement(
            runID: runID, conversationID: conversationID)
        XCTAssertFalse(readback?.isSettled ?? true)
    }

    func testLegacyStopAfterCapturePreventsBootstrapAndResume() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let runID = try await seedCheckpointedRun(
            conversationID: conversationID, goal: "legacy stop race")
        let beforeValue = try await fixture.runStore.stopIdentity(
            runID: runID, conversationID: conversationID)
        let before = try XCTUnwrap(beforeValue)
        _ = try await fixture.runStore.commitParkedUserStop(
            runID: runID, conversationID: conversationID,
            expectedState: before.state, expectedIncarnation: nil,
            expectedStatusSequence: before.latestStatusSequence)
        let resumed = try await fixture.runStore.beginVerifiedUserResume(
            runID: runID, conversationID: conversationID,
            expectedState: before.state, expectedIncarnation: nil,
            observedSettlementSequence: before.latestSettlementSequence,
            expectedStatusSequence: before.latestStatusSequence)
        XCTAssertNil(resumed)
        let events = try await statusObjects(runID)
        XCTAssertFalse(events.contains { $0["floeLegacyBootstrap"] != nil })
        let current = try await fixture.runStore.run(id: runID)
        XCTAssertEqual(current?.state, "checkpointed")
    }

    func testStaleLegacyStopCannotStopResumedAndReparkedRun() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let runID = try await seedCheckpointedRun(
            conversationID: conversationID, goal: "stale legacy stop")
        let initial = try await fixture.runStore.stopIdentity(
            runID: runID, conversationID: conversationID)
        let before = try XCTUnwrap(initial)
        XCTAssertNil(before.incarnation)
        let resumed = try await fixture.runStore.beginVerifiedUserResume(
            runID: runID, conversationID: conversationID,
            expectedState: before.state, expectedIncarnation: nil,
            observedSettlementSequence: before.latestSettlementSequence,
            expectedStatusSequence: before.latestStatusSequence)
        XCTAssertNotNil(resumed)
        try await fixture.runStore.updateRunState(
            id: runID, state: "checkpointed", endedAt: Date())
        let countBefore = try await fixture.durableEvents(runID).count
        let result = try await fixture.runStore.commitParkedUserStop(
            runID: runID, conversationID: conversationID,
            expectedState: before.state, expectedIncarnation: nil,
            expectedStatusSequence: before.latestStatusSequence)
        guard case .staleIncarnation = result else {
            return XCTFail("old legacy Stop must not touch new activation: \(result)")
        }
        let countAfter = try await fixture.durableEvents(runID).count
        XCTAssertEqual(countBefore, countAfter)
    }

    func testCorruptNewStatusDoesNotRestoreOldStopProof() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let runID = try await seedCheckpointedRun(
            conversationID: conversationID, goal: "corrupt status")
        let activation = try await appendActivationMarker(
            runID: runID, conversationID: conversationID)
        let result = try await fixture.runStore.commitRuntimeUserStop(
            runID: runID, conversationID: conversationID,
            expectedIncarnation: activation)
        guard case .settled = result else { return XCTFail("expected valid stop") }
        _ = try await fixture.runStore.appendEvent(
            runID: runID, kind: .status, payloadJSON: "{broken")
        do {
            let readback = try await fixture.runStore.latestStopSettlement(
                runID: runID, conversationID: conversationID)
            XCTAssertFalse(readback?.isSettled ?? false)
        } catch { /* Unreadable status is an acceptable fail-closed result. */ }
        do {
            _ = try await fixture.runStore.stopIdentity(
                runID: runID, conversationID: conversationID)
            XCTFail("corrupt status must not recover older identity")
        } catch { }
    }

    func testMalformedActivationCannotUseLegacyStop() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let runID = try await seedCheckpointedRun(
            conversationID: conversationID, goal: "malformed activation")
        _ = try await fixture.runStore.appendEvent(
            runID: runID, kind: .status,
            payloadJSON: "{\"state\":\"preparing\",\"floeActivation\":{}}")
        let identity = try await fixture.runStore.stopIdentity(
            runID: runID, conversationID: conversationID)
        let captured = try XCTUnwrap(identity)
        XCTAssertNil(captured.incarnation)
        let result = try await fixture.runStore.commitParkedUserStop(
            runID: runID, conversationID: conversationID,
            expectedState: "checkpointed", expectedIncarnation: nil,
            expectedStatusSequence: captured.latestStatusSequence)
        guard case .staleIncarnation = result else {
            return XCTFail("malformed activation is not a legacy task")
        }
    }

    func testActivationOlderThan512StatusesIsNotAbsent() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let runID = try await seedCheckpointedRun(
            conversationID: conversationID, goal: "deep activation")
        let activation = try await appendActivationMarker(
            runID: runID, conversationID: conversationID)
        for _ in 0..<513 {
            _ = try await fixture.runStore.appendEvent(
                runID: runID, kind: .status, payloadJSON: "{\"state\":\"checkpointed\"}")
        }
        let identity = try await fixture.runStore.stopIdentity(
            runID: runID, conversationID: conversationID)
        XCTAssertEqual(identity?.incarnation?.proof, activation.proof)
        let stale = try await fixture.runStore.commitParkedUserStop(
            runID: runID, conversationID: conversationID,
            expectedState: "checkpointed", expectedIncarnation: nil,
            expectedStatusSequence: identity?.latestStatusSequence)
        guard case .staleIncarnation = stale else {
            return XCTFail("existing activation must never take the legacy path")
        }
    }

    func testSnapshotDoesNotClaimStopWhileCurrentOwnerExists() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let runID = try await seedCheckpointedRun(
            conversationID: conversationID, goal: "owner truth")
        let source = try await appendActivationMarker(
            runID: runID, conversationID: conversationID)
        _ = try await fixture.runStore.commitRuntimeUserStop(
            runID: runID, conversationID: conversationID,
            expectedIncarnation: source)
        let readback = try await fixture.runStore.latestStopSettlement(
            runID: runID, conversationID: conversationID)
        guard case .object(let owned) = RunStopSettlementWire.snapshotValue(
            readback, currentOwnerPresent: true, currentOwnerPhase: "admitting",
            currentLiveProducer: false),
              case .object(let retired) = RunStopSettlementWire.snapshotValue(
                readback, currentOwnerPresent: false, currentOwnerPhase: "none",
                currentLiveProducer: false) else {
            return XCTFail("expected stop projections")
        }
        XCTAssertEqual(owned["settled"], .boolean(false))
        XCTAssertEqual(owned["ownerAbsent"], .boolean(false))
        XCTAssertEqual(owned["currentOwnerPhase"], .string("admitting"))
        XCTAssertEqual(owned["currentLiveProducer"], .boolean(false))
        XCTAssertEqual(retired["settled"], .boolean(true))
    }

    func testOwnershipFenceRejectsOwnerABAAndUnknownRoot() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let runID = UUID()
        let domain = fixture.makeDomain()
        let before = await domain.currentStopOwnership(runID: runID)
        let fence = await domain.issueFence(conversationID)
        let ownership = RunOwnership(
            conversationID: conversationID, runID: runID,
            epoch: fixture.epoch, identity: .ordinary,
            launchToken: fence, bundle: fixture.components().durable)
        await domain.register(ownership)
        await domain.unregister(ownership)
        let after = await domain.currentStopOwnership(runID: runID)
        XCTAssertFalse(before.ownerPresent)
        XCTAssertFalse(after.ownerPresent)
        XCTAssertFalse(before.isStable(through: after),
                       "an owner that starts and retires must invalidate a read")
        var unknown = after
        unknown.rootEpoch = nil
        XCTAssertFalse(after.isStable(through: unknown))
        unknown = after
        unknown.stamp = nil
        XCTAssertFalse(after.isStable(through: unknown))
        guard case .object(let projected) = RunStopSettlementWire.snapshotValue(
            nil, currentOwnerPresent: false, currentOwnerPhase: "none",
            currentLiveProducer: false, ownershipVerified: false) else {
            return XCTFail("expected unknown ownership projection")
        }
        XCTAssertEqual(projected["settled"], .boolean(false))
        XCTAssertEqual(projected["currentOwnerPhase"], .string("unknown"))
        XCTAssertEqual(projected["currentLiveProducer"], .null)
    }

    func testBothSnapshotShapesReportVerifiedOwnerForNonCheckpointState() async throws {
        let conversationID = try await fixture.makeOrdinaryConversation()
        let runID = try await seedCheckpointedRun(
            conversationID: conversationID, goal: "owner fields")
        try await fixture.runStore.updateRunState(
            id: runID, state: "failed", endedAt: Date())
        let domain = fixture.makeDomain()
        for metadataOnly in [false, true] {
            let reply = await domain.snapshot(envelope: fixture.executionEnvelope(
                command: "run.snapshot", conversationID: conversationID,
                runID: runID, payload: ["metadataOnly": metadataOnly],
                correlation: "corr-owner-fields"))
            guard case .completedPage(let page, _) = reply.outcome,
                  case .object(let fields) = page.object else {
                return XCTFail("expected snapshot")
            }
            XCTAssertEqual(fields["currentOwnerPhase"], .string("none"))
            XCTAssertEqual(fields["currentLiveProducer"], .boolean(false))
            XCTAssertEqual(fields["liveOwner"], .boolean(false))
        }
    }
}
