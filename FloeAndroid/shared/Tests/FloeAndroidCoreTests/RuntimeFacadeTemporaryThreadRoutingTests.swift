// SPDX-License-Identifier: MPL-2.0
//
// G02 Alpha2 temporary App-path regression:
//   temp.start -> conversation.get -> conversation.messagePage -> run.start
//   -> event.poll window -> run.snapshot -> conversation.messagePage
//   -> run.queue/run.input.*/run.cancel (second suite)
// on ONE live RB5 session over its ORIGINAL Ephemeral* stores.
//
// The assertions prove the App-equivalent ordinary command contracts reach
// the RAM session (not the durable singleton), the run reaches a REAL
// terminal, user/assistant rows are readable, the event window attaches
// with the REAL per-run sequence, and ZERO durable conversation/message/run
// rows exist. A discarded session yields typed notFound; no empty synthetic
// thread is ever returned.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeAndroidCore

// MARK: - Harness

private final class TemporaryThreadRoutingHarness {
    let fixture: RunDomainFixture
    let runDomain: FacadeRunDomain
    let gate: TemporaryNavigationGate
    let tempDomain: FacadeTemporaryDomain
    let conversationDomain: FacadeConversationDomain
    let publisher: MemoryContentPublisher

    private init(fixture: RunDomainFixture,
                 runDomain: FacadeRunDomain,
                 gate: TemporaryNavigationGate,
                 tempDomain: FacadeTemporaryDomain,
                 conversationDomain: FacadeConversationDomain,
                 publisher: MemoryContentPublisher) {
        self.fixture = fixture
        self.runDomain = runDomain
        self.gate = gate
        self.tempDomain = tempDomain
        self.conversationDomain = conversationDomain
        self.publisher = publisher
    }

