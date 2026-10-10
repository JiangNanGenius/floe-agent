// FloeApp — Shared design workflow actions.
//
// ONE production implementation of adopt/reject/restore/template-apply used
// by BOTH the agent tools and the panel. Keeping a single path guarantees UI
// taps and tool calls produce identical CAS commits, identical real node
// content updates, identical grant handling and identical durable notices —
// never two divergent handlers.
//
// Contracts preserved from review:
// - Explicit caller context: trusted UI (panel) vs authorized run (tool).
//   Run callers pass their runID through to the Canvas service, which enforces
//   run→canvas authorization; the panel passes nil (its service instance has
//   no authorization closure).
// - Candidate origin is persisted at PROPOSAL time (originating
//   conversation/environment on the candidate record). Notices go to THAT
//   identity — never the currently selected chat, never a first-conversation
//   fallback. A candidate with no persisted origin FAILS and stays pending.
// - The durable decision intent (full operation fingerprint + exact node) is
//   prepared BEFORE the CAS. The durable ingress sink THROWS on failure; the
//   intent is acknowledged only after confirmed delivery, so a crash/failure
//   leaves the decision pending for launch-time reconcile.
// - Missing payload bytes / unsupported content abort BEFORE the CAS: the
//   candidate stays pending and the caller gets the error.
// - Repeated decisions dedupe on the FULL fingerprint (operationID + node +
//   candidate + origin + decision + mode + base + expected canvas revision),
//   both through design-level operation replay and the durable ledger.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeTools

@MainActor
enum DesignWorkflowActions {
    /// Who is calling: trusted in-app UI, or an authorized agent run.
    enum Caller: Sendable {
        /// The panel: runs without a run context (no run authorization
        /// closure is installed on its service instance).
        case trustedUI
        /// A tool execution: the runID is forwarded so the Canvas service
        /// enforces run→canvas authorization.
        case run(UUID?)
    }

    enum AdoptionOutcome: Sendable {
        /// Content committed. `deliveryError` is non-nil when the candidate
        /// was adopted but the durable notice to the originating task could
        /// not be delivered (it stays in the outbox for reconcile — never a
        /// false "delivered" success).
        case succeeded(DesignCanvasService.Snapshot, contentApplied: Bool, contentNote: String, replayed: Bool = false, deliveryError: String? = nil)
        case failed(Error)
    }

    /// Optional user-grant gate for run callers. The panel passes nil.
    /// Validation runs only for a genuinely NEW operation (after replay and
    /// origin checks, before intent prepare/CAS); consumption runs only after
    /// the CAS committed, so a failed/conflicted CAS never burns the grant.
    struct GrantGate: @unchecked Sendable {
        let validate: @MainActor @Sendable () async -> Bool
        let consume: @MainActor @Sendable () async -> Void
    }

    private static func runID(for caller: Caller) -> UUID? {
        switch caller {
        case .trustedUI: return nil
        case .run(let runID): return runID
        }
    }

    // MARK: - Origin resolution

    /// The EXACT node + originating task for a candidate. The candidate is
    /// read from the design subdocument of `nodeID` on `canvasID` (the
    /// precise target the action addresses). A missing candidate or a
    /// candidate with no persisted originating conversation THROWS: the
    /// decision stays pending and is never routed to the current chat.
    static func resolveDecisionTarget(
        canvasID: UUID,
        nodeID: UUID,
        candidateID: String,
        snapshot: DesignCanvasService.Snapshot?
    ) throws -> (candidate: DesignCandidate, conversationID: UUID) {
        guard let design = snapshot?.design,
              let candidate = design.candidate(candidateID),
              snapshot?.nodeID == nodeID else {
            throw FloeError.validationFailed("Candidate no longer exists on this canvas node; the decision stays pending")
        }
        guard let raw = candidate.originConversationID,
              let origin = UUID(uuidString: raw) else {
            throw FloeError.validationFailed(
                "This proposal has no originating task recorded; its outcome cannot be delivered, so the candidate stays pending"
            )
        }
        return (candidate, origin)
    }

    /// Cross-canvas lookup used by launch reconcile: finds the node whose
    /// design subdocument owns the candidate, if any.
    static func locateCandidate(
        canvasID: UUID,
        candidateID: String,
        repository: CanvasDocumentRepository = FileCanvasDocumentRepository()
    ) async -> (nodeID: UUID, design: DesignProject, candidate: DesignCandidate)? {
        guard let project = try? await repository.project(canvasID: canvasID) else { return nil }
        for document in project.documents {
            for node in document.nodes {
                guard let design = try? DesignCanvasMetadata.decode(
                    node.metadata[DesignCanvasMetadata.key],
                    nodeID: node.id.uuidString.lowercased()
                ), let candidate = design.candidate(candidateID) else { continue }
                return (node.id, design, candidate)
            }
        }
        return nil
    }

