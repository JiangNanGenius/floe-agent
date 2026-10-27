// SPDX-License-Identifier: MPL-2.0
//
// G05-R2 Office AI (job-1db1a7a8d5da457a) — the ONE production
// `OfficeEditEnginePort` implementation. Core side: turns port calls into
// epoch-fenced host tickets, owns the edit-context store (raw engine target
// handles NEVER leave this file toward a model surface), performs the
// INDEPENDENT byte/hash/magic/package verification of every saved snapshot
// (a host receipt string is never a byte authority), publishes run outputs
// only through the trusted generation-fenced `RuntimeFacadeRunOutput` with
// the real submitting ToolContext, and saves originals ONLY through the
// acquired `G04WorkspaceAccessLease`'s own `WorkspaceFileService
// .replaceBinaryFile` CAS (Main-normal18 contract, never a gate-free service
// or a raw committer) plus the EXISTING provider journal ladder.

import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeWorkspace
import FloeAndroidJobTools

public final class OfficeAIHostBridge: OfficeEditEnginePort, @unchecked Sendable {
    public static let shared = OfficeAIHostBridge(transport: OfficeAIHostMailbox.shared,
                                                  store: OfficeAIEditContextStore())

    private let transport: any OfficeAIHostTransport
    private let store: OfficeAIEditContextStore

    public init(transport: any OfficeAIHostTransport, store: OfficeAIEditContextStore) {
        self.transport = transport
        self.store = store
    }

    // MARK: - Readiness

    public func isHostLaneLive() -> Bool {
        guard let epoch = G02NativeRootEpoch.readback() else { return false }
        return transport.isBound(to: epoch)
    }

    private func liveEpoch() throws -> UInt64 {
        guard let epoch = G02NativeRootEpoch.readback() else {
            throw OfficeEditHostError.hostLaneUnavailable
        }
        guard transport.isBound(to: epoch) else { throw OfficeEditHostError.hostLaneUnavailable }
        return epoch
    }

    // MARK: - Ticket plumbing

    private func submit(_ operation: OfficeAIHostOperation, epoch: UInt64,
                        fields: [String: String?], staged: Data = Data(),
                        cancellation: CancellationToken) async throws -> [String: Any] {
        let descriptor = try OfficeAIHostDescriptor.build(operation: operation, epoch: epoch,
                                                          fields: fields)
        let data: Data
        do {
            data = try await transport.submit(operation: operation, descriptor: descriptor,
                                              staged: staged, cancellation: cancellation)
        } catch let error as OfficeAIHostTransportError {
            throw error.relayed()
        }
        guard let object = OfficeAIHostDescriptor.parse(data),
              (object["ok"] as? Bool) == true || (object["ok"] as? Int) == 1 else {
            // A protocol-success body that is not ok is an honest failure —
            // never a success reinterpretation.
            let parsed = OfficeAIHostDescriptor.parse(data)
            let code = (parsed?[OfficeAIHostReplyKey.code] as? String) ?? "replyMalformed"
            throw OfficeAIHostReply.failureError(code: code.isEmpty ? "replyMalformed" : code,
                                                 detail: parsed?[OfficeAIHostReplyKey.detail] as? String)
        }
        return object
    }

    // MARK: - Document resolution (lookup / owner-safe open)

    struct HostDocumentSnapshot {
        var facts: OfficeEditDocumentFacts
        var editStateName: String?
        var editPermissionEstablished: Bool
        var openedNow: Bool
        var isEditableReady: Bool {
            facts.editable && editPermissionEstablished && editStateName == "READY_EDITABLE"
        }
    }

    private func lookupSnapshot(epoch: UInt64, conversationID: UUID,
                                workspaceID: UUID?,
                                cancellation: CancellationToken) async throws -> HostDocumentSnapshot? {
        let fields: [String: String?] = [
            OfficeAIHostField.taskID: conversationID.uuidString,
            OfficeAIHostField.workspaceID: workspaceID?.uuidString,
            OfficeAIHostField.workspacePresent: workspaceID == nil ? "absent" : "exact",
            OfficeAIHostField.nativeEpoch: String(epoch),
        ]
        do {
            let reply = try await submit(.lookup, epoch: epoch, fields: fields, cancellation: cancellation)
            return try decodeDocument(reply: reply, fallbackTask: conversationID)
        } catch let error as OfficeEditHostError {
            // ONLY an explicit "no owned operation in this realm" answer
            // allows the caller to try the other exact realm. Foreign-owner
            // or fence refusals propagate — they are never a "not open".
            switch error {
            case .noOwnedDocument:
                return nil
            case .rejected(let code, _) where code == "noOwnedDocument":
                return nil
            default:
                throw error
            }
        }
    }

    private func decodeDocument(reply: [String: Any], fallbackTask: UUID) throws
        -> HostDocumentSnapshot {
        let sessionToken = (reply["sessionToken"] as? String) ?? ""
        let generation = (reply["nativeGeneration"] as? NSNumber)?.int64Value ?? 0
        guard !sessionToken.isEmpty, generation >= 1 else {
            throw OfficeEditHostError.failed(code: "sessionMismatch",
                                             detail: "The host answered a document without a live "
                                                 + "engine session token/generation.")
        }
        let formatRaw = (reply["format"] as? String)?.lowercased() ?? ""
        guard let family = OfficeEditDocumentFamily(rawValue: formatRaw) else {
            throw OfficeEditHostError.verificationFailed(
                code: "structureInvalid",
                detail: "The host answered a document outside the OOXML families this lane supports.")
        }
        let ownerTask = UUID(uuidString: (reply["ownerTaskId"] as? String) ?? "") ?? fallbackTask
        let workspaceID = UUID(uuidString: (reply["workspaceId"] as? String) ?? "")
        let routeRaw = (reply["route"] as? String) ?? (workspaceID != nil ? "workspace" : "runOutput")
        let route: OfficeEditDocumentFacts.Route = routeRaw == "workspace" ? .workspace : .runOutput
        let facts = OfficeEditDocumentFacts(
            sessionToken: sessionToken,
            nativeGeneration: generation,
            viewerIncarnation: (reply["viewerIncarnation"] as? NSNumber)?.int64Value ?? 0,
            hostGeneration: reply["hostGeneration"] as? String,
            nativeEpoch: reply["nativeEpoch"] as? String,
            ownerTaskID: ownerTask,
            workspaceID: workspaceID,
            sourceLogicalPath: reply["sourceLogicalPath"] as? String,
            sourceID: reply["sourceId"] as? String,
            sourceRevision: reply["sourceRevision"] as? String,
            family: family,
            editable: (reply["editable"] as? Bool) ?? false,
            originalSnapshotSha256: reply["originalSnapshotSha256"] as? String,
            originalSnapshotBytes: (reply["originalSnapshotBytes"] as? NSNumber)?.int64Value ?? -1,
            workingCopySha256: reply["stagedWorkingCopySha256"] as? String,
            workingCopyBytes: (reply["stagedWorkingCopyBytes"] as? NSNumber)?.int64Value ?? -1,
            displayName: boundedDisplayName(reply["displayName"] as? String, family: family),
            route: route)
        return HostDocumentSnapshot(
            facts: facts,
            editStateName: reply["editStateName"] as? String,
            editPermissionEstablished: (reply["editPermissionEstablished"] as? Bool) ?? false,
            openedNow: (reply["openedNow"] as? Bool) ?? false)
    }