    static func make(adapter: ScriptedRunAdapter? = nil) async throws
        -> TemporaryThreadRoutingHarness
    {
        let fixture = try await RunDomainFixture.make(adapter: adapter)
        let runDomain = fixture.makeDomain()
        let gate = TemporaryNavigationGate(epoch: fixture.epoch)
        let port = RuntimeFacadeTemporaryRunAdapter(
            epoch: fixture.epoch,
            launch: { query, title, receipt, conversationID, bundle in
                await runDomain.start(query: query,
                                      conversationTitle: title,
                                      receipt: receipt,
                                      conversationID: conversationID,
                                      bundleOverride: bundle)
            },
            cancel: { runID, _ in
                await runDomain.dispatchTemporaryRunCancel(runID: runID)
            },
            hasLive: { runID, _ in
                await runDomain.hasLiveTemporaryRun(runID: runID)
            },
            modelRoute: { _ in
                (fixture.providerID, fixture.modelID)
            })
        let components = TemporaryDomainComponents(
            epoch: fixture.epoch,
            gate: gate,
            effects: fixture.effects,
            database: fixture.database,
            durableConversations: fixture.conversationStore,
            durableRuns: fixture.runStore,
            durableRunningInputs: fixture.inputStore,
            toolRegistry: fixture.registry,
            runPort: port,
            webSearchAvailability: nil,
            hostSurface: nil)
        guard TemporaryDomainFacade.install(components: components,
                                            registry: RuntimeDomainRegistry()),
              let tempDomain = TemporaryDomainFacade.current(epoch: fixture.epoch)
        else {
            throw NSError(domain: "temporary-routing", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "temporary domain did not install"])
        }
        let context = ConversationFacadeContext(hostEpoch: fixture.epoch)
        let publisher = MemoryContentPublisher(maxTotalBytes: 4_194_304)
        let content = FacadeConversationContentAuthority(
            publisher: publisher,
            database: fixture.database,
            conversationStore: fixture.conversationStore,
            context: context)
        let conversationDomain = FacadeConversationDomain(
            database: fixture.database,
            conversationStore: fixture.conversationStore,
            runStore: fixture.runStore,
            runningInputStore: fixture.inputStore,
            workspaceStore: fixture.workspaceStore,
            intelligenceStore: fixture.intelligence,
            content: content,
            context: context,
            lifecycle: nil,
            credentialDrain: nil,
            workspaceCleaning: nil)
        return TemporaryThreadRoutingHarness(
            fixture: fixture, runDomain: runDomain, gate: gate,
            tempDomain: tempDomain, conversationDomain: conversationDomain,
            publisher: publisher)
    }

    func startSession(draft: String) async throws
        -> (conversationID: UUID, incarnation: UUID)
    {
        let envelope: [String: Any] = [
            "payload": ["draft": draft] as [String: Any],
        ]
        let reply = await tempDomain.start(
            envelope: envelope,
            receipt: nil,
            correlation: "temp-start-\(UUID().uuidString)")
        guard case .mutationAccepted(let detail, _) = reply.outcome,
              let rawID = detail["conversationID"],
              let conversationID = UUID(uuidString: rawID),
              let rawIncarnation = detail["incarnation"],
              let incarnation = UUID(uuidString: rawIncarnation) else {
            throw NSError(domain: "temporary-routing", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "temp.start did not return a live session"])
        }
        return (conversationID, incarnation)
    }

    func runStartEnvelope(conversationID: UUID, incarnation: UUID,
                          goal: String) -> RunCommandEnvelope {
        RunCommandEnvelope(object: [
            "owner": ["taskID": conversationID.uuidString] as [String: Any],
            "revision": [
                "resourceID": TemporarySessionRevision.resourceID(
                    conversationID: conversationID),
                "version": TemporarySessionRevision.version(incarnation: incarnation),
            ] as [String: Any],
            "payload": [
                "goal": goal,
                "mode": "chat",
                "providerID": fixture.providerID.uuidString,
                "modelID": fixture.modelID.uuidString,
                "stagedAttachments": [],
            ],
        ])
    }

    func runEnvelope(conversationID: UUID, runID: UUID,
                     revision: (String, String),
                     payload: [String: Any]) -> RunCommandEnvelope {
        RunCommandEnvelope(object: [
            "owner": ["taskID": conversationID.uuidString,
                      "runID": runID.uuidString] as [String: Any],
            "revision": ["resourceID": revision.0,
                         "version": revision.1] as [String: Any],
            "payload": payload,
        ])
    }

    func tearDown() async {
        await TemporaryDomainFacade.beginGenerationRetirement(epoch: fixture.epoch)
        await fixture.tearDown()
        RunDomainFacade.uninstall()
    }
}

// MARK: - First entry / run / events / snapshot

final class RuntimeFacadeTemporaryThreadRoutingTests: XCTestCase {
    private var harness: TemporaryThreadRoutingHarness!

    override func tearDown() async throws {
        if let harness { await harness.tearDown() }
        harness = nil
    }

