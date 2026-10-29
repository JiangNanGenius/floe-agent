// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes-purpose assistant runtime — the ONE domain.
//
// It is a thin, trust-bound coordinator over the EXISTING pieces:
//   * `RunDomainFacade.current(epoch:)` — the accepted-epoch run domain,
//   * `NotesDomainService.shared` (`floe.notes/4`) — the Notes authority,
//   * the SAME `SQLiteConversationStore` / `SQLiteWorkspaceStore` the ordinary
//     application uses, writing a real `purpose = 'notes'` conversation row.
//
// It never creates a second run domain, provider client, agent loop, database
// or Notes store. Chat-only, closed tool ceiling, no Linux/environment/job
// role, no goal/plan/P8/discovery participation.
import Foundation
import Crypto
import FloeCore
import FloeModels
import FloeNotes
import FloePersistence
import FloeSecurity
import FloeTools

/// Process-wide Notes assistant coordinator. One instance per process; the
/// accepted epoch is (re)bound by the composition root after a real runtime
/// generation installs.
public actor NotesAssistantDomain {
    public static let shared = NotesAssistantDomain()

    private struct Binding {
        var conversationID: UUID
        var documentID: UUID
        var revision: String?
        var lastRunID: UUID?
    }

    private var epoch: UInt64?
    /// document.id → durable notes conversation binding
    private var bindings: [UUID: Binding] = [:]
    private var conversationDocuments: [UUID: UUID] = [:]
    /// Root-stop admission fence. Set by `prepareRootStop`, cleared ONLY by the
    /// same-epoch `abortRootStop`.
    private var fenced = false
    private var fencedEpoch: UInt64?
    private var stopGeneration: UInt64 = 0

    private init() {}

    // MARK: - Lifecycle binding

    /// Trusted composition binding. Never accepts a caller-supplied root or
    /// store; the epoch is the accepted runtime generation.
    public func bind(epoch: UInt64) {
        if self.epoch != epoch {
            self.epoch = epoch
            bindings.removeAll()
            conversationDocuments.removeAll()
            fenced = false
            fencedEpoch = nil
        }
    }

    public func unbind(epoch: UInt64) {
        guard self.epoch == epoch else { return }
        bindings.removeAll()
        conversationDocuments.removeAll()
        fenced = false
        fencedEpoch = nil
        self.epoch = nil
    }

    // MARK: - Entry point used by the existing Notes channel

    /// Dispatches the closed additive assistant actions. Main routes the four
    /// `NotesAssistantActions` here from `NotesDomainService.handle`.
    func handle(epoch: UInt64, requestID: String,
                action: String, payload: NotesJSONValue?) async throws -> Data {
        guard NotesAssistantActions.handles(action) else {
            throw NotesDomainError.unsupportedAction(NotesWire.bounded(action, limit: 80))
        }
        if self.epoch != epoch { bind(epoch: epoch) }
        let payload = try NotesAssistantPayload(payload)
        do {
            switch action {
            case NotesAssistantActions.status:
                return try success(try await status(payload))
            case NotesAssistantActions.open:
                return try success(try await open(payload))
            case NotesAssistantActions.start:
                return try success(try await start(payload))
            case NotesAssistantActions.transcript:
                return try success(try await transcript(payload))
            case NotesAssistantActions.cancel:
                return try success(try await cancel(payload))
            case NotesAssistantActions.stopForRestart:
                return try success(try await stopForRestart(payload))
            case NotesAssistantActions.prepareRootStop:
                return try success(try await prepareRootStop(payload))
            case NotesAssistantActions.abortRootStop:
                return try success(try await abortRootStop(payload))
            case NotesAssistantActions.drainDecisions:
                return try success(try await drainDecisions(payload))
            case NotesAssistantActions.reviewCommit:
                return try success(try await reviewCommit(payload).wireObject)
            case NotesAssistantActions.restart:
                return try success(try await restart(payload))
            default:
                throw NotesDomainError.unsupportedAction(action)
            }
        } catch let refusal as NotesAssistantRefusal {
            return NotesWire.data(from: refusal.wireObject)
        }
    }

    private func success(_ object: [String: Any]) -> Data {
        var value = object
        value["ok"] = true
        return NotesWire.data(from: value)
    }

    // MARK: - Status

    private func status(_ payload: NotesAssistantPayload) async throws -> [String: Any] {
        guard let domain = runDomain() else {
            return NotesAssistantStatusSnapshot(
                availability: .unavailable, reason: "runtimeUnavailable").wireObject
        }
        let documentID = try payload.uuidOrNil("documentID")
        var conversationID = try payload.uuidOrNil("conversationID")
        if conversationID == nil, let documentID {
            conversationID = bindings[documentID]?.conversationID
        }
        var snapshot = NotesAssistantStatusSnapshot(
            availability: .unavailable,
            documentID: documentID,
            conversationID: conversationID)
        if let documentID {
            snapshot.runID = bindings[documentID]?.lastRunID
        }
        if let conversationID {
            snapshot.runState = await domain.notesRunState(conversationID: conversationID)
            if snapshot.runID == nil {
                snapshot.runID = await domain.notesLatestRunID(
                    conversationID: conversationID)
            }
        }
        do {
            let model = try await resolveDefaultModel(domain: domain)
            snapshot.availability = .ready
            snapshot.modelLabel = model.model.displayName
        } catch {
            snapshot.availability = .notConfigured
            snapshot.reason = "modelUnavailable"
        }
        if fenced { snapshot.availability = .unavailable; snapshot.reason = "rootStopping" }
        return snapshot.wireObject
    }

    // MARK: - Open (durable purpose.notes thread)

    private func open(_ payload: NotesAssistantPayload) async throws -> [String: Any] {
        let documentID = try payload.uuid("documentID")
        let title = try payload.optionalString("title", maxBytes: 240) ?? ""
        let forceNewThread = try payload.boolOrNil("newThread") == true
        if fenced { throw NotesAssistantRefusal(.busy, "rootStopping", retryable: true) }
        guard let epoch, let domain = runDomain() else {
            throw NotesAssistantRefusal(.runtimeUnavailable, "runDomainNotInstalled",
                                        retryable: true)
        }
        let authority = NotesAuthority(epoch: epoch)
        let conversations = await domain.notesConversationStore()
        let workspace = await domain.notesWorkspaceStore()

        // 1. The Notes store's assistant_threads row is the durable authority
        //    for "which conversation owns this document". Reading it FIRST is
        //    what makes reopen and partial-open retry idempotent.
        let existing = forceNewThread
            ? nil
            : try await threadConversation(documentID: documentID, authority: authority)
        var created = false
        let conversationID: UUID
        if let existing {
            conversationID = existing
            let row = try? await conversations.conversation(id: existing)
            if let row {
                guard row.purpose == .notes else {
                    // An ordinary (or temporary) row here is a foreign binding:
                    // never retag it into a Notes thread.
                    throw NotesAssistantRefusal(.bindingRefused, "purposeNotNotes")
                }
            } else {
                // Partial open: the Notes thread committed but the main row did
                // not. Retry with the SAME id through the same stores.
                try await conversations.saveConversation(ConversationRecord(
                    id: existing,
                    title: Self.title(title, documentID: documentID),
                    createdAt: Date(),
                    updatedAt: Date(),
                    purpose: .notes))
                created = true
            }
        } else {
            let minted = UUID()
            // Bind the Notes thread FIRST (the authority that a later open
            // reads), then create the main row + workspace. A crash between
            // the two is repaired by the `existing` branch above using this
            // exact id.
            _ = try await authority.call("assistant.bind", [
                "conversationID": minted.uuidString,
                "documentID": documentID.uuidString,
                "canEdit": true,
            ])
            conversationID = minted
            created = true
            do {
                try await conversations.saveConversation(ConversationRecord(
                    id: minted,
                    title: Self.title(title, documentID: documentID),
                    createdAt: Date(),
                    updatedAt: Date(),
                    purpose: .notes))
            } catch {
                throw NotesAssistantRefusal(.storageUnavailable, "conversationWrite",
                                            retryable: true)
            }
        }
        // The original first-run transaction requires an existing task
        // workspace; ensure it BEFORE the first launch (the Notes bundle never
        // activates an empty ordinary header).
        do {
            _ = try await workspace.ensureWorkspace(
                conversationID: conversationID,
                title: Self.title(title, documentID: documentID))
        } catch {
            throw NotesAssistantRefusal(.storageUnavailable, "workspaceEnsure",
                                        retryable: true)
        }
        // Re-read all three facts: a partial outcome is never reported as an
        // open thread.
        let row = try? await conversations.conversation(id: conversationID)
        guard row?.purpose == .notes else {
            throw NotesAssistantRefusal(.storageUnavailable, "conversationMissingFromStore")
        }
        let stillBound = try await threadConversation(documentID: documentID,
                                                      authority: authority)
        guard stillBound == conversationID else {
            throw NotesAssistantRefusal(.storageUnavailable, "threadBindingMismatch")
        }
        let revision = try await domain.notesConversationRevision(
            conversationID: conversationID)
        bindings[documentID] = Binding(conversationID: conversationID,
                                       documentID: documentID,
                                       revision: revision,
                                       lastRunID: bindings[documentID]?.lastRunID)
        conversationDocuments[conversationID] = documentID
        return [
            "conversationID": conversationID.uuidString,
            "documentID": documentID.uuidString,
            "revision": revision,
            "created": created,
            "runID": bindings[documentID]?.lastRunID?.uuidString ?? NSNull(),
            "runState": (await domain.notesRunState(conversationID: conversationID))
                ?? NSNull(),
        ]
    }

    /// Reads the durable `assistant_threads` row through the existing closed
    /// `assistant.thread` projection (Main-owned
    /// `NotesEngineAssistantThreadProjection`, which reads the ONE real
    /// NotesStore). A missing projection refuses instead of guessing: a guessed
    /// id would create a second thread for the same note.
    private func threadConversation(documentID: UUID,
                                    authority: NotesAuthority) async throws -> UUID? {
        do {
            let reply = try await authority.call("assistant.thread", [
                "documentID": documentID.uuidString,
            ])
            guard let raw = reply["conversationID"] as? String else { return nil }
            return UUID(uuidString: raw)
        } catch let refusal as NotesAssistantRefusal {
            let reason = refusal.reason ?? ""
            if reason.hasPrefix("unsupportedAction") || reason.hasPrefix("invalidPayload") {
                throw NotesAssistantRefusal(.runtimeUnavailable,
                                            "notesThreadLookupUnavailable",
                                            retryable: true)
            }
            throw refusal
        }
    }

    // MARK: - Start

    private func start(_ payload: NotesAssistantPayload) async throws -> [String: Any] {
        if fenced { throw NotesAssistantRefusal(.busy, "rootStopping", retryable: true) }
        let conversationID = try payload.uuid("conversationID")
        let goal = try payload.string("goal", maxBytes: 32_768)
        guard let epoch = self.epoch, let domain = runDomain() else {
            throw NotesAssistantRefusal(.runtimeUnavailable, "runDomainNotInstalled",
                                        retryable: true)
        }
        // The route is resolved by the ORIGINAL RunModelAssembly (an explicit
        // pair is validated; otherwise the persisted default-agent preference
        // is used — never a first-provider guess). The frozen pair rides
        // `capturedLaunch` so nothing is silently re-resolved later.
        let explicitProvider = try payload.uuidOrNil("providerID")
        let explicitModel = try payload.uuidOrNil("modelID")
        guard explicitProvider == nil || explicitModel != nil else {
            throw NotesAssistantRefusal(.invalidPayload, "modelIDRequiredWithProvider")
        }
        let launch: RunModelAssembly.ResolvedPair
        do {
            guard let resolved = try await domain.notesResolvePreferred(
                modelID: explicitModel) else {
                throw NotesAssistantRefusal(.notConfigured, "modelUnavailable")
            }
            launch = resolved
        } catch let error as RunDomainError {
            throw Self.refusal(for: error)
        }
        if let explicitProvider, launch.provider.id != explicitProvider {
            throw NotesAssistantRefusal(.invalidPayload, "providerMismatch")
        }
        do {
            try await domain.notesAdmitChat(model: launch.model)
        } catch let error as RunDomainError {
            throw Self.refusal(for: error)
        }
        let documentID = try await resolveDocument(conversationID: conversationID,
                                                  payload: payload)
        let authority = NotesAuthority(epoch: epoch)
        let grants = try await authority.grants(conversationID: conversationID)
        guard grants[documentID] != nil else {
            throw NotesAssistantRefusal(.notAuthorized, "documentNotSelected")
        }
        guard let context = try await authority.runtimeContext(
            conversationID: conversationID) else {
            throw NotesAssistantRefusal(.notAuthorized, "noSelection")
        }
        // The App's real editor focus is carried as data, bounded and validated
        // against the EXACT stored document revision before any model dispatch.
        // It never grants anything: the grants above remain the only authority.
        let rawFocus = try payload.focus()
        let document = try await authority.document(
            documentID: documentID, conversationID: conversationID)
        let resolution = try NotesRunFocusResolver.resolve(
            document: document,
            documentRevision: try payload.intOrNil("documentRevision"),
            focus: rawFocus)
        let focusText = resolution.contextText
        let contextText = focusText.map { focus -> String in
            let joined = context.isEmpty ? focus : context + "\n\n" + focus
            return NotesRunFocusResolver.utf8Prefix(joined, maxBytes: 24_000)
        } ?? context
        let binding = NotesRunBinding(
            conversationID: conversationID,
            documentID: documentID,
            readableDocumentIDs: Set(grants.keys),
            editableDocumentIDs: Set(grants.filter { $0.value }.keys),
            contextText: contextText,
            focusedPageID: resolution.focus.pageID,
            focus: resolution.focus)
        guard let revision = await domain.notesConversationRevision(
            conversationID: conversationID) else {
            throw NotesAssistantRefusal(.conversationMissing, "revisionAbsent")
        }
        if let expected = try payload.optionalString("revision", maxBytes: 256),
           expected != revision {
            throw NotesAssistantRefusal(.staleRevision, "revisionMismatch", retryable: true)
        }
        let reply = await domain.startNotes(
            conversationID: conversationID,
            goal: goal,
            providerID: launch.provider.id,
            modelID: launch.model.id,
            expectedRevision: revision,
            binding: binding,
            capturedLaunch: launch)
        switch reply.outcome {
        case .mutationAccepted(let detail):
            guard let raw = detail["runID"], let runID = UUID(uuidString: raw) else {
                throw NotesAssistantRefusal(.authority, "runIdentityMissing")
            }
            var current = bindings[documentID]
                ?? Binding(conversationID: conversationID, documentID: documentID,
                           revision: revision, lastRunID: nil)
            current.lastRunID = runID
            bindings[documentID] = current
            conversationDocuments[conversationID] = documentID
            return [
                "runID": runID.uuidString,
                "conversationID": conversationID.uuidString,
                "documentID": documentID.uuidString,
                "revision": revision,
                "started": true,
            ]
        case .rejected(let error):
            throw Self.refusal(for: error)
        case .completedPage:
            throw NotesAssistantRefusal(.authority, "unexpectedPageReply")
        }
    }

    private func resolveDocument(conversationID: UUID,
                                 payload: NotesAssistantPayload) async throws -> UUID {
        if let explicit = try payload.uuidOrNil("documentID") { return explicit }
        if let bound = conversationDocuments[conversationID] { return bound }
        throw NotesAssistantRefusal(.invalidPayload, "documentIDRequired")
    }

    // MARK: - Transcript

    private func transcript(_ payload: NotesAssistantPayload) async throws -> [String: Any] {
        let conversationID = try payload.uuid("conversationID")
        let limit = min(200, max(1, try payload.intOrNil("limit") ?? 60))
        guard let domain = runDomain() else {
            throw NotesAssistantRefusal(.runtimeUnavailable, "runDomainNotInstalled",
                                        retryable: true)
        }
        let conversations = await domain.notesConversationStore()
        guard let row = try? await conversations.conversation(id: conversationID),
              row.purpose == .notes else {
            throw NotesAssistantRefusal(.conversationMissing, "conversationNotNotes")
        }
        let cursor = try NotesTranscriptPage.parseCursor(
            try payload.optionalString("olderCursor", maxBytes: 128))
        let page: ConversationMessagePage
        do {
            page = try await conversations.messagePage(
                conversationID: conversationID, before: cursor, limit: limit)
        } catch {
            throw NotesAssistantRefusal(.storageUnavailable, "transcriptRead",
                                        retryable: true)
        }
        // Durable run outcome per message run. ACTIVE is the only value the
        // controller maps to `streaming`; a cancel ACK or an empty reply is
        // never guessed into CANCELLED/COMPLETED.
        var outcomes: [UUID: String] = [:]
        for runID in Set(page.messages.compactMap(\.runID)) {
            if await domain.notesRunOwnership(runID: runID) != nil {
                // A live (accepted, non-retired) run is ACTIVE; its terminal is
                // projected from the durable terminal below on the next read.
                outcomes[runID] = "ACTIVE"
                continue
            }
            let result = await domain.notesRunOutcome(runID: runID)
            if let outcome = Self.runOutcome(state: result.state,
                                             stopReason: result.stopReason) {
                outcomes[runID] = outcome
            }
        }
        let entries = page.messages.map { message in
            NotesTranscriptEntry(
                id: message.id,
                role: message.role,
                text: message.content,
                createdAtMillis: Int64(message.createdAt.timeIntervalSince1970 * 1000),
                runID: message.runID,
                outcome: message.runID.flatMap { outcomes[$0] })
        }
        var object = NotesTranscriptPage(
            entries: entries,
            olderCursor: page.earlierCursor.map(NotesTranscriptPage.cursor),
            hasOlder: page.hasEarlier).wireObject
        object["conversationID"] = conversationID.uuidString
        object["revision"] = await domain.notesConversationRevision(
            conversationID: conversationID) ?? NSNull()
        return object
    }

    // MARK: - Cancel / stop

    private func cancel(_ payload: NotesAssistantPayload) async throws -> [String: Any] {
        let conversationID = try payload.uuid("conversationID")
        guard let domain = runDomain() else {
            throw NotesAssistantRefusal(.runtimeUnavailable, "runDomainNotInstalled",
                                        retryable: true)
        }
        var runID = try payload.uuidOrNil("runID")
        if runID == nil {
            runID = await domain.notesLatestRunID(conversationID: conversationID)
        }
        guard let runID else {
            return ["cancelled": false, "reason": "noLiveRun"]
        }
        let accepted = await domain.notesCancel(runID: runID)
        return ["cancelled": accepted, "runID": runID.uuidString,
                "reason": accepted ? "requested" : "notOwned"]
    }

    /// Restart path: stop the ACTUAL Notes run and wait for real settlement
    /// before the caller replaces the grant/openid. A cancel ACK alone is never
    /// reported as stopped.
    private func stopForRestart(_ payload: NotesAssistantPayload) async throws -> [String: Any] {
        let conversationID = try payload.uuid("conversationID")
        guard let domain = runDomain() else {
            throw NotesAssistantRefusal(.runtimeUnavailable, "runDomainNotInstalled",
                                        retryable: true)
        }
        let before = await domain.notesLiveRunIDs(conversationID: conversationID)
        for runID in before {
            _ = await domain.notesCancel(runID: runID)
        }
        let report = await waitForDrain(domain: domain,
                                        conversationIDs: [conversationID],
                                        timeoutMillis: 5_000)
        var object = report.wireObject
        object["conversationID"] = conversationID.uuidString
        object["requestedRunIDs"] = before.map(\.uuidString)
        return object
    }

    /// Root-stop admission: fence Notes, cancel every owned Notes run, then
    /// wait for the exact owned tokens to detach. `canRetire` is true only for
    /// a real drain.
    private func prepareRootStop(_ payload: NotesAssistantPayload) async throws -> [String: Any] {
        guard let domain = runDomain() else {
            return NotesStopReport.runtimeUnavailable.wireObject
        }
        fenced = true
        fencedEpoch = epoch
        stopGeneration &+= 1
        let generation = stopGeneration
        let live = await domain.notesLiveRunIDs(conversationID: nil)
        for runID in live {
            _ = await domain.notesCancel(runID: runID)
        }
        let report = await waitForDrain(domain: domain, conversationIDs: nil,
                                        timeoutMillis: 8_000)
        // A newer abort/newer stop generation makes this report stale; it must
        // never allow retirement for a later fence.
        if generation != stopGeneration {
            return NotesStopReport(canRetire: false, fenced: fenced, pendingRunIDs: [],
                                   reason: "superseded").wireObject
        }
        var object = report.wireObject
        object["requestedRunIDs"] = live.map(\.uuidString)
        object["epoch"] = (epoch ?? 0) as NSNumber
        return object
    }

    /// Same-epoch re-arm after a refused retirement: clears the admission
    /// fence, never revives a cancelled run and never stops/rebinds a root.
    private func abortRootStop(_ payload: NotesAssistantPayload) async throws -> [String: Any] {
        let requestEpoch = try payload.uint64OrNil("epoch")
        if let requestEpoch, let fencedEpoch, requestEpoch < fencedEpoch {
            throw NotesAssistantRefusal(.staleRevision, "epochFenced")
        }
        let wasFenced = fenced
        fenced = false
        fencedEpoch = nil
        stopGeneration &+= 1
        return ["rearmed": wasFenced, "fenced": false,
                "epoch": (epoch ?? 0) as NSNumber]
    }

    /// Bounded drain proof. Never treats a timeout as drained: the returned
    /// report carries the exact still-attached run ids.
    private func waitForDrain(domain: FacadeRunDomain,
                              conversationIDs: Set<UUID>?,
                              timeoutMillis: Int) async -> NotesStopReport {
        let deadline = Date().addingTimeInterval(Double(timeoutMillis) / 1000)
        while true {
            let snapshot = await domain.notesOwnedRunTokens(conversationIDs: conversationIDs)
            let live = await domain.notesLiveRunIDs(conversationID: nil)
            let inScope = snapshot.filter { entry in
                conversationIDs?.contains(entry.conversationID) ?? true
            }
            // REAL drain proof: a run is still pending while it has any
            // registry-attached exact token (run/child/tool) or has not reached
            // the retired phase. A cancel ACK, a pump close or the timeout
            // below is never treated as drained.
            let pending = inScope.filter { entry in
                entry.phase != .retired
                    || entry.tokens.contains {
                        RuntimeOwnedWorkRegistry.shared.isAttached($0)
                    }
            }.map(\.runID)
            let liveInScope = live.filter { runID in
                conversationIDs == nil
                    || inScope.contains { $0.runID == runID }
            }
            if pending.isEmpty, liveInScope.isEmpty {
                return NotesStopReport(canRetire: true, fenced: fenced,
                                       pendingRunIDs: [], reason: "drained")
            }
            if Date() >= deadline {
                let merged = Array(Set(pending + liveInScope))
                    .sorted { $0.uuidString < $1.uuidString }
                return NotesStopReport(canRetire: false, fenced: fenced,
                                       pendingRunIDs: merged, reason: "pendingWork")
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Proposal decisions

    /// Delivers final proposal decisions into THIS conversation exactly once:
    /// durable transcript append + durable pending-input enqueue, then the
    /// native outbox ACK. Never launches an ordinary drain and never widens the
    /// Notes tool ceiling; the next real Notes turn consumes the queued row.
    private func drainDecisions(_ payload: NotesAssistantPayload) async throws -> [String: Any] {
        let conversationID = try payload.uuid("conversationID")
        let limit = min(200, max(1, try payload.intOrNil("limit") ?? 32))
        guard let epoch, let domain = runDomain() else {
            throw NotesAssistantRefusal(.runtimeUnavailable, "runDomainNotInstalled",
                                        retryable: true)
        }
        let authority = NotesAuthority(epoch: epoch)
        let conversations = await domain.notesConversationStore()
        let inputs = await domain.notesRunningInputStore()
        guard let row = try? await conversations.conversation(id: conversationID),
              row.purpose == .notes else {
            throw NotesAssistantRefusal(.conversationMissing, "conversationNotNotes")
        }
        let decisions = try await authority.outbox(conversationID: conversationID,
                                                  limit: limit)
        var delivered: [[String: Any]] = []
        for decision in decisions {
            guard (decision["ready"] as? Bool) == true,
                  let rawIntent = decision["intentID"] as? String,
                  let intentID = UUID(uuidString: rawIntent),
                  let rawEvent = decision["eventID"] as? String,
                  let eventID = UUID(uuidString: rawEvent),
                  let content = decision["content"] as? String,
                  !content.isEmpty else { continue }
            let documentID = (decision["documentID"] as? String)
                .flatMap(UUID.init(uuidString:))
            // Durable append + enqueue are both idempotent by the stable event
            // id; ACK happens only after BOTH succeeded.
            do {
                if try await inputs.input(id: eventID) == nil {
                    _ = try await inputs.enqueue(PendingUserInput(
                        id: eventID,
                        conversationID: conversationID,
                        content: content,
                        mode: .queue,
                        status: .queued,
                        workspaceID: nil,
                        executionMode: "chat"))
                }
                try await conversations.appendMessage(PersistedMessage(
                    id: eventID,
                    conversationID: conversationID,
                    role: "system",
                    content: content,
                    createdAt: Date()))
                _ = try await authority.acknowledge(intentID: intentID,
                                                    eventID: eventID)
            } catch let refusal as NotesAssistantRefusal {
                // A not-yet-final intent stays queued for the next drain.
                if refusal.retryable { continue }
                throw refusal
            }
            var entry: [String: Any] = [
                "eventID": eventID.uuidString,
                "intentID": intentID.uuidString,
                "decision": decision["decision"] as? String ?? "",
            ]
            entry["proposalID"] = decision["proposalID"] ?? NSNull()
            entry["documentID"] = documentID?.uuidString ?? NSNull()
            entry["revision"] = decision["revision"] ?? NSNull()
            delivered.append(entry)
        }
        // Notes-specific drain: after delivering, an EXPLICIT drain may launch
        // one queued decision row through the SAME closed Notes profile when
        // nothing is running. This never flips the ordinary queue guard and
        // never auto-resumes after process death (the row waits for this call).
        var queuedLaunch: [String: Any]? = nil
        if try payload.boolOrNil("launchQueued") == true {
            queuedLaunch = try await launchQueuedDecision(conversationID: conversationID)
        }
        var object: [String: Any] = [
            "conversationID": conversationID.uuidString,
            "delivered": delivered,
            "total": decisions.count,
        ]
        object["queuedLaunch"] = queuedLaunch ?? NSNull()
        return object
    }

    /// Durable run-state → transcript outcome. Only REAL evidence maps:
    /// a completed run whose terminal stop reason is `cancelled` is CANCELLED;
    /// an absent row yields nil (no guessed outcome).
    static func runOutcome(state: String?, stopReason: String?) -> String? {
        guard let state else { return nil }
        switch state {
        case "completed":
            return stopReason == "cancelled" ? "CANCELLED" : "COMPLETED"
        case "failed":
            return "FAILED"
        case "checkpointed":
            return "CHECKPOINTED"
        case "interrupted":
            return "INTERRUPTED"
        case "cancelling":
            return "ACTIVE"
        case "preparing", "streamingModel", "waitingApproval", "executingTool",
             "compacting", "paused", "verifying":
            return "ACTIVE"
        default:
            return "ACTIVE"
        }
    }

    // MARK: - Trusted proposal review/commit

    /// The trusted review step. The model NEVER calls this: `notes.edit` calls
    /// it after `proposal.create` returned the durable proposal identity.
    ///
    /// Everything below is re-read from the live native store and the live run
    /// domain immediately before the commit:
    ///   * the proposal is pending, is THIS document, and was authored by THIS
    ///     exact tool call (`sourceRequestID`);
    ///   * the document is owned by THIS conversation (`assistant_threads`) and
    ///     still holds a live canEdit grant;
    ///   * the run that received the tool call is still the live Notes owner;
    ///   * the closed edit family is locally undoable and non-destructive;
    ///   * the revision AND the canonical document fingerprint still match.
    /// Only then is the single-use grant minted and consumed internally. The
    /// public editor-only `proposal.issueGrant` action is untouched.
    /// Explicit restart: the real per-conversation stop/drain FIRST, then a
    /// fresh durable thread. A run that has not really settled refuses with the
    /// pending identity set (the caller must not treat a cancel ACK as drained).
    private func restart(_ payload: NotesAssistantPayload) async throws -> [String: Any] {
        let documentID = try payload.uuid("documentID")
        let title = try payload.optionalString("title", maxBytes: 240) ?? ""
        var conversationID = try payload.uuidOrNil("conversationID")
        if conversationID == nil {
            conversationID = bindings[documentID]?.conversationID
        }
        if let conversationID {
            let stopPayload = try NotesAssistantPayload(.object([
                "conversationID": .string(conversationID.uuidString),
            ]))
            let stop = try await stopForRestart(stopPayload)
            if (stop["canRetire"] as? Bool) != true {
                var object = stop
                object["restarted"] = false
                object["reason"] = "runNotDrained"
                return object
            }
        }
        let openPayload = try NotesAssistantPayload(.object([
            "documentID": .string(documentID.uuidString),
            "title": .string(title),
            "newThread": .boolean(true),
        ]))
        let opened = try await open(openPayload)
        var object = opened
        object["restarted"] = true
        object["replacedConversationID"] = conversationID?.uuidString ?? NSNull()
        return object
    }

    /// Typed entry point for the trusted `notes.edit` tool (same checks as the
    /// closed `assistant.reviewCommit` action, without crossing the JSON
    /// channel). Not model-reachable: the tool passes the REAL `ToolContext`
    /// identities it received.
    public func reviewCommitForTool(proposalID: UUID,
                                    documentID: UUID,
                                    conversationID: UUID,
                                    runID: UUID,
                                    toolCallID: String?,
                                    expectedRevision: Int,
                                    editActions: [String],
                                    editCount: Int,
                                    environmentID: String?) async -> NotesReviewReport {
        let payload: NotesJSONValue = .object([
            "proposalID": .string(proposalID.uuidString),
            "documentID": .string(documentID.uuidString),
            "conversationID": .string(conversationID.uuidString),
            "runID": .string(runID.uuidString),
            "toolCallID": toolCallID.map { .string($0) } ?? .null,
            "expectedRevision": .integer(expectedRevision),
            "editCount": .integer(editCount),
            "editActions": .array(editActions.map { .string($0) }),
            "environmentID": environmentID.map { .string($0) } ?? .null,
        ])
        do {
            guard let parsed = try? NotesAssistantPayload(payload) else {
                return NotesReviewReport(status: "pendingUserDecision", applied: false,
                                         reason: "invalidPayload")
            }
            return try await reviewCommit(parsed)
        } catch let refusal as NotesAssistantRefusal {
            return NotesReviewReport(status: "pendingUserDecision", applied: false,
                                     reason: refusal.reason ?? "reviewRefused")
        } catch {
            return NotesReviewReport(status: "pendingUserDecision", applied: false,
                                     reason: "reviewFailed")
        }
    }

    private func reviewCommit(_ payload: NotesAssistantPayload) async throws -> NotesReviewReport {
        let proposalID = try payload.uuid("proposalID")
        let documentID = try payload.uuid("documentID")
        let conversationID = try payload.uuid("conversationID")
        let runID = try payload.uuid("runID")
        let toolCallID = try payload.optionalString("toolCallID", maxBytes: 256)
        let expectedRevision = try payload.intOrNil("expectedRevision") ?? 0
        let editCount = try payload.intOrNil("editCount") ?? 0
        let actions = (try payload.stringArray("editActions", maxItems: 200)) ?? []
        let environmentID = try payload.optionalString("environmentID", maxBytes: 512)
        let family = NotesProposalEditFamily(actions: actions, count: editCount)
        guard let epoch, let domain = runDomain() else {
            throw NotesAssistantRefusal(.runtimeUnavailable, "runDomainNotInstalled",
                                        retryable: true)
        }
        // Live run ownership: the exact run that received this tool call is
        // still the Notes owner of this conversation.
        let ownership = await domain.notesRunOwnership(runID: runID)
        let authority = NotesAuthority(epoch: epoch)
        // Native facts (origin-scoped read; a foreign task sees notFound).
        let proposal = try await authority.proposal(
            proposalID: proposalID, documentID: documentID,
            conversationID: conversationID, environmentID: environmentID)
        let grants = try await authority.grants(conversationID: conversationID)
        let threadOwner = try await threadConversation(documentID: documentID,
                                                       authority: authority)
        // Current baseline (revision + canonical fingerprint).
        let current: NoteDocument?
        do {
            current = try await authority.document(documentID: documentID,
                                                   conversationID: conversationID)
        } catch let refusal as NotesAssistantRefusal {
            // A revoked grant/stale identity produces NO write.
            return Self.reviewObject(.pending(reason: refusal.reason ?? "documentUnavailable"))
        }
        let fingerprint = current.map(NoteDocumentFingerprint.sha256(of:)) ?? ""
        let facts = NotesProposalReviewFacts(
            proposalID: proposalID,
            documentID: (proposal["documentID"] as? String).flatMap(UUID.init(uuidString:)) ?? documentID,
            proposalStatus: proposal["status"] as? String ?? "",
            proposalSourceRequestID: proposal["sourceRequestID"] as? String,
            proposalBaseRevision: (proposal["baseRevision"] as? NSNumber)?.intValue ?? -1,
            proposalBaseSHA256: proposal["baseSHA256"] as? String ?? "",
            proposalEditCount: (proposal["editCount"] as? NSNumber)?.intValue ?? -1,
            threadConversationID: threadOwner,
            liveCanEdit: grants[documentID] == true,
            runConversationID: ownership?.conversationID,
            runIsLive: ownership.map { $0.phase == .handedOff && !$0.cancelRequested } ?? false)
        if let outcome = NotesProposalReviewPolicy.refusal(
            facts,
            conversationID: conversationID,
            documentID: documentID,
            runID: runID,
            toolCallID: toolCallID,
            family: family,
            currentRevision: current?.revision ?? -1,
            currentFingerprint: fingerprint) {
            return Self.reviewObject(outcome)
        }
        if let current, current.revision < expectedRevision {
            return Self.reviewObject(.conflict(reason: "revisionOrSourceChanged"))
        }
        // Mint/consume the single-use grant INTERNALLY and apply exactly once.
        do {
            let grant = try await authority.issueGrant(proposalID: proposalID,
                                                       documentID: documentID)
            guard let grantID = grant["grantID"] as? String, !grantID.isEmpty else {
                return Self.reviewObject(.pending(reason: "grantIdentityMissing"))
            }
            let applied = try await authority.applyProposal(
                proposalID: proposalID, documentID: documentID, grantID: grantID,
                conversationID: conversationID, environmentID: environmentID)
            let result = applied["result"] as? [String: Any] ?? [:]
            let revision = (result["appliedRevision"] as? NSNumber)?.intValue
                ?? (applied["document"] as? [String: Any])
                    .flatMap { $0["revision"] as? NSNumber }?.intValue
            let replayed = result["replayed"] as? Bool ?? false
            return Self.reviewObject(.applied(revision: revision, replayed: replayed))
        } catch let refusal as NotesAssistantRefusal {
            let reason = refusal.reason ?? ""
            if reason.hasPrefix("conflict") || reason.contains("revisionOrSourceChanged") {
                return Self.reviewObject(.conflict(reason: "revisionOrSourceChanged"))
            }
            if refusal.retryable {
                return Self.reviewObject(.pending(reason: "authorityBusy"))
            }
            return Self.reviewObject(.pending(reason: "authorityRefused"))
        }
    }

    private static func reviewObject(_ outcome: NotesReviewOutcome) -> NotesReviewReport {
        switch outcome {
        case .applied(let revision, let replayed):
            return NotesReviewReport(status: "applied", applied: true,
                                     appliedRevision: revision, replayed: replayed)
        case .pending(let reason):
            return NotesReviewReport(status: "pendingUserDecision", applied: false,
                                     reason: reason)
        case .conflict(let reason):
            return NotesReviewReport(status: "conflict", applied: false,
                                     reason: reason)
        }
    }

    // MARK: - Notes-specific queued decision drain

    /// Launches ONE queued decision row through the SAME closed Notes profile
    /// when (and only when) the conversation has no live run. The row is marked
    /// consumed with the REAL run identity after the atomic commit; a refusal
    /// leaves it queued for the next explicit drain.
    private func launchQueuedDecision(conversationID: UUID) async throws -> [String: Any]? {
        guard let epoch, let domain = runDomain() else {
            throw NotesAssistantRefusal(.runtimeUnavailable, "runDomainNotInstalled",
                                        retryable: true)
        }
        guard await domain.notesLiveRunIDs(conversationID: conversationID).isEmpty else {
            return ["launched": false, "reason": "runActive"]
        }
        let inputs = await domain.notesRunningInputStore()
        guard let row = try await inputs.claimNextQueued(conversationID: conversationID) else {
            return nil
        }
        do {
            let launch: RunModelAssembly.ResolvedPair
            guard let resolved = try await domain.notesResolvePreferred(modelID: nil) else {
                try await inputs.restoreQueued(id: row.id)
                return ["launched": false, "reason": "modelUnavailable"]
            }
            launch = resolved
            try await domain.notesAdmitChat(model: launch.model)
            let authority = NotesAuthority(epoch: epoch)
            let grants = try await authority.grants(conversationID: conversationID)
            guard let documentID = conversationDocuments[conversationID]
                    ?? grants.keys.sorted(by: { $0.uuidString < $1.uuidString }).first,
                  let context = try await authority.runtimeContext(
                    conversationID: conversationID) else {
                try await inputs.restoreQueued(id: row.id)
                return ["launched": false, "reason": "noSelection"]
            }
            let binding = NotesRunBinding(
                conversationID: conversationID,
                documentID: documentID,
                readableDocumentIDs: Set(grants.keys),
                editableDocumentIDs: Set(grants.filter { $0.value }.keys),
                contextText: context)
            let revision = await domain.notesConversationRevision(
                conversationID: conversationID) ?? ""
            let reply = await domain.startNotes(
                conversationID: conversationID,
                goal: row.content,
                providerID: launch.provider.id,
                modelID: launch.model.id,
                expectedRevision: revision,
                binding: binding,
                capturedLaunch: launch)
            switch reply.outcome {
            case .mutationAccepted(let detail):
                guard let raw = detail["runID"], let runID = UUID(uuidString: raw) else {
                    try await inputs.restoreQueued(id: row.id)
                    return ["launched": false, "reason": "runIdentityMissing"]
                }
                try await inputs.markConsumed(id: row.id, runID: runID)
                return ["launched": true, "runID": runID.uuidString,
                        "inputID": row.id.uuidString]
            case .rejected:
                try await inputs.restoreQueued(id: row.id)
                return ["launched": false, "reason": "launchRefused"]
            case .completedPage:
                try await inputs.restoreQueued(id: row.id)
                return ["launched": false, "reason": "unexpectedPage"]
            }
        } catch {
            // Every failure restores the durable row; a refused drain never
            // drops queued content.
            try? await inputs.restoreQueued(id: row.id)
            throw NotesAssistantRefusal(.storageUnavailable, "queuedDrainFailed",
                                        retryable: true)
        }
    }

    // MARK: - Model resolution


    private struct ResolvedModel {
        let provider: ProviderProfile
        let model: ModelProfile
    }

    /// Resolves the configured default agent model. An unconfigured install is
    /// `notConfigured` — it never blocks ordinary offline Notes editing.
    private func resolveDefaultModel(domain: FacadeRunDomain) async throws -> ResolvedModel {
        let store = await domain.notesModelStore()
        let preferences = try await store.preferences()
        guard let modelID = preferences.defaultAgentModelID,
              let model = try await store.model(id: modelID),
              model.isEnabled,
              model.capabilities.contains(.text) else {
            throw NotesAssistantRefusal(.notConfigured, "agentModelUnavailable")
        }
        guard let provider = try await store.provider(id: model.providerID),
              provider.isEnabled else {
            throw NotesAssistantRefusal(.notConfigured, "providerUnavailable")
        }
        return ResolvedModel(provider: provider, model: model)
    }

    // MARK: - Helpers

    private func runDomain() -> FacadeRunDomain? {
        guard let epoch else { return nil }
        return RunDomainFacade.current(epoch: epoch)?.0
    }

    private static func title(_ raw: String, documentID: UUID) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Notes assistant" : String(trimmed.prefix(80))
    }

    private static func refusal(for error: RunDomainError) -> NotesAssistantRefusal {
        switch error.reason {
        case .conversationMissing, .runMissing:
            return NotesAssistantRefusal(.conversationMissing, error.reason.rawValue)
        case .revisionMismatch, .revisionAbsent:
            return NotesAssistantRefusal(.staleRevision, error.reason.rawValue, retryable: true)
        case .launchAlreadyInFlight, .conversationActive, .serviceAlreadyLive:
            return NotesAssistantRefusal(.busy, error.reason.rawValue, retryable: true)
        case .deletingGuarded, .generationRetired, .epochFenced:
            return NotesAssistantRefusal(.runtimeUnavailable, error.reason.rawValue)
        case .notesRuntimeUnbound:
            return NotesAssistantRefusal(.runtimeUnavailable, error.reason.rawValue)
        case .payloadInvalid, .payloadTooLarge:
            return NotesAssistantRefusal(.invalidPayload, error.reason.rawValue)
        case .storeWriteFailed, .storeReadFailed:
            return NotesAssistantRefusal(.storageUnavailable, error.reason.rawValue,
                                         retryable: true)
        case .providerDisabled, .modelDisabled, .modelBelongsToOtherProvider,
             .localInferenceUnsupported:
            return NotesAssistantRefusal(.notConfigured, error.reason.rawValue)
        case .gatewayUnregistered, .secretMissing, .secretInvalidated, .secretLocked:
            return NotesAssistantRefusal(.notConfigured, error.reason.rawValue)
        case .transportNotQualified:
            return NotesAssistantRefusal(.notConfigured, error.reason.rawValue)
        case .corpusAbsent, .corpusInvalid:
            return NotesAssistantRefusal(.runtimeUnavailable, error.reason.rawValue)
        default:
            return NotesAssistantRefusal(.authority, error.reason.rawValue)
        }
    }
}

// MARK: - Payload reader

/// Strict typed access to one assistant action payload. Mirrors the existing
/// `NotesPayload` discipline: missing and explicit-null stay distinguishable.
private struct NotesAssistantPayload {
    private let object: [String: NotesJSONValue]

    init(_ value: NotesJSONValue?) throws {
        guard let value, !value.isNull else { object = [:]; return }
        guard case .object(let object) = value else {
            throw NotesAssistantRefusal(.invalidPayload, "payloadNotObject")
        }
        self.object = object
    }

    func uuid(_ key: String) throws -> UUID {
        guard let raw = object[key]?.stringValue, let value = UUID(uuidString: raw) else {
            throw NotesAssistantRefusal(.invalidPayload, "missingOrInvalid:\(key)")
        }
        return value
    }

    func uuidOrNil(_ key: String) throws -> UUID? {
        guard let value = object[key], !value.isNull else { return nil }
        guard let raw = value.stringValue, let uuid = UUID(uuidString: raw) else {
            throw NotesAssistantRefusal(.invalidPayload, "invalidUUID:\(key)")
        }
        return uuid
    }

    func string(_ key: String, maxBytes: Int) throws -> String {
        guard let value = object[key]?.stringValue else {
            throw NotesAssistantRefusal(.invalidPayload, "missing:\(key)")
        }
        guard value.utf8.count <= maxBytes else {
            throw NotesAssistantRefusal(.invalidPayload, "tooLong:\(key)")
        }
        return value
    }

    func optionalString(_ key: String, maxBytes: Int) throws -> String? {
        guard let value = object[key], !value.isNull else { return nil }
        guard let raw = value.stringValue else {
            throw NotesAssistantRefusal(.invalidPayload, "invalidString:\(key)")
        }
        guard raw.utf8.count <= maxBytes else {
            throw NotesAssistantRefusal(.invalidPayload, "tooLong:\(key)")
        }
        return raw
    }

    func intOrNil(_ key: String) throws -> Int? {
        guard let value = object[key], !value.isNull else { return nil }
        guard let int = value.intValue else {
            throw NotesAssistantRefusal(.invalidPayload, "invalidInt:\(key)")
        }
        return int
    }

    func stringArray(_ key: String, maxItems: Int) throws -> [String]? {
        guard let value = object[key], !value.isNull else { return nil }
        guard let items = value.arrayValue, items.count <= maxItems else {
            throw NotesAssistantRefusal(.invalidPayload, "invalidArray:\(key)")
        }
        return try items.map { item in
            guard let text = item.stringValue, text.utf8.count <= 64 else {
                throw NotesAssistantRefusal(.invalidPayload, "invalidArrayItem:\(key)")
            }
            return text
        }
    }

    /// Bounded UUID array for editor focus fields. Non-UUID entries are a
    /// typed payload refusal, never silently dropped.
    func uuidArray(_ key: String, maxItems: Int) throws -> [UUID] {
        guard let values = try stringArray(key, maxItems: maxItems) else { return [] }
        return try values.map { raw in
            guard let value = UUID(uuidString: raw) else {
                throw NotesAssistantRefusal(.invalidPayload, "invalidUUID:\(key)")
            }
            return value
        }
    }

    /// The real editor focus carried by the App host. Everything is bounded;
    /// the coordinator validates the identities against the stored document.
    func focus() throws -> NotesRunFocus {
        NotesRunFocus(
            pageID: try uuidOrNil("pageID"),
            pageNumber: try intOrNil("pageNumber"),
            nodeID: try uuidOrNil("nodeID"),
            selectedElementIDs: try uuidArray("selectedElementIDs",
                                              maxItems: NotesRunFocusResolver.maxSelectedElements),
            selectedText: try optionalString("selectedText",
                                             maxBytes: NotesRunFocusResolver.maxSelectedTextBytes),
            attachmentResourceIDs: try uuidArray("attachmentResourceIDs",
                                                 maxItems: NotesRunFocusResolver.maxAttachments))
    }

    func boolOrNil(_ key: String) throws -> Bool? {
        guard let value = object[key], !value.isNull else { return nil }
        guard let flag = value.boolValue else {
            throw NotesAssistantRefusal(.invalidPayload, "invalidBool:\(key)")
        }
        return flag
    }

    func uint64OrNil(_ key: String) throws -> UInt64? {
        guard let value = object[key], !value.isNull else { return nil }
        guard let int = value.intValue, int > 0 else {
            throw NotesAssistantRefusal(.invalidPayload, "invalidUInt:\(key)")
        }
        return UInt64(int)
    }
}

// MARK: - Runtime provider conformance

extension NotesAssistantDomain: NotesRunRuntimeProviding {
    public nonisolated var closedToolNames: Set<String> { NotesAssistantToolNames.closed }

    public nonisolated func makeToolRegistry(epoch: UInt64,
                                             binding: NotesRunBinding,
                                             runID: UUID,
                                             environmentID: String?) -> ToolRunnerRegistry {
        NotesToolRegistry.make(authority: NotesToolAuthority(
            epoch: epoch,
            conversationID: binding.conversationID,
            runID: runID,
            documentID: binding.documentID,
            readableDocumentIDs: binding.readableDocumentIDs,
            editableDocumentIDs: binding.editableDocumentIDs,
            mayCommitRoutineEdits: true,
            environmentID: environmentID))
    }

    public nonisolated func approvalPolicy(epoch: UInt64,
                                           binding: NotesRunBinding,
                                           runID: UUID,
                                           environmentID: String?) -> any ApprovalPolicy {
        NotesAssistantApprovalPolicy(authority: NotesToolAuthority(
            epoch: epoch,
            conversationID: binding.conversationID,
            runID: runID,
            documentID: binding.documentID,
            readableDocumentIDs: binding.readableDocumentIDs,
            editableDocumentIDs: binding.editableDocumentIDs,
            mayCommitRoutineEdits: true,
            environmentID: environmentID))
    }
}