    /// A unique opId for a QUERY-class dispatch (capture / read). Queries are
    /// replay-safe and the engine refuses duplicate opIds, so a retried read
    /// must carry a fresh one; EFFECT stages (apply/flush/export) deliberately
    /// use the SEED-STABLE opIds so a retry can never re-apply an effect.
    private func newQueryOpId(prefix: String) -> String {
        let hex = String(UUID().uuidString.lowercased()
            .replacingOccurrences(of: "-", with: "").prefix(28))
        return prefix + hex
    }

    /// CAPTURE_BASELINE addendum (Main 2026-10-27): derive the context
    /// document's CURRENT working-copy baseline from the ACTUAL valid
    /// captured facts (the engine's own flushed TargetCaptured digest for
    /// this capture) BEFORE the context is stored or returned. The ORIGINAL
    /// staged snapshot (`originalSnapshotSha256`), the opaque revision and
    /// the source identity stay strictly unchanged. Absent, malformed or
    /// unbounded capture facts refuse the context honestly — there is NO
    /// silent fallback to the App initial-stage staged hash, which manual
    /// edits followed by a capture flush can have superseded. Both the
    /// initial capture and the post-effect recapture derive through here, so
    /// the live pre-edit baseline and the durable ownedV2Target summary
    /// always bind the corrected ACTUAL capture document.
    func captureBaselineDocument(snapshot: HostDocumentSnapshot,
                                 capture: OfficeEditCommandResult) throws -> OfficeEditDocumentFacts {
        guard let capturedSha = capture.facts.captureWorkingCopySha256,
              RunOutputFile.isValidSHA256Hex(capturedSha),
              let capturedBytes = capture.facts.captureWorkingCopyBytes,
              capturedBytes > 0,
              capturedBytes <= OfficeEditLimits.maximumCaptureWorkingCopyBytes else {
            throw OfficeEditHostError.unknown(
                code: "captureBaselineUnproven",
                detail: "The engine did not attest the document's CURRENT captured working copy; "
                    + "this context cannot be minted against a possibly stale initial-stage baseline.")
        }
        var facts = snapshot.facts
        facts.workingCopySha256 = capturedSha
        facts.workingCopyBytes = Int64(capturedBytes)
        return facts
    }

    /// The engine target handle shape: exactly 32 lowercase hex characters.
    private func isHex32(_ value: String) -> Bool {
        guard value.count == 32 else { return false }
        return value.lowercased().allSatisfy { character in
            (character >= "0" && character <= "9") || (character >= "a" && character <= "f")
        }
    }

    func boundedDisplayName(_ raw: String?, family: OfficeEditDocumentFamily) -> String {
        let base = (raw?
            .split(separator: "/").last.map(String.init) ?? "")
            .replacingOccurrences(of: "\\", with: "-")
        let cleaned = String(base.map {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" || $0 == " " ||
                $0 >= "\u{0080}" ? $0 : "-"
        }.prefix(96))
        let stem = (cleaned as NSString).deletingPathExtension
        let name = stem.isEmpty ? "office-document" : String(stem.prefix(80))
        return "\(name).\(family.rawValue)"
    }

    // MARK: - openEditContext (capture + context minting)