    func testLiveTemporaryThreadLoadsLaunchesStreamsAndNeverPersists() async throws {
        harness = try await TemporaryThreadRoutingHarness.make()
        let fixture = harness.fixture
        let session = try await harness.startSession(draft: "hello temp")

        // 1. `conversation.get` — the App's first-entry load — must answer
        // from the LIVE session, not the durable cluster.
        let firstLoad = try await harness.conversationDomain.get(
            conversationID: session.conversationID)
        XCTAssertEqual(firstLoad.conversationID, session.conversationID)
        XCTAssertEqual(firstLoad.resourceID,
                       TemporarySessionRevision.resourceID(
                        conversationID: session.conversationID))
        XCTAssertEqual(firstLoad.revision, session.incarnation.uuidString)
        XCTAssertEqual(firstLoad.purpose, .temporary)
        XCTAssertTrue(firstLoad.runs.isEmpty)
        XCTAssertTrue(firstLoad.firstScreen.rows.isEmpty)
        XCTAssertEqual(firstLoad.messagesTotalCount, 0)
        let emptyPage = try await harness.conversationDomain.messagePage(
            conversationID: session.conversationID, payload: nil)
        XCTAssertTrue(emptyPage.rows.isEmpty)

        // 2. `run.start` with the session revision (the App's exact launch
        // contract) must launch through the RB5 port over the SAME bundle.
        let receipt = try XCTUnwrap(
            fixture.effects.register(correlationID: "temp-run-start-1"))
        let startReply = await harness.runDomain.start(
            envelope: harness.runStartEnvelope(
                conversationID: session.conversationID,
                incarnation: session.incarnation,
                goal: "hello temp"),
            receipt: receipt,
            correlation: "temp-run-start-1")
        guard case .mutationAccepted(let startDetail) = startReply.outcome else {
            return XCTFail("temporary run.start must launch, got \(startReply.outcome)")
        }
        XCTAssertEqual(startDetail["launched"], "true")
        let runID = try XCTUnwrap(UUID(uuidString: startDetail["runID"] ?? ""))
        let prepared = try XCTUnwrap(
            pollEffects(fixture.effects, receipt: receipt)
                .first { $0.kind == .prepared })
        XCTAssertEqual(prepared.detail?["runID"], runID.uuidString)
        XCTAssertEqual(prepared.detail?["conversationID"],
                       session.conversationID.uuidString)

        // 3. Wait for the REAL engine terminal in the session RAM store.
        guard let route = await harness.tempDomain.liveRoute(
            conversationID: session.conversationID) else {
            return XCTFail("live temporary route disappeared")
        }
        let settled = await pollFor(timeoutSeconds: 10) {
            guard let record = try? await route.stores.runs.run(id: runID)
            else { return false }
            return !FacadeRunDomain.activeRunStates.contains(record.state)
        }
        XCTAssertTrue(settled, "temporary run must reach a real terminal")
        let finalState = try await route.stores.runs.run(id: runID)?.state
        XCTAssertEqual(finalState, "completed")

        // 4. Actual event/read handling: the SAME event pump window the App
        // polls must attach and carry the REAL per-run sequence.
        var window: [String: Any] = [:]
        let windowAttached = await pollFor(timeoutSeconds: 8) {
            window = fixture.events.pollDurable(
                runID: runID, afterSequence: 0,
                budgetBytes: SettingsDomainV1.pageBudgetBytes)
            guard (window["windowState"] as? String) == "attached",
                  let events = window["events"] as? [[String: Any]] else {
                return false
            }
            return events.contains { ($0["kind"] as? String) == "terminal" }
        }
        XCTAssertTrue(windowAttached, "event.poll window must attach with RAM events")
        let kinds = (window["events"] as? [[String: Any]] ?? [])
            .compactMap { $0["kind"] as? String }
        XCTAssertTrue(kinds.contains("assistantText"))
        XCTAssertTrue(kinds.contains("terminal"))
        XCTAssertGreaterThan((window["watermark"] as? Int) ?? 0, 0)

        // 5. `run.snapshot` reads the SAME bundle (including after the live
        // service retires) and reports the real terminal/revision.
        let snapshotReply = await harness.runDomain.snapshot(
            envelope: harness.runEnvelope(
                conversationID: session.conversationID,
                runID: runID,
                revision: (RunWireRevision.runResourceID(runID), "completed"),
                payload: [:]))
        let page = try XCTUnwrap(snapshotReply.typedPage)
        let fields = try XCTUnwrap(
            FacadeRunDomain.unwrap(page.object) as? [String: Any])
        XCTAssertEqual(fields["runID"] as? String, runID.uuidString)
        XCTAssertEqual(fields["durableState"] as? String, "completed")
        XCTAssertEqual(fields["isTerminal"] as? Bool, true)
        XCTAssertGreaterThan((fields["durableWatermark"] as? Int64) ?? 0, 0)
        let revision = try XCTUnwrap(fields["revision"] as? [String: Any])
        XCTAssertEqual(revision["resourceID"] as? String,
                       RunWireRevision.runResourceID(runID))
        XCTAssertEqual(revision["version"] as? String, "completed")

        // 6. Real RAM user + assistant rows through the App's message page.
        let messages = try await harness.conversationDomain.messagePage(
            conversationID: session.conversationID, payload: nil)
        let contents = messages.rows.compactMap(\.content)
        XCTAssertTrue(contents.contains("hello temp"))
        XCTAssertTrue(contents.contains("fixture answer"))
        XCTAssertFalse(messages.usesContentHandles)

        let reload = try await harness.conversationDomain.get(
            conversationID: session.conversationID)
        XCTAssertEqual(reload.runs.map(\.runID), [runID])
        XCTAssertEqual(reload.runs.first?.state, "completed")
        XCTAssertEqual(reload.messagesTotalCount, 2)
        XCTAssertEqual(reload.firstScreen.rows.count, 2)

        // 7. Zero durable rows: the App-path reads never promoted anything.
        let durableConversations = try await fixture.durableConversationCount()
        let durableRuns = try await fixture.durableRunCount()
        let durableMessages = try await fixture.durableMessageCount()
        XCTAssertEqual(durableConversations, 0)
        XCTAssertEqual(durableRuns, 0)
        XCTAssertEqual(durableMessages, 0)
        XCTAssertEqual(fixture.checkpointFileCount, 0)

        // 8. Discard: the RAM authority is gone; a read by the old hosted id
        // answers typed notFound (no empty synthetic thread, no ordinary
        // fallback row). Process death has nothing to restore because nothing
        // was ever durable.
        let endReply = await harness.tempDomain.end(
            conversationID: session.conversationID,
            incarnation: session.incarnation)
        guard case .mutationAccepted = endReply.outcome else {
            return XCTFail("temporary end must accept, got \(endReply.outcome)")
        }
        do {
            _ = try await harness.conversationDomain.get(
                conversationID: session.conversationID)
            XCTFail("a discarded temporary session must not load")
        } catch {
            // typed notFound (no durable row exists)
        }
    }