    // MARK: - Durable delivery

    /// Delivers the decision through the throwing durable ingress sink, then
    /// acknowledges the intent ONLY after success. A sink failure is returned
    /// (the intent remains `.committing` for reconcile), never swallowed.
    @discardableResult
    static func deliver(
        intent: DesignDecisionIntent,
        revision: Int64?,
        sha256: String?,
        sink: @escaping @MainActor @Sendable (UUID, UUID, String, Int64?, String?) async throws -> Void
    ) async -> Error? {
        guard let conversationID = UUID(uuidString: intent.conversationID),
              let candidateUUID = UUID(uuidString: intent.candidateID) else {
            return FloeError.validationFailed("Durable decision has an invalid target")
        }
        do {
            try await sink(conversationID, candidateUUID, intent.decision, revision, sha256)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Adopt (one shared transaction)

    /// Adopts a candidate: ONE Canvas CAS commit advances the design metadata
    /// AND the real node content (verified payload through the material
    /// library). Layout, name, size, z-order and document connections are
    /// preserved; `.variant` creates an actual new node in the same document.
    /// Missing payload bytes abort before the CAS: the candidate stays
    /// pending and `.failed` carries the error.
    static func adopt(
        service: DesignCanvasService,
        adapters: DesignAdapterCenter,
        environment: AppEnvironment,
        caller: Caller,
        outbox: DesignDecisionOutbox,
        sink: @escaping @MainActor @Sendable (UUID, UUID, String, Int64?, String?) async throws -> Void,
        canvasID: UUID,
        nodeID: UUID,
        expectedRevision: Int64,
        operationID: String,
        candidateID: String,
        mode: DesignAdoptMode,
        expectedArtifactRevisionID: String? = nil,
        grant: GrantGate? = nil
    ) async -> AdoptionOutcome {
        let runID = self.runID(for: caller)
        do {
            let preRead = try await service.snapshot(runID: runID, canvasID: canvasID, nodeID: nodeID)
            // Replay is resolved BEFORE grant validation or any side effect.
            if preRead.design?.hasApplied(operationID: operationID) == true {
                return try replayAdoption(
                    preRead: preRead, candidateID: candidateID, mode: mode
                )
            }
            guard let candidate = preRead.design?.candidate(candidateID),
                  let artifact = preRead.design?.artifact(candidate.artifactID),
                  let proposed = artifact.revision(candidate.proposedRevisionID) else {
                return .failed(FloeError.validationFailed("Candidate or its proposed revision no longer exists"))
            }
            // Origin resolution FAILS CLOSED: no fallback to the current chat.
            let origin: UUID
            do {
                origin = try resolveDecisionTarget(
                    canvasID: canvasID, nodeID: nodeID, candidateID: candidateID, snapshot: preRead
                ).conversationID
            } catch {
                return .failed(error)
            }
            // A user grant is required for run callers and validated only for
            // genuinely new operations.
            if let grant, await !grant.validate() {
                return .failed(FloeError.validationFailed(
                    "Adoption grant is missing, expired or bound to a different candidate/revision"
                ))
            }
            guard proposed.payloadRelativePath != nil else {
                // Adoption without retained payload bytes is NOT an adoption:
                // fail before the CAS and keep the candidate pending.
                return .failed(FloeError.validationFailed("The proposed revision has no retained payload; the candidate stays pending"))
            }
            let bytes: Data
            do {
                bytes = try await adapters.verifiedRevisionBytes(
                    canvasID: canvasID, nodeID: nodeID, artifactID: artifact.id,
                    revisionID: proposed.id, expectedContentSHA256: proposed.contentSHA256
                )
            } catch {
                return .failed(error)
            }
            // The verified revision bytes must be really reopenable by this
            // content type's connected reader BEFORE any CAS: hash equality
            // is integrity, not format proof (Office OOXML parse, CAD
            // same-engine reparse, media decoders).
            let contentType = DesignContentTypeMapper.effectiveContentType(
                existing: preRead.design?.contentType,
                kind: preRead.nodeKind,
                metadata: preRead.nodeMetadata
            )
            guard let contentTypeAdapter = adapters.adapter(for: contentType) else {
                return .failed(FloeError.validationFailed("No design adapter is connected for \(contentType.rawValue)"))
            }
            do {
                try await contentTypeAdapter.verifyExportReopen(
                    bytes: bytes, format: proposed.payloadFormat ?? "bin"
                )
            } catch {
                return .failed(error)
            }
            let update: DesignCanvasContentApplicator.PreparedUpdate
            do {
                update = try await DesignCanvasContentApplicator.prepare(
                    nodeKind: preRead.nodeKind, bytes: bytes,
                    format: proposed.payloadFormat ?? "bin",
                    displayName: artifact.identity.name,
                    candidateRevisionID: proposed.id,
                    contentSHA256: proposed.contentSHA256,
                    environment: environment,
                    canvasID: canvasID,
                    nodeID: nodeID,
                    nodeMetadata: preRead.nodeMetadata
                )
            } catch {
                return .failed(error)
            }
            let contentNote: String
            if update.asset == nil && update.text == nil && update.documentRevision == nil {
                // Provenance-only would fake an adoption; fail and keep the
                // candidate pending.
                return .failed(FloeError.validationFailed("This adoption would change no real content; the candidate stays pending"))
            } else if update.asset == nil && update.text == nil {
                contentNote = "workspace-document"
            } else {
                contentNote = "applied"
            }
            // Durable intent BEFORE the CAS, with the FULL fingerprint. A
            // persistence failure aborts the adoption rather than risking a
            // lost decision; an identical recorded decision dedupes.
            let intent = DesignDecisionIntent(
                canvasID: canvasID.uuidString.lowercased(),
                nodeID: nodeID.uuidString.lowercased(),
                candidateID: candidateID,
                conversationID: origin.uuidString.lowercased(),
                decision: "adopted",
                operationID: operationID,
                mode: mode.rawValue,
                baseRevisionID: candidate.baseRevisionID,
                expectedCanvasRevision: expectedRevision
            )
            let prepared: DesignDecisionIntent
            do {
                let result = try await outbox.prepareIfNew(intent)
                if !result.isNew, result.intent.phase == .recorded {
                    return try replayAdoption(preRead: preRead, candidateID: candidateID, mode: mode)
                }
                prepared = result.intent
            } catch {
                return .failed(error)
            }
            // Stage the variant node identity and (for document-backed
            // content) its OWN revision file BEFORE the CAS, so the variant
            // node — not the original — owns the new binding.
            let variantNodeID: UUID? = mode == .variant ? UUID() : nil
            let variantRevision: DesignWorkspace.RevisionFile? = try {
                guard mode == .variant, update.documentRevision != nil, let variantNodeID else {
                    return nil
                }
                return try DesignWorkspace.writeRevisionFile(
                    bytes: bytes, canvasID: canvasID, nodeID: variantNodeID,
                    format: update.documentRevisionFormat ?? "bin"
                )
            }()
            let snapshot: DesignCanvasService.Snapshot
            do {
                snapshot = try await service.mutateProject(
                runID: runID,
                canvasID: canvasID,
                nodeID: nodeID,
                expectedRevision: expectedRevision,
                operationID: operationID
                ) { project, design in
                let adopted = try DesignWorkflowEngine.adoptCandidate(
                    in: &design,
                    candidateID: candidateID,
                    mode: mode,
                    expectedRevisionID: expectedArtifactRevisionID
                )
                guard let documentIndex = project.documents.firstIndex(where: { $0.nodes.contains(where: { $0.id == nodeID }) }),
                      let nodeIndex = project.documents[documentIndex].nodes.firstIndex(where: { $0.id == nodeID }) else {
                    throw FloeError.validationFailed("Canvas node disappeared during adoption")
                }
                do {
                    switch mode {
                    case .updateOriginal:
                        if let revision = update.documentRevision,
                           let revisionFormat = update.documentRevisionFormat {
                            // ONE CAS flips the binding reference to the
                            // fully-verified revision file (never an in-place
                            // overwrite of the editor's document).
                            design.workspaceBinding = DesignWorkspaceBinding(
                                workspaceRootPath: DesignWorkspace.root(canvasID: canvasID)!.standardizedFileURL.path,
                                relativeDocumentPath: revision.relativePath,
                                format: revisionFormat
                            )
                        }
                        designApplyContentUpdate(update, to: &project.documents[documentIndex].nodes[nodeIndex])
                    case .variant:
                        guard let variantNodeID else {
                            throw FloeError.validationFailed("Variant node identity was not staged")
                        }
                        let variant = designApplyVariantUpdate(
                            update,
                            from: project.documents[documentIndex].nodes[nodeIndex],
                            into: &project.documents[documentIndex].nodes,
                            id: variantNodeID
                        )
                        guard let candidateIndex = design.candidates.firstIndex(where: { $0.id == candidateID }) else {
                            throw FloeError.validationFailed("Candidate disappeared during variant adoption")
                        }
                        design.candidates[candidateIndex].variantArtifactID = adopted.id
                        guard let adoptedIndex = design.artifacts.firstIndex(where: { $0.id == adopted.id }) else {
                            throw FloeError.validationFailed("Variant artifact missing after adoption")
                        }
                        design.artifacts[adoptedIndex].canvasNodeID = variant.id.uuidString.lowercased()
                        // The variant node gets its OWN design subdocument:
                        // copied brief/spec and — for document-backed content
                        // — its own workspace binding/revision file. The
                        // original node's binding is never retargeted.
                        var variantDesign = DesignProject(
                            nodeID: variant.id.uuidString.lowercased(),
                            contentType: design.contentType,
                            brief: design.brief,
                            spec: design.spec
                        )
                        variantDesign.template = design.template
                        if let variantRevision {
                            variantDesign.workspaceBinding = DesignWorkspaceBinding(
                                workspaceRootPath: DesignWorkspace.root(canvasID: canvasID)!.standardizedFileURL.path,
                                relativeDocumentPath: variantRevision.relativePath,
                                format: update.documentRevisionFormat ?? "bin"
                            )
                        }
                        variantDesign.artifacts = [adopted]
                        variantDesign.appliedOperationIDs = [operationID]
                        if let variantIndex = project.documents[documentIndex].nodes.firstIndex(where: { $0.id == variant.id }) {
                            let raw = try DesignCanvasMetadata.encode(variantDesign)
                            project.documents[documentIndex].nodes[variantIndex].metadata[DesignCanvasMetadata.key] = raw
                        }
                    }
                }
                }
            } catch {
                // CAS failed: only an orphan revision file remains
                // (recyclable); the editor's document is untouched. Cancel
                // the fresh intent so reconcile does not deliver a decision
                // that never committed (best effort; on failure reconcile
                // re-checks exact state and cancels it then).
                if prepared.phase == .committing { try? await outbox.cancel(id: prepared.id) }
                return .failed(error)
            }
            // Consume the single-use grant only AFTER the transaction
            // succeeded, so a failed CAS never burns it.
            await grant?.consume()
            // Post-CAS stable-alias publish for existing editors (journaled,
            // hash-protected; the revision file stays authoritative). The
            // variant node's alias is published for ITS OWN binding.
            var aliasError: Error?
            if let revision = update.documentRevision,
               let revisionFormat = update.documentRevisionFormat {
                do {
                    if mode == .variant {
                        if let variantNodeID, let variantRevision {
                            try DesignWorkspace.publishStableAlias(
                                canvasID: canvasID, nodeID: variantNodeID,
                                revision: variantRevision, format: revisionFormat
                            )
                        }
                    } else {
                        try DesignWorkspace.publishStableAlias(
                            canvasID: canvasID, nodeID: nodeID,
                            revision: revision, format: revisionFormat
                        )
                    }
                } catch {
                    aliasError = error
                }
            }
            // Durable delivery to the ORIGINATING task; ack only on success.
            let deliveryError = await Self.deliver(
                intent: prepared, revision: snapshot.canvasRevision,
                sha256: proposed.contentSHA256, sink: sink
            )
            if deliveryError == nil {
                try? await outbox.markDelivered(id: prepared.id)
            }
            if let aliasError { return .failed(aliasError) }
            return .succeeded(
                snapshot,
                contentApplied: true,
                contentNote: contentNote,
                deliveryError: deliveryError?.localizedDescription
            )
        } catch {
            return .failed(error)
        }
    }

    /// Strict replay: the recorded candidate must be in the exact terminal
    /// state THIS request would have produced (same candidate, same base,
    /// mode encoded by variant-artifact presence).
    private static func replayAdoption(
        preRead: DesignCanvasService.Snapshot,
        candidateID: String,
        mode: DesignAdoptMode
    ) throws -> AdoptionOutcome {
        guard let candidate = preRead.design?.candidate(candidateID),
              candidate.status == .adopted,
              (mode == .variant) == (candidate.variantArtifactID != nil) else {
            throw FloeError.validationFailed(
                "operationID was already applied to a different request; idempotency replay requires identical arguments"
            )
        }
        return .succeeded(preRead, contentApplied: false, contentNote: "replayed", replayed: true)
    }

    // MARK: - Reject (one shared transaction)

    /// Rejects a candidate without touching the artifact. Run callers are
    /// authorized through their runID. The durable decision uses the exact
    /// same ledger ordering as adoption.
    @discardableResult
    static func reject(
        service: DesignCanvasService,
        caller: Caller,
        outbox: DesignDecisionOutbox,
        sink: @escaping @MainActor @Sendable (UUID, UUID, String, Int64?, String?) async throws -> Void,
        canvasID: UUID,
        nodeID: UUID,
        expectedRevision: Int64,
        operationID: String,
        candidateID: String
    ) async throws -> DesignCanvasService.Snapshot {
        let runID = runID(for: caller)
        let preRead = try await service.snapshot(runID: runID, canvasID: canvasID, nodeID: nodeID)
        if preRead.design?.hasApplied(operationID: operationID) == true {
            guard let recorded = preRead.design?.candidate(candidateID),
                  recorded.status == .rejected else {
                throw FloeError.validationFailed("operationID was already applied to a different request")
            }
            return preRead
        }
        let candidate = try resolveDecisionTarget(
            canvasID: canvasID, nodeID: nodeID, candidateID: candidateID, snapshot: preRead
        )
        let proposedSHA = preRead.design.flatMap { design -> String? in
            design.artifacts
                .flatMap(\.revisions)
                .first(where: { $0.id == candidate.candidate.proposedRevisionID })?
                .contentSHA256
        }
        let intent = DesignDecisionIntent(
            canvasID: canvasID.uuidString.lowercased(),
            nodeID: nodeID.uuidString.lowercased(),
            candidateID: candidateID,
            conversationID: candidate.conversationID.uuidString.lowercased(),
            decision: "rejected",
            operationID: operationID,
            mode: nil,
            baseRevisionID: candidate.candidate.baseRevisionID,
            expectedCanvasRevision: expectedRevision
        )
        let prepared: DesignDecisionIntent
        do {
            let result = try await outbox.prepareIfNew(intent)
            if !result.isNew, result.intent.phase == .recorded { return preRead }
            prepared = result.intent
        }
        let snapshot: DesignCanvasService.Snapshot
        do {
            snapshot = try await service.mutate(
                runID: runID,
                canvasID: canvasID,
                nodeID: nodeID,
                expectedRevision: expectedRevision,
                operationID: operationID
            ) { design in
                try DesignWorkflowEngine.rejectCandidate(in: &design, candidateID: candidateID)
            }
        } catch {
            if prepared.phase == .committing { try? await outbox.cancel(id: prepared.id) }
            throw error
        }
        let deliveryError = await Self.deliver(
            intent: prepared, revision: snapshot.canvasRevision,
            sha256: proposedSHA, sink: sink
        )
        if deliveryError == nil {
            try? await outbox.markDelivered(id: prepared.id)
        }
        if let deliveryError { throw deliveryError }
        return snapshot
    }

    /// Restores a previous revision: the design metadata AND the real node
    /// content commit in ONE CAS. Payload problems abort before the CAS.
    static func restore(
        service: DesignCanvasService,
        adapters: DesignAdapterCenter,
        environment: AppEnvironment,
        caller: Caller,
        canvasID: UUID,
        nodeID: UUID,
        expectedRevision: Int64,
        operationID: String,
        artifactID: String,
        revisionID: String
    ) async throws -> DesignCanvasService.Snapshot {
        let runID = self.runID(for: caller)
        let preRead = try await service.snapshot(runID: runID, canvasID: canvasID, nodeID: nodeID)
        guard let artifact = preRead.design?.artifact(artifactID),
              let target = artifact.revision(revisionID) else {
            throw FloeError.validationFailed("Artifact or revision not found")
        }
        guard target.payloadRelativePath != nil else {
            throw FloeError.validationFailed("This revision has no retained payload to restore")
        }
        let bytes: Data
        do {
            bytes = try await adapters.verifiedRevisionBytes(
                canvasID: canvasID, nodeID: nodeID, artifactID: artifactID,
                revisionID: target.id, expectedContentSHA256: target.contentSHA256
            )
        } catch {
            throw error
        }
        // Real reopen before the CAS (same gate as adoption).
        let restoreContentType = DesignContentTypeMapper.effectiveContentType(
            existing: preRead.design?.contentType,
            kind: preRead.nodeKind,
            metadata: preRead.nodeMetadata
        )
        guard let restoreAdapter = adapters.adapter(for: restoreContentType) else {
            throw FloeError.validationFailed("No design adapter is connected for \(restoreContentType.rawValue)")
        }
        try await restoreAdapter.verifyExportReopen(
            bytes: bytes, format: target.payloadFormat ?? "bin"
        )
        let update: DesignCanvasContentApplicator.PreparedUpdate
        do {
            update = try await DesignCanvasContentApplicator.prepare(
                nodeKind: preRead.nodeKind, bytes: bytes,
                format: target.payloadFormat ?? "bin",
                displayName: artifact.identity.name,
                candidateRevisionID: target.id,
                contentSHA256: target.contentSHA256,
                environment: environment,
                canvasID: canvasID,
                nodeID: nodeID,
                nodeMetadata: preRead.nodeMetadata
            )
        } catch {
            throw error
        }
        let snapshot: DesignCanvasService.Snapshot
        do {
            snapshot = try await service.mutateProject(
                runID: runID,
                canvasID: canvasID,
                nodeID: nodeID,
                expectedRevision: expectedRevision,
                operationID: operationID
            ) { project, design in
                _ = try DesignWorkflowEngine.restoreRevision(in: &design, artifactID: artifactID, revisionID: revisionID)
                if let revision = update.documentRevision,
                   let revisionFormat = update.documentRevisionFormat {
                    design.workspaceBinding = DesignWorkspaceBinding(
                        workspaceRootPath: DesignWorkspace.root(canvasID: canvasID)!.standardizedFileURL.path,
                        relativeDocumentPath: revision.relativePath,
                        format: revisionFormat
                    )
                }
                guard let documentIndex = project.documents.firstIndex(where: { $0.nodes.contains(where: { $0.id == nodeID }) }),
                      let nodeIndex = project.documents[documentIndex].nodes.firstIndex(where: { $0.id == nodeID }) else {
                    throw FloeError.validationFailed("Canvas node disappeared during restore")
                }
                designApplyContentUpdate(update, to: &project.documents[documentIndex].nodes[nodeIndex])
            }
        } catch {
            throw error
        }
        if let revision = update.documentRevision,
           let revisionFormat = update.documentRevisionFormat {
            try DesignWorkspace.publishStableAlias(
                canvasID: canvasID, nodeID: nodeID,
                revision: revision, format: revisionFormat
            )
        }
        return snapshot
    }

    // MARK: - Use current node (freeze existing content)

    /// Why the current node's existing content cannot be frozen.
    struct CurrentNodeUnavailable: Error, LocalizedError {
        let reason: String
        var errorDescription: String? { reason }

        init(reason: String) { self.reason = reason }

        /// Localized failure with catalog-key resolution at throw time so the
        /// panel shows the active product language (never fixed English).
        init(key: String, _ arguments: String...) {
            self.reason = FloeL10n.localized(key: key, arguments: arguments)
        }
    }

    struct CurrentNodeOutcome: Sendable {
        let snapshot: DesignCanvasService.Snapshot
        let artifactID: String
        let revisionID: String
        let format: String
        let byteCount: Int
        let contentSHA256: String
        let replayed: Bool
    }

    /// Freezes the content ALREADY on the Canvas node into a design revision:
    /// text/markdown body, the node's retained asset bytes, or the
    /// CAD/Office workspace document the node is bound to. No external
    /// export/reimport is needed, and the mutable editor state/drafts are not
    /// touched (the stored document files are read, not rewritten). Every
    /// path uses the existing guards (artifact authority, canonical
    /// workspace binding) and reports a precise reason when unavailable.
    static func useCurrentNode(
        service: DesignCanvasService,
        adapters: DesignAdapterCenter,
        environment: AppEnvironment,
        caller: Caller,
        canvasID: UUID,
        nodeID: UUID,
        expectedRevision: Int64,
        operationID: String,
        displayName: String?
    ) async throws -> CurrentNodeOutcome {
        let runID = runID(for: caller)
        let snapshot = try await service.snapshot(runID: runID, canvasID: canvasID, nodeID: nodeID)
        let node = try await service.node(runID: runID, canvasID: canvasID, nodeID: nodeID)
        let builtinPlugin = node.metadata[DesignContentTypeMapper.builtinPluginMetadataKey]
        let isTextBodyBuiltin = builtinPlugin
            .map { DesignContentTypeMapper.textBodyBuiltinPlugins.contains($0) } ?? false
        let contentType = DesignContentTypeMapper.effectiveContentType(
            existing: snapshot.design?.contentType, kind: node.kind, metadata: node.metadata
        )
        let source: (bytes: Data, format: String, name: String)
        switch node.kind {
        case .text, .stickyNote:
            let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw CurrentNodeUnavailable(key: "design.error.current_node_no_text")
            }
            let format = contentType == .notes ? "md" : "txt"
            source = (Data(node.text.utf8), format, node.title ?? "node-text")
        case .card where isTextBodyBuiltin:
            // Built-in Markdown / HTML / SVG card: the card text IS the typed
            // source. Freeze the exact bytes under the plugin's recorded
            // format; the adapter's real parser verifies them below.
            let pluginID = builtinPlugin!
            let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw CurrentNodeUnavailable(
                    key: "design.error.current_node_builtin_empty", pluginID
                )
            }
            guard let format = DesignContentTypeMapper.builtinPluginFormat(pluginID),
                  DesignContentTypeMapper.builtinPluginContentType(pluginID) == contentType else {
                // Unknown/non-text builtin must fail explicitly, never fall
                // back to treating arbitrary card bytes as text.
                throw CurrentNodeUnavailable(
                    key: "design.error.current_node_builtin_unsupported", pluginID
                )
            }
            source = (Data(node.text.utf8), format, node.title ?? "builtin-\(pluginID)")
        case .image, .video, .file, .audio:
            if let asset = node.asset, let relative = asset.localRelativePath, !relative.isEmpty {
                let root = try FloeArtifactStore.root()
                let fileURL = root.appendingPathComponent(relative)
                guard !relative.split(separator: "/").contains("..") else {
                    throw CurrentNodeUnavailable(key: "design.error.current_node_unsafe_asset_path")
                }
                let bytes: Data
                do {
                    bytes = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                } catch {
                    throw CurrentNodeUnavailable(key: "design.error.current_node_asset_missing")
                }
                guard !bytes.isEmpty else {
                    throw CurrentNodeUnavailable(key: "design.error.current_node_asset_empty")
                }
                if let expected = asset.contentHash, !expected.isEmpty {
                    guard FloeDigest.sha256Hex(bytes) == expected.lowercased() else {
                        throw CurrentNodeUnavailable(key: "design.error.current_node_asset_digest")
                    }
                }
                // Format discipline: prefer the real file extension, then the
                // recorded MIME, then the content-type default.
                let ext = (relative as NSString).pathExtension.lowercased()
                let mimeExt: String = {
                    switch asset.mimeType?.lowercased() {
                    case "image/png": return "png"
                    case "image/jpeg", "image/jpg": return "jpg"
                    case "image/webp": return "webp"
                    case "image/gif": return "gif"
                    case "image/heic": return "heic"
                    case "video/mp4": return "mp4"
                    case "video/quicktime": return "mov"
                    case "application/pdf": return "pdf"
                    default: return ""
                    }
                }()
                let format = !ext.isEmpty ? ext : (mimeExt.isEmpty ? "bin" : mimeExt)
                source = (bytes, format, asset.sourceURL?.lastPathComponent ?? (node.title ?? "node-asset"))
                break
            }
            // No retained asset: fall through to the explicit unavailable
            // error below (Office/CAD nodes with a binding are handled next).
            fallthrough
        case .scene3D, .card, .shape, .group, .generationTask:
            // CAD/Office freeze: the node's explicit workspace binding is the
            // authority. Reads are re-derived through the canonical guard.
            if let design = snapshot.design,
               let binding = try await DesignWorkspace.canonicalBinding(
                   design.workspaceBinding, canvasID: canvasID, nodeID: nodeID
               ) {
                let url = URL(fileURLWithPath: binding.documentAbsolutePath)
                guard let bytes = try? Data(contentsOf: url, options: [.mappedIfSafe]), !bytes.isEmpty else {
                    throw CurrentNodeUnavailable(
                        key: "design.error.current_node_bound_missing", binding.format.uppercased()
                    )
                }
                source = (bytes, binding.format, url.lastPathComponent)
                break
            }
            if node.kind == .scene3D,
               let key = node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath],
               key.hasPrefix(CanvasCADStorage.keyPrefix),
               let packageURL = CanvasCADStorage.packageURL(forKey: key) {
                guard let bytes = try? Data(contentsOf: packageURL, options: [.mappedIfSafe]), !bytes.isEmpty else {
                    throw CurrentNodeUnavailable(key: "design.error.current_node_cad_missing")
                }
                let format = packageURL.pathExtension.lowercased()
                source = (bytes, format.isEmpty ? "bin" : format, packageURL.lastPathComponent)
                break
            }
            // A built-in node without a recognized text body (e.g. panorama3D
            // with no retained asset) reports its own precise reason instead
            // of the generic content-type message.
            if let pluginID = builtinPlugin, !isTextBodyBuiltin {
                throw CurrentNodeUnavailable(
                    key: "design.error.current_node_builtin_unsupported", pluginID
                )
            }
            throw CurrentNodeUnavailable(
                key: "design.error.current_node_none", contentType.rawValue
            )
        }
        // An adapter must exist for this content type; its real parser
        // verifies the frozen bytes before they become a revision.
        guard let adapter = adapters.adapter(for: contentType) else {
            throw FloeError.validationFailed("No design adapter is connected for \(contentType.rawValue)")
        }
        try await adapter.verifyExportReopen(bytes: source.bytes, format: source.format)