    public func openEditContext(runID: UUID, conversationID: UUID,
                                workspaceRelativePath: String?,
                                cancellation: CancellationToken) async throws -> OfficeEditContext {
        let epoch = try liveEpoch()
        let snapshot: HostDocumentSnapshot
        if let path = workspaceRelativePath {
            // Reuse ONLY a matching owned document; another open document is
            // an honest busy refusal, never a switch/foreground-steal.
            let clusterWorkspaceID = await clusterWorkspaceID(conversationID)
            if let existing = try await resolveOwnedSnapshot(epoch: epoch, conversationID: conversationID,
                                                             clusterWorkspaceID: clusterWorkspaceID,
                                                             cancellation: cancellation) {
                if existing.facts.sourceLogicalPath == path {
                    snapshot = existing
                } else {
                    throw OfficeEditHostError.failed(
                        code: "documentBusy",
                        detail: "A different Office document is already open for this task. Close it "
                            + "first; this tool never retargets or replaces the open viewer.")
                }
            } else {
                guard let workspaceID = clusterWorkspaceID else {
                    throw OfficeEditHostError.noOwnedDocument(
                        detail: "This task has no workspace to open the requested document from")
                }
                let reply = try await submit(.open, epoch: epoch, fields: [
                    OfficeAIHostField.taskID: conversationID.uuidString,
                    OfficeAIHostField.workspaceID: workspaceID.uuidString,
                    OfficeAIHostField.nativeEpoch: String(epoch),
                    OfficeAIHostField.logicalPath: path,
                    OfficeAIHostField.requestID: UUID().uuidString,
                ], cancellation: cancellation)
                snapshot = try decodeDocument(reply: reply, fallbackTask: conversationID)
                guard snapshot.facts.ownerTaskID == conversationID,
                      snapshot.facts.sourceLogicalPath == path else {
                    throw OfficeEditHostError.rejected(
                        code: "notOwner",
                        detail: "The opened document identity does not match this task's request; the "
                            + "host refused to associate them.")
                    }
            }
        } else {
            guard let existing = try await resolveOwnedSnapshot(epoch: epoch, conversationID: conversationID,
                                                                clusterWorkspaceID: await clusterWorkspaceID(conversationID),
                                                                cancellation: cancellation) else {
                throw OfficeEditHostError.noOwnedDocument(
                    detail: "no App-owned open document for this conversation; pass workspacePath to "
                        + "open a task-workspace document through the normal in-app viewer")
            }
            snapshot = existing
        }
        // The capture is the P-A CAPTURE_TARGET: it mints the engine handle
        // the follow-up apply MUST revalidate. Reads stay allowed on a
        // read-only mount; content effects check editability separately.
        let contextID = "ctx" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let captureReply = try await submitCommand(
            epoch: epoch, snapshot: snapshot, action: "captureTarget", opId: "cap" + String(contextID.dropFirst(3)),
            targetHandle: nil, staged: Data(), taskID: conversationID, cancellation: cancellation)
        let capture = decodeCommand(captureReply, identity: contextID)
        guard capture.state == .queryObserved, let handle = capture.targetHandle,
              isHex32(handle) else {
            if capture.state == .rejected || capture.state == .failed {
                throw OfficeEditHostError.failed(
                    code: capture.failureCode ?? "captureFailed",
                    detail: capture.detail ?? "The engine could not mint a captured target for the open document")
            }
            throw OfficeEditHostError.unknown(
                code: capture.failureCode ?? "captureUnknown",
                detail: capture.detail ?? "The capture outcome is unknown; no apply may proceed against "
                    + "an unproven target. Nothing was dispatched.")
        }
        // CAPTURE_BASELINE addendum: the stored/returned context document's
        // CURRENT baseline is the ACTUAL captured flushed working copy (B),
        // never the App initial-stage staged hash (A stays the original CAS
        // fact). Unproven capture baseline refuses the context honestly.
        let contextDocument = try captureBaselineDocument(snapshot: snapshot, capture: capture)
        let record = OfficeAIEditContextRecord(
            contextID: contextID, conversationID: conversationID, createdRunID: runID,
            targetHandle: handle, document: contextDocument,
            capturedContext: capture.facts,
            capturedAtElapsedMillis: Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000))
        guard store.insert(record) else {
            throw OfficeEditHostError.transport(code: "contextSaturated")
        }
        return OfficeEditContext(contextID: contextID, document: contextDocument,
                                 captureAttested: true, capturedContext: capture.facts,
                                 capturedAtElapsedMillis: record.capturedAtElapsedMillis)
    }

    /// Exact-realm lookup: the conversation's real workspace ID first, then
    /// the honest `null` realm (provider/run-output routes). Never a
    /// first-open-document fallback: both attempts carry the exact task owner.
    private func resolveOwnedSnapshot(epoch: UInt64, conversationID: UUID,
                                      clusterWorkspaceID: UUID?,
                                      cancellation: CancellationToken) async throws
        -> HostDocumentSnapshot? {
        if let workspaceID = clusterWorkspaceID,
           let exact = try await lookupSnapshot(epoch: epoch, conversationID: conversationID,
                                                workspaceID: workspaceID, cancellation: cancellation) {
            return exact
        }
        return try await lookupSnapshot(epoch: epoch, conversationID: conversationID,
                                        workspaceID: nil, cancellation: cancellation)
    }

    private func clusterWorkspaceID(_ taskID: UUID) async -> UUID? {
        guard let installed = G02RuntimeComposition.shared.installedComposition,
              installed.epoch == G02NativeRootEpoch.readback() else { return nil }
        return try? await installed.cluster.workspaceStore.workspaceID(conversationID: taskID)
    }

    // MARK: - command submit/decode

    private func submitCommand(epoch: UInt64, snapshot: HostDocumentSnapshot, action: String,
                               opId: String, targetHandle: String?, staged: Data,
                               taskID: UUID?, partId: String? = nil,
                               cancellation: CancellationToken) async throws
        -> [String: Any] {
        let fields: [String: String?] = [
            OfficeAIHostField.sessionToken: snapshot.facts.sessionToken,
            OfficeAIHostField.generation: String(snapshot.facts.nativeGeneration),
            OfficeAIHostField.opId: opId,
            OfficeAIHostField.action: action,
            OfficeAIHostField.targetHandle: targetHandle,
            OfficeAIHostField.partId: partId,
            OfficeAIHostField.taskID: taskID?.uuidString,
        ]
        return try await submit(.command, epoch: epoch, fields: fields, staged: staged,
                                cancellation: cancellation)
    }

    func decodeCommand(_ reply: [String: Any], identity: String) -> OfficeEditCommandResult {
        let stateRaw = (reply["state"] as? String) ?? "unknown"
        let state: OfficeEditResultState
        switch stateRaw {
        case "queryObserved": state = .queryObserved
        case "nativeCompleted": state = .nativeCompleted
        case "mutationVerified": state = .mutationVerified
        case "rejected": state = .rejected
        case "failed": state = .failed
        default: state = .unknown
        }
        var facts = OfficeEditQueryFacts()
        if let object = reply["facts"] as? [String: Any] {
            facts.docType = object["docType"] as? String
            facts.partsCount = (object["partsCount"] as? NSNumber)?.intValue
            facts.selectedPart = object["selectedPart"] as? String
            facts.viewID = (object["viewID"] as? NSNumber)?.intValue
            facts.readOnly = object["readOnly"] as? Bool
            facts.documentModified = object["documentModified"] as? Bool
            facts.selectionByteCount = (object["selectionByteCount"] as? NSNumber)?.intValue
            if let text = object["selectionText"] as? String {
                let bound = OfficeEditLimits.maximumReturnedSelectionBytes
                if text.utf8.count > bound {
                    facts.selectionText = nil
                    facts.selectionTruncated = true
                } else {
                    facts.selectionText = text
                }
            }
            facts.cellColumn = (object["cursorColumn"] as? NSNumber)?.intValue
            facts.cellRow = (object["cursorRow"] as? NSNumber)?.intValue
            facts.cellEmpty = object["cursorEmpty"] as? Bool
            facts.slideCount = (object["slideCount"] as? NSNumber)?.intValue
            facts.shownPart = object["shownPart"] as? String
            facts.selectedTextBytes = (object["selectedTextBytes"] as? NSNumber)?.intValue
            facts.partIndex = (object["partIndex"] as? NSNumber)?.intValue
            // CAPTURE_BASELINE addendum (Main 2026-10-27): the ACTUAL native
            // captured flushed working copy rides the command facts; never
            // the App initial-stage staged hash.
            facts.captureWorkingCopySha256 = object["captureWorkingCopySha256"] as? String
            facts.captureWorkingCopyBytes = (object["captureWorkingCopyBytes"] as? NSNumber)?.intValue
        }
        return OfficeEditCommandResult(
            state: state,
            failureCode: reply["failure"] as? String,
            detail: (reply["detail"] as? String).map { String($0.prefix(240)) },
            attestation: (reply["attestation"] as? String) ?? "",
            targetHandle: reply["targetHandle"] as? String,
            facts: facts,
            contentReadback: reply["contentReadback"] as? String,
            operationIdentity: identity)
    }

    // MARK: - read

    public func read(_ command: OfficeEditReadCommand, contextID: String, conversationID: UUID,
                     seed: String, cancellation: CancellationToken) async throws
        -> OfficeEditCommandResult {
        let epoch = try liveEpoch()
        let record = try requiringLiveRecord(contextID: contextID, conversationID: conversationID)
        try await reaffirmSession(epoch: epoch, record: record, cancellation: cancellation)
        let reply = try await submitCommand(
            epoch: epoch, snapshot: HostDocumentSnapshot(facts: record.document, editStateName: nil,
                                                         editPermissionEstablished: false, openedNow: false),
            action: command.actionToken,
            opId: newQueryOpId(prefix: "rd"),
            targetHandle: nil, staged: Data(), taskID: conversationID, cancellation: cancellation)
        return decodeCommand(reply, identity: seed)
    }

    // MARK: - preparatory effects

    public func executePreparatory(_ command: OfficeEditPreparatoryCommand, contextID: String,
                                   conversationID: UUID, seed: String,
                                   cancellation: CancellationToken) async throws
        -> OfficeEditPreparatoryOutcome {
        let epoch = try liveEpoch()
        let record = try requiringLiveRecord(contextID: contextID, conversationID: conversationID)
        try await reaffirmSession(epoch: epoch, record: record, cancellation: cancellation)
        guard record.document.editable else {
            throw OfficeEditHostError.notEditable(detail: "The open document is not on an edit route")
        }
        let (actionToken, partID): (String, String?)
        switch command {
        case .selectSlide(let part):
            guard record.document.family != .docx else {
                throw OfficeEditHostError.unsupported(detail: "selectSlide applies to XLSX/PPTX only")
            }
            actionToken = "selectSlide"; partID = String(part)
        case .selectAllText:
            actionToken = "selectAllText"; partID = nil
        }
        let reply = try await submitCommand(
            epoch: epoch,
            snapshot: HostDocumentSnapshot(facts: record.document, editStateName: nil,
                                           editPermissionEstablished: false, openedNow: false),
            action: actionToken,
            opId: OfficeEditOperationIdentity.stageOpId(seed: seed, stage: "prep-" + actionToken),
            targetHandle: nil, staged: Data(), taskID: conversationID, partId: partID,
            cancellation: cancellation)
        let result = decodeCommand(reply, identity: seed)

        // A dispatch that may have moved the target consumes the old context
        // honestly; only a REFUSED-before-dispatch keeps it alive.
        if result.state == .nativeCompleted || result.state == .mutationVerified
            || result.state == .failed || result.state == .unknown {
            store.supersede(oldContextID: contextID, conversationID: conversationID)
        }
        guard result.isEffectProven else {
            return OfficeEditPreparatoryOutcome(result: result, refreshedContext: nil)
        }
        // Honest recapture: the follow-up apply MUST use this fresh attested
        // context; we never hand back the superseded one.
        let snapshot = HostDocumentSnapshot(facts: record.document, editStateName: nil,
                                            editPermissionEstablished: false, openedNow: false)
        let opened = try await captureContext(epoch: epoch, snapshot: snapshot, seed: seed,
                                              runID: record.createdRunID,
                                              conversationID: conversationID,
                                              cancellation: cancellation)
        return OfficeEditPreparatoryOutcome(result: result, refreshedContext: opened)
    }

    /// Mint a NEW engine capture + context record (used after a proven
    /// preparatory effect). Fails closed when the capture is unattested.
    private func captureContext(epoch: UInt64, snapshot: HostDocumentSnapshot, seed: String,
                                runID: UUID, conversationID: UUID,
                                cancellation: CancellationToken) async throws -> OfficeEditContext {
        // Re-look the document facts first: the recapture must bind the
        // CURRENT flushed working copy, not the superseded echo.
        let fresh: HostDocumentSnapshot
        if let relooked = try await lookupSnapshot(epoch: epoch, conversationID: conversationID,
                                                   workspaceID: snapshot.facts.workspaceID,
                                                   cancellation: cancellation),
            relooked.facts.sessionToken == snapshot.facts.sessionToken,
            relooked.facts.nativeGeneration == snapshot.facts.nativeGeneration {
            fresh = relooked
        } else {
            fresh = snapshot
        }
        let contextID = "ctx" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let captureReply = try await submitCommand(
            epoch: epoch, snapshot: fresh, action: "captureTarget",
            opId: newQueryOpId(prefix: "cap"),
            targetHandle: nil, staged: Data(), taskID: conversationID, cancellation: cancellation)
        let capture = decodeCommand(captureReply, identity: contextID)
        guard capture.state == .queryObserved, let handle = capture.targetHandle,
              isHex32(handle) else {
            throw OfficeEditHostError.unknown(
                code: capture.failureCode ?? "recaptureUnattested",
                detail: "The effect landed but the follow-up capture is unattested; the tool stops "
                    + "here so no apply can target an unproven context.")
        }
        // CAPTURE_BASELINE addendum: the recaptured context binds the ACTUAL
        // captured flushed working copy too — the re-look may still echo an
        // App-stage staged hash; only the engine's own capture facts prove
        // the CURRENT bytes.
        let contextDocument = try captureBaselineDocument(snapshot: fresh, capture: capture)
        let record = OfficeAIEditContextRecord(
            contextID: contextID, conversationID: conversationID, createdRunID: runID,
            targetHandle: handle, document: contextDocument, capturedContext: capture.facts,
            capturedAtElapsedMillis: Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000))
        guard store.insert(record) else {
            throw OfficeEditHostError.transport(code: "contextSaturated")
        }
        return OfficeEditContext(contextID: contextID, document: contextDocument,
                                 captureAttested: true, capturedContext: capture.facts,
                                 capturedAtElapsedMillis: record.capturedAtElapsedMillis)
    }

    // MARK: - content effects (full verified chain)

    public func executeContent(_ command: OfficeEditContentCommand, contextID: String,
                               conversationID: UUID, seed: String,
                               cancellation: CancellationToken) async throws
        -> OfficeEditContentOutcome {
        let epoch = try liveEpoch()
        let record = try requiringLiveRecord(contextID: contextID, conversationID: conversationID)
        try await reaffirmSession(epoch: epoch, record: record, cancellation: cancellation)
        let document = record.document
        let snapshot = HostDocumentSnapshot(facts: document, editStateName: nil,
                                            editPermissionEstablished: false, openedNow: false)
        switch command {
        case .setCellContent:
            guard document.family == .xlsx else {
                throw OfficeEditHostError.unsupported(detail: "setCellContent applies to XLSX workbooks only")
            }
        case .applyText:
            break
        }
        guard document.editable else {
            throw OfficeEditHostError.notEditable(detail: "The open document is not on an edit route")
        }
        // Consume EXACTLY ONCE before dispatch. Even if the dispatch outcome
        // later turns UNKNOWN, this context can never fuel a second effect.
        guard store.consume(contextID: contextID, conversationID: conversationID) else {
            throw OfficeEditHostError.rejected(code: "editContextConsumed",
                                               detail: "This captured context has already driven an "
                                                   + "effect. Read again to capture the current target.")
        }
        let (action, staged, cell, contentKind): (String, Data, String?, String?)
        switch command {
        case .applyText(let text):
            action = "applyText"; staged = Data(text.utf8); cell = nil; contentKind = nil
        case .setCellContent(let address, let text, let kind):
            action = "setCellContent"; staged = Data(text.utf8)
            cell = OfficeEditLimits.canonicalCellAddress(address)
            contentKind = kind.rawValue
        }
        let applyResult = decodeCommand(
            try await submit(.command, epoch: epoch, fields: [
                OfficeAIHostField.sessionToken: document.sessionToken,
                OfficeAIHostField.generation: String(document.nativeGeneration),
                OfficeAIHostField.opId: OfficeEditOperationIdentity.stageOpId(seed: seed, stage: "apply"),
                OfficeAIHostField.action: action,
                OfficeAIHostField.targetHandle: record.targetHandle,
                OfficeAIHostField.cellAddress: cell,
                OfficeAIHostField.contentKind: contentKind,
                OfficeAIHostField.taskID: conversationID.uuidString,
            ], staged: staged, cancellation: cancellation),
            identity: seed)
        if !applyResult.isEffectProven {
            // No publication; the caller maps failed/rejected vs unknown
            // (unknown = retained, unsafe).
            let receipt = OfficeEditFlushReceipt(
                state: applyResult.state == .unknown ? .unknown : .rejected,
                failureCode: applyResult.failureCode,
                attestation: applyResult.attestation,
                sessionToken: document.sessionToken, nativeGeneration: document.nativeGeneration)
            return OfficeEditContentOutcome(result: applyResult, flush: receipt,
                                            contextConsumed: true, document: document)
        }

        // Stage: flush the owned working copy (real bytes on disk).
        let flushReply = try await submit(.save, epoch: epoch, fields: [
            OfficeAIHostField.sessionToken: document.sessionToken,
            OfficeAIHostField.generation: String(document.nativeGeneration),
            OfficeAIHostField.opId: OfficeEditOperationIdentity.stageOpId(seed: seed, stage: "flush"),
            OfficeAIHostField.saveOperation: "flush",
        ], cancellation: cancellation)
        let flush = decodeFlush(flushReply, document: document)
        guard flush.state == .flushed else {
            return OfficeEditContentOutcome(result: applyResult, flush: flush,
                                            contextConsumed: true, document: document)
        }

        // Stage: authoritative saved snapshot through the native staged export.
        let exportReply = try await submit(.save, epoch: epoch, fields: [
            OfficeAIHostField.sessionToken: document.sessionToken,
            OfficeAIHostField.generation: String(document.nativeGeneration),
            OfficeAIHostField.opId: OfficeEditOperationIdentity.stageOpId(seed: seed, stage: "export"),
            OfficeAIHostField.saveOperation: "export",
            OfficeAIHostField.format: document.family.rawValue,
            OfficeAIHostField.suggestedName: suggestedName(for: document),
        ], cancellation: cancellation)
        let export = decodeExport(exportReply, document: document)
        guard export.isOutputReady, let path = export.outputPath,
              let sha = export.outputSha256, export.outputBytes ?? 0 > 0 else {
            return OfficeEditContentOutcome(result: applyResult, flush: flush,
                                            snapshot: nil, semantic: nil,
                                            contextConsumed: true, document: document)
        }
        // INDEPENDENT verification of the actual bytes (never trust the
        // receipt strings alone), then the owned semantic inspection.
        let verified = try adoptAndVerify(path: path, expectedSha256: sha,
                                         expectedBytes: export.outputBytes!,
                                         family: document.family,
                                         displayName: document.displayName,
                                         attestation: export.attestation,
                                         sessionToken: document.sessionToken,
                                         nativeGeneration: document.nativeGeneration)
        // Amendment/2: the live expectations bind THIS context's captured
        // logical part index, the CURRENT flushed working copy as the
        // pre-edit delta baseline, and the owned live-effect identity
        // (deterministic original stage opIds + the Core-owned captured
        // handle) — never a sheet1 default, never the open-time source hash,
        // never anything model-supplied.
        let expectations = expectations(for: command, record: record, seed: seed)
        let semantic = try await inspectSavedPackage(verified, expectations: expectations,
                                                     cancellation: cancellation)
        return OfficeEditContentOutcome(result: applyResult, flush: flush, snapshot: verified,
                                         semantic: semantic, contextConsumed: true,
                                         document: document)
    }

    private func expectations(for command: OfficeEditContentCommand,
                              record: OfficeAIEditContextRecord, seed: String) -> OfficeEditExpectations {
        let document = record.document
        // The pre-edit baseline is the capture's FLUSHED working copy (the
        // last bytes the engine wrote before this effect); the original
        // source snapshot stays a separate CAS/identity fact of the document.
        let preEditBaselineSha256 = document.workingCopySha256
        let effectOpId = OfficeEditOperationIdentity.stageOpId(seed: seed, stage: "apply")
        let exportOpId = OfficeEditOperationIdentity.stageOpId(seed: seed, stage: "export")
        switch command {
        case .applyText(let text):
            return OfficeEditExpectations(command: .applyText, family: document.family,
                                          text: text,
                                          partIndex: record.capturedContext.partIndex,
                                          preEditSnapshotSha256: preEditBaselineSha256,
                                          verificationMode: .liveEffect,
                                          effectOpId: effectOpId, exportOpId: exportOpId,
                                          targetHandle: record.targetHandle,
                                          ownerTaskID: record.conversationID)
        case .setCellContent(let cell, let text, let kind):
            return OfficeEditExpectations(command: .setCellContent, family: document.family,
                                          text: text,
                                          cell: OfficeEditLimits.canonicalCellAddress(cell),
                                          contentKind: kind,
                                          partIndex: record.capturedContext.partIndex,
                                          preEditSnapshotSha256: preEditBaselineSha256,
                                          verificationMode: .liveEffect,
                                          effectOpId: effectOpId, exportOpId: exportOpId,
                                          targetHandle: record.targetHandle,
                                          ownerTaskID: record.conversationID)
        }
    }

    private func suggestedName(for document: OfficeEditDocumentFacts) -> String {
        String(document.displayName.prefix(120))
    }

    func decodeFlush(_ reply: [String: Any], document: OfficeEditDocumentFacts)
        -> OfficeEditFlushReceipt {
        let stateRaw = (reply["state"] as? String) ?? "unknown"
        let state: OfficeEditFlushReceipt.State
        switch stateRaw {
        case "flushed": state = .flushed
        case "unmodified": state = .unmodified
        case "failed": state = .failed
        case "rejected": state = .rejected
        case "cancelled": state = .cancelled
        default: state = .unknown
        }
        return OfficeEditFlushReceipt(
            state: state, failureCode: reply["failure"] as? String,
            workingCopySha256: reply["workingCopySHA256"] as? String,
            workingCopyBytes: (reply["workingCopyBytes"] as? NSNumber)?.int64Value ?? 0,
            attestation: (reply["attestation"] as? String) ?? "",
            sessionToken: document.sessionToken, nativeGeneration: document.nativeGeneration)
    }

    struct DecodedExport {
        var isOutputReady: Bool
        var outputPath: String?
        var outputSha256: String?
        var outputBytes: Int64?
        var attestation: String
        var failureCode: String?
    }

    func decodeExport(_ reply: [String: Any], document: OfficeEditDocumentFacts) -> DecodedExport {
        let stateRaw = (reply["state"] as? String) ?? "unknown"
        return DecodedExport(
            isOutputReady: stateRaw == "outputReady",
            outputPath: reply["outputPath"] as? String,
            outputSha256: reply["outputSHA256"] as? String,
            outputBytes: (reply["outputBytes"] as? NSNumber)?.int64Value,
            attestation: (reply["attestation"] as? String) ?? "jni-saveas-sync+output-verified",
            failureCode: reply["failure"] as? String)
    }

    // MARK: - independent file verification

    private func adoptAndVerify(path: String, expectedSha256: String?, expectedBytes: Int64?,
                                family: OfficeEditDocumentFamily, displayName: String,
                                attestation: String, sessionToken: String, nativeGeneration: Int64)
        throws -> OfficeEditSavedSnapshot {
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else {
            throw OfficeEditHostError.verificationFailed(
                code: "structureInvalid",
                detail: "The saved snapshot is not a plain regular file; no output was published.")
        }
        let size = Int64(values?.fileSize ?? 0)
        if let expectedBytes, size != expectedBytes {
            throw OfficeEditHostError.verificationFailed(
                code: "sizeMismatch",
                detail: "The saved snapshot's measured size does not match the verified receipt.")
        }
        let measured: String
        do {
            measured = try FloeDigest.sha256Hex(ofFileAt: url)
        } catch {
            throw OfficeEditHostError.verificationFailed(
                code: "packageUnreadable",
                detail: "The saved snapshot could not be fully read for verification.")
        }
        if let expectedSha256, measured.lowercased() != expectedSha256.lowercased() {
            throw OfficeEditHostError.verificationFailed(
                code: "digestMismatch",
                detail: "The saved snapshot bytes do not match the digest the engine verified.")
        }
        do {
            _ = try OfficeAIPackageStructure.verifyPackage(url: url, family: family.rawValue)
        } catch let failure as OfficeAIPackageStructure.Failure {
            throw OfficeEditHostError.verificationFailed(
                code: "structureInvalid",
                detail: "The saved file is not a structurally valid \(family.rawValue) package (\(failure)).")
        }
        return OfficeEditSavedSnapshot(kind: .stagedExport, path: path, sha256: measured,
                                       byteCount: size, format: family, displayName: displayName,
                                       attestation: attestation, sessionToken: sessionToken,
                                       nativeGeneration: nativeGeneration)
    }

    public func adoptVerifiedFile(path: String, expectedSha256: String, expectedBytes: Int64?,
                                  format: OfficeEditDocumentFamily, displayName: String) throws
        -> OfficeEditSavedSnapshot {
        // Public collect entry: same independent verification; the display
        // name must survive the run-output name rules or publication would
        // fail later.
        guard RunOutputFile.isValidDisplayName(displayName) else {
            throw OfficeEditHostError.verificationFailed(
                code: "displayNameInvalid",
                detail: "The collected artifact name is not a valid user-file display name.")
        }
        return try adoptAndVerify(path: path, expectedSha256: expectedSha256,
                                  expectedBytes: expectedBytes, family: format,
                                  displayName: displayName,
                                  attestation: "adopted-reverified",
                                  sessionToken: "", nativeGeneration: 0)
    }

    // MARK: - semantic inspection

    public func inspectSavedPackage(_ snapshot: OfficeEditSavedSnapshot,
                                    expectations: OfficeEditExpectations,
                                    cancellation: CancellationToken) async throws
        -> OfficeEditSemanticFacts {
        let epoch = try liveEpoch()
        // Amendment/2: the raw expected text is staged for EVERY content kind
        // (literal, number AND formula) — the v1 prose that claimed an empty
        // stage for formula described a bug, not the wire.
        let staged = expectations.text.map { Data($0.utf8) } ?? Data()
        // The live-effect identity is bound from the captured context; for a
        // completedJob/reconcile proof the session/generation/handle are
        // honestly absent (the engine session may be gone) and the proof
        // rides on the recomputed original stage opIds + artifact digest.
        let live = expectations.verificationMode == .liveEffect
        let reply: [String: Any]
        do {
            reply = try await submit(.verify, epoch: epoch, fields: [
                OfficeAIHostField.path: snapshot.path,
                OfficeAIHostField.sha256: snapshot.sha256,
                OfficeAIHostField.format: snapshot.format.rawValue,
                OfficeAIHostField.expectCommand: expectations.command.rawValue,
                OfficeAIHostField.cellAddress: expectations.cell,
                OfficeAIHostField.contentKind: expectations.contentKind?.rawValue,
                OfficeAIHostField.expectPartIndex: expectations.partIndex.map { String($0) },
                OfficeAIHostField.preEditSha256: expectations.preEditSnapshotSha256,
                OfficeAIHostField.taskID: expectations.ownerTaskID?.uuidString,
                OfficeAIHostField.verificationMode: expectations.verificationMode?.rawValue,
                OfficeAIHostField.effectOpId: expectations.effectOpId,
                OfficeAIHostField.exportOpId: expectations.exportOpId,
                OfficeAIHostField.sessionToken: live ? snapshot.sessionToken : nil,
                OfficeAIHostField.generation: live ? String(snapshot.nativeGeneration) : nil,
                OfficeAIHostField.targetHandle: expectations.targetHandle,
            ], staged: staged, cancellation: cancellation)
        } catch let error as OfficeEditHostError {
            throw OfficeEditHostError.verificationFailed(
                code: "semanticNotInspected",
                detail: "The host could not inspect the saved package (\(error.code)); "
                    + "verification is unproven.")
        }
        return decodeSemantic(reply)
    }

    func decodeSemantic(_ reply: [String: Any]) -> OfficeEditSemanticFacts {
        var facts = OfficeEditSemanticFacts(inspectedSavedPackage: (reply["inspected"] as? Bool) == true)
        facts.partName = reply["partName"] as? String
        facts.expectedTextFound = reply["expectedTextFound"] as? Bool
        facts.occurrenceCount = (reply["occurrenceCount"] as? NSNumber)?.intValue
        facts.replacementScope = reply["replacementScope"] as? String
        facts.cellTypeAttribute = reply["cellTypeAttribute"] as? String
        facts.cellHasFormula = reply["cellHasFormula"] as? Bool
        facts.cellPersistedValue = (reply["cellPersistedValue"] as? String)
            .map { String($0.prefix(OfficeEditLimits.maximumPersistedValueChars)) }
        facts.cellTypeMatchesIntent = reply["cellTypeMatchesIntent"] as? Bool
        facts.changedFromOriginal = reply["changedFromOriginal"] as? Bool
        // Amendment/2 owned proof facts (absent ⇒ nil ⇒ the gate refuses).
        facts.expectedContentMatches = reply["expectedContentMatches"] as? Bool
        facts.targetEffectVerified = reply["targetEffectVerified"] as? Bool
        facts.semanticDeltaVerified = reply["semanticDeltaVerified"] as? Bool
        facts.proofReused = reply["proofReused"] as? Bool
        if let version = (reply["proofVersion"] as? NSNumber)?.intValue, version >= 1 {
            facts.proofVersion = version
        }
        facts.limitations = ((reply["limitations"] as? [String]) ?? [])
            .prefix(OfficeEditLimits.maximumLimitations).map { String($0.prefix(160)) }
        return facts
    }

    // MARK: - publication

    public func publishVerifiedOutput(_ snapshot: OfficeEditSavedSnapshot,
                                      semantic: OfficeEditSemanticFacts,
                                      slot: String,
                                      context: ToolContext) throws -> RunOutputFile {
        _ = try liveEpoch()
        guard !semantic.isUnproven else {
            throw OfficeEditHostError.verificationFailed(
                code: "semanticNotInspected",
                detail: "Publication requires owned semantic facts over the saved package.")
        }
        guard RunOutputFile.isValidDisplayName(snapshot.displayName) else {
            throw OfficeEditHostError.verificationFailed(
                code: "displayNameInvalid", detail: "Unsavable display name.")
        }
        let request = RunOutputSnapshotRequest(
            producerTool: OfficeDocumentEditTool.producerToolName,
            slot: slot,
            commit: RunOutputCommit(
                sourceURL: URL(fileURLWithPath: snapshot.path),
                sha256: snapshot.sha256,
                byteCount: Int(clamping: snapshot.byteCount),
                displayName: snapshot.displayName,
                mimeType: snapshot.format.mimeType,
                uti: nil))
        // Trusted generation-fenced publication with the REAL submitting
        // ToolContext; RuntimeFacadeRunOutput atomically captures the bound
        // artifact root + lease and rechecks the boundary; the runtime's
        // strict seal then binds the receipt to this exact call. Nothing here
        // picks a root, a call id or a producer name from model data.
        return try RuntimeFacadeRunOutput.shared.publish(request, using: context)
    }

    // MARK: - original save (Normal18 CAS + existing journal)

    public func saveOriginal(_ snapshot: OfficeEditSavedSnapshot,
                             document: OfficeEditDocumentFacts,
                             cancellation: CancellationToken) async throws
        -> OfficeEditOriginalSaveOutcome {
        let epoch = try liveEpoch()
        guard document.supportsOriginalSave,
              let workspaceID = document.workspaceID,
              let logicalPath = document.sourceLogicalPath, !logicalPath.isEmpty else {
            return OfficeEditOriginalSaveOutcome(
                local: .unsupported, provider: .refused,
                detail: "This document is not an ordinary workspace original (a run-output copy stays "
                    + "immutable, and a provider-picked document carries no task ownership). The "
                    + "published saved copy remains available for Save Copy.")
        }
        guard let expectedOriginal = document.originalSnapshotSha256,
              RunOutputFile.isValidSHA256Hex(expectedOriginal.lowercased()),
              RunOutputFile.isValidSHA256Hex(snapshot.sha256.lowercased()),
              snapshot.byteCount >= 1, snapshot.byteCount <= Int64(Int32.max) else {
            return OfficeEditOriginalSaveOutcome(
                local: .refused, provider: .refused,
                localToken: "originalIdentityMissing",
                detail: "The open-time snapshot digest is unavailable; the CAS replace cannot be "
                    + "expressed safely, so nothing was overwritten.")
        }
        guard let installed = G02RuntimeComposition.shared.installedComposition,
              installed.epoch == epoch else {
            return OfficeEditOriginalSaveOutcome(local: .refused, provider: .refused,
                                                 localToken: "generationRetired",
                                                 detail: "The runtime generation is not live.")
        }
        let access = G04WorkspaceComposition.liveAccess(epoch: epoch, installed: installed)
        let owner = G04WorkspaceOwner(epoch: epoch, taskID: document.ownerTaskID,
                                      workspaceID: workspaceID)
        let lease: G04WorkspaceAccessLease
        do {
            lease = try await access.acquire(owner: owner, intent: .write, relativePath: logicalPath)
        } catch {
            return OfficeEditOriginalSaveOutcome(
                local: .refused, provider: .refused, localToken: "leaseRefused",
                detail: "The workspace write lease (ownership admission + operation lease) refused "
                    + "this document; nothing was overwritten.")
        }
        defer { Task { await lease.release() } }
        // The acquired lease's OWN service (real mutation lock, path guard,
        // freeze gate, streaming digest CAS) — normal18 contract, called
        // exactly as Main's interface review accepts.
        var commitError: Error?
        var outcome: WriteOutcome?
        do {
            outcome = try lease.service.replaceBinaryFile(
                logicalPath,
                from: URL(fileURLWithPath: snapshot.path),
                expectedOriginalSHA256: expectedOriginal,
                expectedSourceSHA256: snapshot.sha256,
                expectedSourceBytes: Int(clamping: snapshot.byteCount),
                cancellation: cancellation)
        } catch is CancellationError {
            commitError = FloeError.cancelled
        } catch let error as FloeError where error == .cancelled {
            commitError = error
        } catch {
            commitError = error
        }
        var localState: OfficeEditOriginalSaveOutcome.LocalState = .unknown
        var localToken = "commitOutcomeUnknown"
        var committedSHA: String?
        var committedBytes: Int64 = 0
        var localDetail = "The replace outcome could not be proven; the recoverable copies and the "
            + "verified export remain. The native edit was NOT retried."
        if let outcome {
            localState = .committed
            localToken = "replaceBinaryFileCommitted"
            committedSHA = outcome.sha256
            committedBytes = Int64(outcome.bytesWritten)
            localDetail = "The workspace original now carries the verified edit."
        } else if let commitError {
            // Main's accepted-18 boundary: this CAS is a COOPERATING-WRITER
            // lock + digest policy, not an OS-level compare-and-swap. An
            // IO/receipt error AFTER the atomic adoption may therefore have
            // already written. The original state is classified by INSPECTING
            // the actual readback under the SAME owned lease — never by
            // assuming "throw means untouched", and never auto-retried.
            let readback = Self.classifyOriginalReadback(service: lease.service,
                                                          logicalPath: logicalPath,
                                                          expectedOriginal: expectedOriginal,
                                                          expectedSaved: snapshot.sha256,
                                                          expectedBytes: snapshot.byteCount)
            switch readback {
            case .saved:
                localState = .committed
                localToken = "writtenPerActualReadback"
                committedSHA = snapshot.sha256.lowercased()
                committedBytes = snapshot.byteCount
                localDetail = "The replace reported an error ("
                    + String(describing: type(of: commitError))
                    + ") but the workspace file's ACTUAL bytes are the verified replacement: "
                    + "originalSaved per readback under the owned lease."
            case .untouched:
                // Genuinely pre-write refusal/conflict (or the original is
                // byte-identical after the failed attempt): honest conflict/
                // refusal from the error's own shape, never a silent success.
                if commitError is FloeError {
                    localState = .refused
                    localToken = "cancelledBeforeCommit"
                    localDetail = "Cancellation was honored with the original intact per readback; "
                        + "nothing was overwritten."
                } else {
                    localState = .conflict
                    localToken = "originalIntactPerReadback"
                    localDetail = "The workspace original is byte-intact per actual readback; the "
                        + "replace did not land. Nothing was overwritten and the native edit was "
                        + "NOT retried."
                }
            case .drifted:
                localState = .unknown
                localToken = "originalDriftedPerReadback"
                localDetail = "Neither the original nor the verified replacement matches the "
                    + "workspace file's actual bytes after the attempt (a cooperating writer may "
                    + "have changed it). Retained honestly as UNKNOWN; nothing was retried."
            case .unreadable:
                localState = .unknown
                localToken = "readbackUnprovable"
                localDetail = "The original could not be re-inspected after the failed commit; the "
                    + "outcome is UNKNOWN and every copy is retained."
            }
        }
        var result = OfficeEditOriginalSaveOutcome(
            local: localState, provider: .refused,
            committedSHA256: committedSHA, committedBytes: committedBytes,
            localToken: localToken, detail: localDetail)
        guard localState == .committed else {
            // The verified export remains recoverable regardless; no provider
            // push is attempted when the workspace half did not land.
            return result
        }
        result.provider = .notApplicable
        result.detail = localDetail
        // Provider push ONLY when the resolved document really carries a
        // sourceID binding; a plain workspace document honestly reports
        // notApplicable (no provider original exists).
        if document.sourceID != nil, let sourceID = document.sourceID, !sourceID.isEmpty {
            do {
                let reply = try await submit(.pushOriginal, epoch: epoch, fields: [
                    OfficeAIHostField.taskID: document.ownerTaskID.uuidString,
                    OfficeAIHostField.workspaceID: workspaceID.uuidString,
                    OfficeAIHostField.nativeEpoch: String(epoch),
                    OfficeAIHostField.logicalPath: logicalPath,
                ], cancellation: cancellation)
                let status = (reply["status"] as? String) ?? "unknown"
                let recovery = reply["recoveryID"] as? String
                switch status {
                case "ok":
                    result.provider = .committed
                    result.providerToken = "committed"
                    result.recoveryID = recovery
                    result.detail = "Both the workspace original and the provider original now carry "
                        + "the verified edit."
                case "sourceUnbound", "notApplicable":
                    result.provider = .notApplicable
                    result.providerToken = status
                case "conflict", "sourceChangedSinceImport", "driftAtClaim", "rePickRequired",
                     "revoked", "readOnly", "journalRefused":
                    result.provider = .refused
                    result.providerToken = status
                    result.recoveryID = recovery
                    result.detail = "The workspace original carries the edit, but the provider journal "
                        + "refused/conflicted this push (\(status)). Recoverable copies are retained; "
                        + "no native edit was retried."
                case "providerOffline", "pendingRecoverable", "unknown":
                    result.provider = .unknown
                    result.providerToken = status
                    result.recoveryID = recovery
                    result.detail = "The provider push outcome is UNKNOWN; the journaled recovery row "
                        + "stays honestly pending (\(recovery ?? "-")) and is decided only by the "
                        + "provider's actual bytes at a later reconcile."
                default:
                    result.provider = .unknown
                    result.providerToken = status.isEmpty ? "unknown" : String(status.prefix(64))
                }
            } catch let error as OfficeEditHostError {
                // The local commit already happened: a host transport failure
                // here must NOT undo or relabel it.
                result.provider = .unknown
                result.providerToken = error.code
                result.detail = "The workspace original carries the edit; the provider push could not "
                    + "be settled (\(error.code)). Recoverable copies are retained; nothing was retried."
            }
        } else {
            result.provider = .notApplicable
            result.providerToken = "sourceUnbound"
        }
        return result
    }

    // MARK: - context helpers

    private func requiringLiveRecord(contextID: String, conversationID: UUID) throws
        -> OfficeAIEditContextRecord {
        guard let record = store.liveRecord(contextID: contextID, conversationID: conversationID) else {
            throw OfficeEditHostError.rejected(
                code: "editContextMissing",
                detail: "The editContext is unknown, expired, already consumed or belongs to another "
                    + "conversation. Run document.office.edit read again; apply never captures silently.")
        }
        return record
    }

    /// Defense-in-depth reaffirm: the App's CURRENT owned operation must still
    /// name the SAME session token + the SAME ENGINE generation as the
    /// capture. A viewer close/reopen/remount is `editContextStale` BEFORE any
    /// dispatch; the engine's own CAS remains the final authority.
    private func reaffirmSession(epoch: UInt64, record: OfficeAIEditContextRecord,
                                 cancellation: CancellationToken) async throws {
        guard let current = try await lookupSnapshot(epoch: epoch, conversationID: record.conversationID,
                                                     workspaceID: record.document.workspaceID,
                                                     cancellation: cancellation) else {
            throw OfficeEditHostError.rejected(
                code: "editContextStale",
                detail: "The document behind this editContext is no longer the owned open operation "
                    + "for this conversation; read again to capture the current target.")
        }
        guard current.facts.sessionToken == record.document.sessionToken,
              current.facts.nativeGeneration == record.document.nativeGeneration else {
            throw OfficeEditHostError.rejected(
                code: "editContextStale",
                detail: "The engine session/generation behind this editContext changed; the captured "
                    + "target is void. Read again.")
        }
    }

    public func contextDocument(contextID: String, conversationID: UUID) -> OfficeEditDocumentFacts? {
        store.contextDocument(contextID: contextID, conversationID: conversationID)
    }

    public func capturedContextFacts(contextID: String,
                                     conversationID: UUID) -> OfficeEditQueryFacts? {
        store.capturedContext(contextID: contextID, conversationID: conversationID)
    }

    // MARK: - interrupted job reconciliation

    public func interruptedJobArtifact(operationID: String, exportOpId: String,
                                       expectations: OfficeEditExpectations,
                                       cancellation: CancellationToken) async throws
        -> OfficeEditSavedSnapshot? {
        let epoch: UInt64
        do { epoch = try liveEpoch() } catch { return nil }
        let reply: [String: Any]
        do {
            reply = try await submit(.reconcile, epoch: epoch, fields: [
                OfficeAIHostField.exportOpId: exportOpId,
                OfficeAIHostField.format: expectations.family.rawValue,
            ], cancellation: cancellation)
        } catch {
            return nil
        }
        guard (reply["found"] as? Bool) == true, let path = reply["path"] as? String,
              !path.isEmpty else { return nil }
        // No recorded digest exists for an interrupted row: the proof is the
        // exact-opId artifact + independent structure + fresh semantic gate.
        let snapshot: OfficeEditSavedSnapshot
        do {
            snapshot = try adoptAndVerify(path: path, expectedSha256: nil, expectedBytes: nil,
                                          family: expectations.family,
                                          displayName: OfficeDocumentEditTool.collectedDisplayName(
                                            artifactPath: path, format: expectations.family),
                                          attestation: "reconcile-opId",
                                          sessionToken: "", nativeGeneration: 0)
        } catch {
            return nil
        }
        let semantic: OfficeEditSemanticFacts
        do {
            semantic = try await inspectSavedPackage(snapshot, expectations: expectations,
                                                     cancellation: cancellation)
        } catch {
            return nil
        }
        guard !semantic.isUnproven,
              OfficeEditSemanticGate.failure(command: expectations.command, semantic: semantic) == nil
        else { return nil }
        return snapshot
    }

    /// Generation retirement hook: no context minted under a closing lane
    /// may resolve again (late callbacks cannot address a dead generation).
    public func retireAllContexts() {
        store.retireAll()
    }

    public func contextStatsJSON() -> String {
        store.statsJSON()
    }

    /// Actual-state classification of the original file under the SAME
    /// acquired lease service (path containment + digest equality against the
    /// two candidate identities; never a trust of any receipt string).
    enum OriginalReadback { case saved, untouched, drifted, unreadable }

    static func classifyOriginalReadback(service: WorkspaceFileService, logicalPath: String,
                                         expectedOriginal: String, expectedSaved: String,
                                         expectedBytes: Int64) -> OriginalReadback {
        let url: URL
        do {
            url = try service.guardResolver.resolve(logicalPath)
        } catch {
            return .unreadable
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { return .unreadable }
        guard let digest = try? FloeDigest.sha256Hex(ofFileAt: url) else { return .unreadable }
        let normalizedSaved = expectedSaved.lowercased()
        let normalizedOriginal = expectedOriginal.lowercased()
        if digest == normalizedSaved, Int64(values?.fileSize ?? -1) == expectedBytes { return .saved }
        if digest == normalizedOriginal { return .untouched }
        return .drifted
    }

    public func statsJSON() -> String {
        "{\"mailbox\":\(OfficeAIHostMailbox.shared.statsJSON()),\"contexts\":\(store.statsJSON())}"
    }
}

extension OfficeEditReadCommand {
    /// The engine action token for this read.
    var actionToken: String {
        switch self {
        case .documentContext: return "queryDocumentContext"
        case .textSelection: return "queryTextSelection"
        case .cellCursor: return "queryCellCursor"
        case .presentationInfo: return "queryPresentationInfo"
        }
    }
}