    func testTemporaryRetryReownsTheSameRunFromRamHistory() async throws {
        harness = try await TemporaryThreadRoutingHarness.make()
        let fixture = harness.fixture
        let session = try await harness.startSession(draft: "retry temp")
        guard let route = await harness.tempDomain.liveRoute(
            conversationID: session.conversationID) else {
            return XCTFail("live temporary route disappeared")
        }
        // A REAL failed record in the session's own store (the retry path
        // must re-own this SAME id, never mint a new run or read durable
        // history/checkpoints).
        let runID = UUID()
        try await route.stores.runs.saveRun(RunRecord(
            id: runID,
            conversationID: session.conversationID,
            state: "failed",
            goal: "retry goal",
            startedAt: Date(),
            providerID: fixture.providerID,
            modelID: fixture.modelID,
            providerName: "Fixture",
            modelName: "Fixture Model",
            conversationMode: "chat"))
        let receipt = try XCTUnwrap(
            fixture.effects.register(correlationID: "temp-retry-1"))
        let reply = await harness.runDomain.retry(
            envelope: harness.runEnvelope(
                conversationID: session.conversationID,
                runID: runID,
                revision: (RunWireRevision.runResourceID(runID), "failed"),
                payload: ["expectedState": "failed"]),
            receipt: receipt)
        guard case .mutationAccepted(let detail) = reply.outcome else {
            return XCTFail("temporary retry must re-own the run, got \(reply.outcome)")
        }
        XCTAssertEqual(detail["resumed"], "true")
        let settled = await pollFor(timeoutSeconds: 10) {
            guard let record = try? await route.stores.runs.run(id: runID)
            else { return false }
            return !FacadeRunDomain.activeRunStates.contains(record.state)
        }
        XCTAssertTrue(settled, "retried temporary run must reach a terminal")
        let finalRecord = try await route.stores.runs.run(id: runID)
        if finalRecord?.state != "completed" {
            let events = (try? await route.stores.runs.events(runID: runID)) ?? []
            let errors = (try? await route.stores.runs.errors(runID: runID)) ?? []
            print("RETRY_DIAG state=\(finalRecord?.state ?? "nil")")
            for event in events.suffix(20) {
                print("RETRY_EVENT kind=\(event.kind.rawValue) payload=\(event.payloadJSON)")
            }
            for error in errors {
                print("RETRY_ERROR kind=\(error.kind) recoverable=\(error.recoverable) message=\(error.message)")
            }
            let allMessages = (try? await route.stores.conversations.messages(
                conversationID: session.conversationID)) ?? []
            for message in allMessages {
                print("RETRY_MESSAGE role=\(message.role) bytes=\(message.content.utf8.count) prefix=\(message.content.prefix(120))")
            }
        }
        XCTAssertEqual(finalRecord?.state, "completed")
        let messages = try await route.stores.conversations.messages(
            conversationID: session.conversationID)
        XCTAssertTrue(messages.contains { $0.role == "assistant"
            && $0.content.contains("fixture answer") })
        let durableMessages = try await fixture.durableMessageCount()
        let durableRuns = try await fixture.durableRunCount()
        XCTAssertEqual(durableMessages, 0)
        XCTAssertEqual(durableRuns, 0)
        _ = await harness.tempDomain.end(
            conversationID: session.conversationID,
            incarnation: session.incarnation)
    }