        // Replay: same operation returns the recorded current-node revision
        // without publishing another payload.
        if snapshot.design?.hasApplied(operationID: operationID) == true {
            if let recorded = Self.recordedCurrentNodeRevision(
                matching: FloeDigest.sha256Hex(source.bytes), in: snapshot.design
            ) {
                return CurrentNodeOutcome(
                    snapshot: snapshot,
                    artifactID: recorded.artifactID,
                    revisionID: recorded.revisionID,
                    format: source.format,
                    byteCount: source.bytes.count,
                    contentSHA256: recorded.contentSHA256,
                    replayed: true
                )
            }
            throw FloeError.validationFailed("operationID '\(operationID)' was already applied with different content; idempotency replay requires the identical node content")
        }
        let digest = FloeDigest.sha256Hex(source.bytes)
        let artifactID = snapshot.design?.artifacts.first(where: {
            $0.canvasNodeID == nodeID.uuidString.lowercased()
        })?.id ?? UUID().uuidString.lowercased()
        let revisionID = UUID().uuidString.lowercased()
        // Stage + publish the immutable payload BEFORE the CAS (same ordering
        // as imports): the committed revision never points at missing bytes.
        let staged = try adapters.stageRevisionPayload(
            canvasID: canvasID, nodeID: nodeID, artifactID: artifactID,
            revisionID: revisionID, bytes: source.bytes, expectedContentSHA256: digest
        )
        try adapters.commitRevisionPayload(staged)
        let updated: DesignCanvasService.Snapshot
        do {
            updated = try await service.mutate(
                runID: runID,
                canvasID: canvasID,
                nodeID: nodeID,
                expectedRevision: expectedRevision,
                operationID: operationID,
                contentType: contentType
            ) { design in
                if design.artifact(artifactID) == nil {
                    let identity = DesignArtifactIdentity(
                        name: displayName ?? source.name,
                        positionX: node.position.x, positionY: node.position.y,
                        width: node.size.width, height: node.size.height,
                        connections: []
                    )
                    DesignWorkflowEngine.addArtifact(
                        DesignArtifact(
                            id: artifactID,
                            contentType: contentType,
                            canvasNodeID: nodeID.uuidString.lowercased(),
                            identity: identity
                        ),
                        to: &design
                    )
                }
                _ = try DesignWorkflowEngine.registerRevision(
                    in: &design,
                    artifactID: artifactID,
                    contentSHA256: digest,
                    origin: .currentNode,
                    payloadRelativePath: staged.relativePath,
                    payloadFormat: source.format,
                    revisionID: revisionID
                )
            }
        } catch {
            // Only this call's exact orphan payload is removed.
            try? adapters.removeRevisionPayload(
                canvasID: canvasID, nodeID: nodeID, artifactID: artifactID, revisionID: revisionID
            )
            throw error
        }
        return CurrentNodeOutcome(
            snapshot: updated,
            artifactID: artifactID,
            revisionID: revisionID,
            format: source.format,
            byteCount: source.bytes.count,
            contentSHA256: digest,
            replayed: updated.operationReplayed
        )
    }

    private static func recordedCurrentNodeRevision(
        matching digest: String, in design: DesignProject?
    ) -> (artifactID: String, revisionID: String, contentSHA256: String)? {
        guard let design else { return nil }
        for artifact in design.artifacts {
            for revision in artifact.revisions
            where revision.origin == .currentNode && revision.contentSHA256 == digest && revision.payloadRelativePath != nil {
                return (artifactID: artifact.id, revisionID: revision.id, contentSHA256: revision.contentSHA256)
            }
        }
        return nil
    }

    /// Applies a template: the manifest is recorded AND the stored payload
    /// (DESIGN.md) is parsed into the spec — both in one CAS. A stored
    /// template whose payload is missing/corrupt THROWS (never a silent
    /// manifest-only apply); built-in templates intentionally have no stored
    /// payload and apply their manifest only.
    static func applyTemplate(
        service: DesignCanvasService,
        templateStore: DesignTemplateStore?,
        caller: Caller,
        canvasID: UUID,
        nodeID: UUID,
        expectedRevision: Int64,
        operationID: String,
        template: DesignTemplateManifest
    ) async throws -> DesignCanvasService.Snapshot {
        var spec: DesignSpec? = nil
        switch template.origin {
        case .builtIn:
            spec = nil // Built-ins carry no stored payload by design.
        case .user, .signedContent:
            guard let templateStore else {
                throw FloeError.validationFailed("Template store unavailable")
            }
            let record: DesignTemplateStore.Record
            do {
                record = try templateStore.loadUser(id: template.id)
            } catch {
                throw FloeError.validationFailed("Template '\(template.name)' payload is unavailable: \(error.localizedDescription)")
            }
            guard !record.payload.isEmpty,
                  let markdown = String(data: record.payload, encoding: .utf8) else {
                throw FloeError.validationFailed("Template '\(template.name)' has no readable DESIGN.md payload")
            }
            // The stored bytes must match the manifest's claimed digest: a
            // manifest-only or tampered template never applies silently.
            guard FloeDigest.sha256Hex(record.payload) == template.contentSHA256 else {
                throw FloeError.validationFailed(
                    "Template '\(template.name)' payload does not match its recorded digest"
                )
            }
            spec = DesignMDCodec.parse(markdown)
        }
        let specToApply = spec
        return try await service.mutate(
            runID: runID(for: caller),
            canvasID: canvasID,
            nodeID: nodeID,
            expectedRevision: expectedRevision,
            operationID: operationID
        ) { design in
            design.template = template
            if let specToApply { DesignWorkflowEngine.updateSpec(specToApply, in: &design) }
        }
    }
}
#endif