    func testOversizeTemporaryMessageUsesRamContentHandleAndFullRead() async throws {
        harness = try await TemporaryThreadRoutingHarness.make()
        let fixture = harness.fixture
        let session = try await harness.startSession(draft: "")
        guard let route = await harness.tempDomain.liveRoute(
            conversationID: session.conversationID) else {
            return XCTFail("live temporary route disappeared")
        }
        // > 48 KiB of ordinary text: the page must stage it in the SAME
        // bounded reader with a temp owner/incarnation, never truncate it,
        // never inline a partial, and never create a durable row.
        let longText = String(repeating: "Large temporary turn. ", count: 2_800)
        XCTAssertGreaterThan(longText.utf8.count, SettingsDomainV1.pageBudgetBytes)
        try await route.stores.conversations.appendMessage(PersistedMessage(
            id: UUID(),
            conversationID: session.conversationID,
            role: "assistant",
            content: longText,
            createdAt: Date(),
            parts: [],
            runID: nil))

        let page = try await harness.conversationDomain.messagePage(
            conversationID: session.conversationID, payload: nil)
        XCTAssertEqual(page.rows.count, 1)
        XCTAssertTrue(page.usesContentHandles)
        let row = try XCTUnwrap(page.rows.first)
        XCTAssertNil(row.content)
        XCTAssertFalse(row.contentInlineComplete)
        XCTAssertEqual(row.totalBytes, longText.utf8.count)
        let handle = try XCTUnwrap(row.contentHandle)

        var offset = 0
        var fetched = Data()
        var done = false
        var depth = 0
        while !done && depth < 128 {
            let payload = try XCTUnwrap(SettingsDomainV1.JSONValue.decode(Data(
                #"{"handle":"\#(handle)","offset":\#(offset),"maxBytes":32768}"#
                    .utf8)))
            let slice = try await harness.conversationDomain.readContent(
                conversationID: session.conversationID, payload: payload)
            let chunk = try XCTUnwrap(slice.chunk.chunk.data(using: .utf8))
            fetched.append(chunk)
            done = slice.chunk.done
            if let next = slice.chunk.nextOffset {
                offset = next
            } else {
                break
            }
            depth += 1
        }
        XCTAssertTrue(done)
        XCTAssertEqual(String(decoding: fetched, as: UTF8.self), longText)
        let durableMessages = try await fixture.durableMessageCount()
        let durableConversations = try await fixture.durableConversationCount()
        let durableRuns = try await fixture.durableRunCount()
        XCTAssertEqual(durableMessages, 0)
        XCTAssertEqual(durableConversations, 0)
        XCTAssertEqual(durableRuns, 0)

        _ = await harness.tempDomain.end(
            conversationID: session.conversationID,
            incarnation: session.incarnation)
    }
}

// MARK: - Queue / input controls / cancel over the same RAM bundle

final class RuntimeFacadeTemporaryRunControlRoutingTests: XCTestCase {
    private var harness: TemporaryThreadRoutingHarness!
    private var gate: RunGateBox!

    override func tearDown() async throws {
        gate?.release()
        if let harness { await harness.tearDown() }
        harness = nil
        gate = nil
    }

    func testTemporaryQueueEditReorderRemoveAndCancelUseRamBundle() async throws {
        let gate = RunGateBox()
        self.gate = gate
        let adapter = ScriptedRunAdapter(defaultScript: .init(
            events: [.textDelta(.init(text: "partial answer")),
                     .completed(.init(stopReason: .endTurn))],
            stallAfter: 1,
            gate: gate))
        harness = try await TemporaryThreadRoutingHarness.make(adapter: adapter)
        let fixture = harness.fixture
        let session = try await harness.startSession(draft: "control temp")
        let receipt = try XCTUnwrap(
            fixture.effects.register(correlationID: "temp-control-start"))
        let startReply = await harness.runDomain.start(
            envelope: harness.runStartEnvelope(
                conversationID: session.conversationID,
                incarnation: session.incarnation,
                goal: "control temp"),
            receipt: receipt,
            correlation: "temp-control-start")
        guard case .mutationAccepted(let startDetail) = startReply.outcome,
              let runID = UUID(uuidString: startDetail["runID"] ?? "") else {
            return XCTFail("temporary control run must launch")
        }
        let waiting = await pollFor(timeoutSeconds: 8) {
            adapter.requestCount == 1 && gate.isWaiting
        }
        XCTAssertTrue(waiting, "scripted provider stream must reach the gate")
        guard let route = await harness.tempDomain.liveRoute(
            conversationID: session.conversationID) else {
            return XCTFail("live temporary route disappeared")
        }
        let loaded = try await harness.conversationDomain.get(
            conversationID: session.conversationID)
        let sessionRevision = (loaded.resourceID, loaded.revision)

        // Queue two rows through the ordinary `run.queue` contract.
        func queue(_ content: String, suffix: Int) async throws -> UUID {
            let reply = await harness.runDomain.queue(
                envelope: harness.runEnvelope(
                    conversationID: session.conversationID,
                    runID: runID,
                    revision: sessionRevision,
                    payload: ["content": content,
                              "mode": "queue",
                              "selectedModelID": fixture.modelID.uuidString]))
            guard case .mutationAccepted(let detail) = reply.outcome,
                  let inputID = UUID(uuidString: detail["inputID"] ?? "") else {
                throw NSError(domain: "temporary-routing", code: 3,
                              userInfo: [NSLocalizedDescriptionKey:
                                            "run.queue refused \(suffix): \(reply.outcome)"])
            }
            return inputID
        }
        let firstID = try await queue("first queued", suffix: 1)
        let secondID = try await queue("second queued", suffix: 2)
        var pending = try await route.stores.runningInputs.pending(
            conversationID: session.conversationID)
        XCTAssertEqual(pending.map(\.id), [firstID, secondID])
        XCTAssertTrue(pending.allSatisfy { $0.status == .queued })

        // Reorder under the REAL pendingQueue revision.
        let currentOrder = pending.filter { $0.status == .queued }.map(\.id)
        let queueVersion = RunWireRevision.queueVersion(orderedIDs: currentOrder)
        let reordered = currentOrder.reversed()
        let reorderReply = await harness.runDomain.inputReorder(
            envelope: harness.runEnvelope(
                conversationID: session.conversationID,
                runID: runID,
                revision: (RunWireRevision.pendingQueueResourceID(
                    session.conversationID), queueVersion),
                payload: ["orderedIDs": reordered.map(\.uuidString),
                          "expectedQueueVersion": queueVersion]))
        guard case .mutationAccepted = reorderReply.outcome else {
            return XCTFail("run.input.reorder must accept, got \(reorderReply.outcome)")
        }
        pending = try await route.stores.runningInputs.pending(
            conversationID: session.conversationID)
        XCTAssertEqual(pending.map(\.id), Array(reordered))

        // Edit one row (App contract: session revision + row version).
        let editable = try XCTUnwrap(
            pending.first { $0.id == firstID })
        let editReply = await harness.runDomain.inputEdit(
            envelope: harness.runEnvelope(
                conversationID: session.conversationID,
                runID: runID,
                revision: sessionRevision,
                payload: [
                    "inputID": firstID.uuidString,
                    "content": "edited queued",
                    "expectedInputVersion": RunWireRevision.inputVersion(
                        updatedAt: editable.updatedAt),
                ]))
        guard case .mutationAccepted = editReply.outcome else {
            return XCTFail("run.input.edit must accept, got \(editReply.outcome)")
        }
        let editedRowValue = try await route.stores.runningInputs.input(id: firstID)
        let editedRow = try XCTUnwrap(editedRowValue)
        XCTAssertEqual(editedRow.content, "edited queued")

        // Remove the other row.
        let removableValue = try await route.stores.runningInputs.input(id: secondID)
        let removable = try XCTUnwrap(removableValue)
        let removeReply = await harness.runDomain.inputRemove(
            envelope: harness.runEnvelope(
                conversationID: session.conversationID,
                runID: runID,
                revision: sessionRevision,
                payload: [
                    "inputID": secondID.uuidString,
                    "expectedInputVersion": RunWireRevision.inputVersion(
                        updatedAt: removable.updatedAt),
                ]))
        guard case .mutationAccepted = removeReply.outcome else {
            return XCTFail("run.input.remove must accept, got \(removeReply.outcome)")
        }
        let removedRowValue = try await route.stores.runningInputs.input(id: secondID)
        let removedRow = try XCTUnwrap(removedRowValue)
        XCTAssertEqual(removedRow.status, .cancelled)

        // Steer the remaining queued row through the ordinary run.steer CAS
        // against the LIVE temporary service.
        let steerStateValue = try await route.stores.runs.run(id: runID)?.state
        let steerState = try XCTUnwrap(steerStateValue)
        let steerReply = await harness.runDomain.steer(
            envelope: harness.runEnvelope(
                conversationID: session.conversationID,
                runID: runID,
                revision: (RunWireRevision.runResourceID(runID), steerState),
                payload: [
                    "inputID": firstID.uuidString,
                    "expectedState": steerState,
                ]))
        guard case .mutationAccepted(let steerDetail) = steerReply.outcome else {
            return XCTFail("run.steer must accept the RAM row, got \(steerReply.outcome)")
        }
        XCTAssertEqual(steerDetail["accepted"], "true")
        let steeredRowValue = try await route.stores.runningInputs.input(id: firstID)
        let steeredRow = try XCTUnwrap(steeredRowValue)
        XCTAssertTrue(steeredRow.status == .steerPending
                      || steeredRow.status == .promoting
                      || steeredRow.status == .consumed)

        // Cancel the active run through the ordinary run.cancel CAS.
        let cancelStateValue = try await route.stores.runs.run(id: runID)?.state
        let cancelState = try XCTUnwrap(cancelStateValue)
        let cancelReply = await harness.runDomain.cancel(
            envelope: harness.runEnvelope(
                conversationID: session.conversationID,
                runID: runID,
                revision: (RunWireRevision.runResourceID(runID), cancelState),
                payload: ["expectedState": cancelState]))
        guard case .mutationAccepted(let cancelDetail) = cancelReply.outcome else {
            return XCTFail("run.cancel must accept the RAM run, got \(cancelReply.outcome)")
        }
        XCTAssertTrue(["requested", "appliedC1", "pendingC0"]
            .contains(cancelDetail["cancel"] ?? ""))
        gate.release()
        let terminal = await pollFor(timeoutSeconds: 10) {
            guard let record = try? await route.stores.runs.run(id: runID)
            else { return false }
            return !FacadeRunDomain.activeRunStates.contains(record.state)
        }
        XCTAssertTrue(terminal, "cancelled temporary run must settle")

        let durableConversations = try await fixture.durableConversationCount()
        let durableRuns = try await fixture.durableRunCount()
        let durableMessages = try await fixture.durableMessageCount()
        XCTAssertEqual(durableConversations, 0)
        XCTAssertEqual(durableRuns, 0)
        XCTAssertEqual(durableMessages, 0)
    }
}
