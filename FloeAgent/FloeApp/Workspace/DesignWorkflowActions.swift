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
//   conversation/environment); notices go to THAT identity — never the
//   currently selected chat, never a first-conversation fallback.
// - Durable decision intents are prepared BEFORE the CAS and acked only after
//   confirmed delivery; a delivery failure leaves the intent pending for
//   launch-time reconcile.
// - Missing payload bytes / unsupported content abort BEFORE the CAS: the
//   candidate stays pending and the caller gets the error.

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
        case succeeded(DesignCanvasService.Snapshot, contentApplied: Bool, contentNote: String)
        case failed(Error)
    }

    private static func runID(for caller: Caller) -> UUID? {
        switch caller {
        case .trustedUI: return nil
        case .run(let runID): return runID
        }
    }

    /// Durable decision intent + delivery, shared by UI and tools. Returns
    /// false (with no fallback) when the candidate has no persisted
    /// originating conversation or delivery fails.
    @discardableResult
    static func recordDecision(
        outbox: DesignDecisionOutbox,
        environment: AppEnvironment,
        decisionSink: @escaping @MainActor @Sendable (UUID, UUID, String, Int64?, String?) async -> Void,
        canvasID: UUID,
        candidateID: String,
        decision: String,
        revision: Int64?,
        sha256: String?,
        operationID: String,
        conversationID: UUID?
    ) async -> Bool {
        // The ORIGINATING task is the identity persisted on the candidate at
        // proposal time — never the currently selected conversation.
        guard let candidateUUID = UUID(uuidString: candidateID) else { return false }
        let recorded: UUID? = await {
            // Search all nodes' design subdocuments for the candidate.
            guard let project = try? await FileCanvasDocumentRepository().project(canvasID: canvasID) else { return nil }
            for document in project.documents {
                for node in document.nodes {
                    guard let design = try? DesignCanvasMetadata.decode(
                        node.metadata[DesignCanvasMetadata.key],
                        nodeID: node.id.uuidString.lowercased()
                    ), let candidate = design.candidate(candidateID) else { continue }
                    if let raw = candidate.originConversationID, let uuid = UUID(uuidString: raw) {
                        return uuid
                    }
                }
            }
            return nil
        }()
        guard let target = recorded ?? conversationID else { return false }
        // Durable intent BEFORE any dependent mutation completes.
        let intent: DesignDecisionIntent?
        do {
            intent = try await outbox.prepare(DesignDecisionIntent(
                canvasID: canvasID.uuidString.lowercased(),
                nodeID: "shared",
                candidateID: candidateID,
                conversationID: target.uuidString.lowercased(),
                decision: decision,
                operationID: operationID
            ))
        } catch {
            return false
        }
        await DesignDecisionNotifier.notify(
            conversationID: target, candidateID: candidateID,
            decision: decision, revision: revision, sha256: sha256,
            sink: decisionSink
        )
        if let intent {
            do {
                try await outbox.markDelivered(id: intent.id)
            } catch {
                return false
            }
        }
        return true
    }

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
        canvasID: UUID,
        nodeID: UUID,
        expectedRevision: Int64,
        operationID: String,
        candidateID: String,
        mode: DesignAdoptMode,
        expectedArtifactRevisionID: String? = nil
    ) async -> AdoptionOutcome {
        let runID = self.runID(for: caller)
        do {
            let preRead = try await service.snapshot(runID: runID, canvasID: canvasID, nodeID: nodeID)
            guard let candidate = preRead.design?.candidate(candidateID),
                  let artifact = preRead.design?.artifact(candidate.artifactID),
                  let proposed = artifact.revision(candidate.proposedRevisionID) else {
                return .failed(FloeError.validationFailed("Candidate or its proposed revision no longer exists"))
            }
            guard proposed.payloadRelativePath != nil else {
                // Adoption without retained payload bytes is NOT an adoption:
                // fail before the CAS and keep the candidate pending.
                return .failed(FloeError.validationFailed("The proposed revision has no retained payload; the candidate stays pending"))
            }
            let update: DesignCanvasContentApplicator.PreparedUpdate
            let bytes: Data
            do {
                bytes = try await adapters.verifiedRevisionBytes(
                    canvasID: canvasID, nodeID: nodeID, artifactID: artifact.id,
                    revisionID: proposed.id, expectedContentSHA256: proposed.contentSHA256
                )
            } catch {
                // Missing/corrupt payload: abort BEFORE the CAS so the
                // candidate stays pending.
                return .failed(error)
            }
            do {
                update = try await DesignCanvasContentApplicator.prepare(
                    nodeKind: preRead.nodeKind, bytes: bytes,
                    format: proposed.payloadFormat ?? "bin",
                    displayName: artifact.identity.name,
                    candidateRevisionID: proposed.id,
                    contentSHA256: proposed.contentSHA256,
                    environment: environment,
                    canvasID: canvasID,
                    nodeID: nodeID
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
                    switch mode {
                    case .updateOriginal:
                        designApplyContentUpdate(update, to: &project.documents[documentIndex].nodes[nodeIndex])
                    case .variant:
                        let variant = designApplyVariantUpdate(
                            update,
                            from: project.documents[documentIndex].nodes[nodeIndex],
                            into: &project.documents[documentIndex].nodes
                        )
                        guard let candidateIndex = design.candidates.firstIndex(where: { $0.id == candidateID }) else {
                            throw FloeError.validationFailed("Candidate disappeared during variant adoption")
                        }
                        design.candidates[candidateIndex].variantArtifactID = adopted.id
                        guard let adoptedIndex = design.artifacts.firstIndex(where: { $0.id == adopted.id }) else {
                            throw FloeError.validationFailed("Variant artifact missing after adoption")
                        }
                        design.artifacts[adoptedIndex].canvasNodeID = variant.id.uuidString.lowercased()
                    }
                }
                }
            } catch {
                // CAS failed: only an orphan revision file remains
                // (recyclable); the editor's document is untouched.
                return .failed(error)
            }
            // Post-CAS stable-alias publish for existing editors (journaled,
            // hash-protected; the revision file stays authoritative).
            if let revision = update.documentRevision,
               let revisionFormat = update.documentRevisionFormat {
                do {
                    try DesignWorkspace.publishStableAlias(
                        canvasID: canvasID, nodeID: nodeID,
                        revision: revision, format: revisionFormat
                    )
                } catch {
                    return .failed(error)
                }
            }
            return .succeeded(
                snapshot,
                contentApplied: true,
                contentNote: contentNote
            )
        } catch {
            return .failed(error)
        }
    }

    /// Rejects a candidate without touching the artifact. Run callers are
    /// authorized through their runID.
    static func reject(
        service: DesignCanvasService,
        caller: Caller,
        canvasID: UUID,
        nodeID: UUID,
        expectedRevision: Int64,
        operationID: String,
        candidateID: String
    ) async throws -> DesignCanvasService.Snapshot {
        try await service.mutate(
            runID: runID(for: caller),
            canvasID: canvasID,
            nodeID: nodeID,
            expectedRevision: expectedRevision,
            operationID: operationID
        ) { design in
            try DesignWorkflowEngine.rejectCandidate(in: &design, candidateID: candidateID)
        }
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
                canvasID: canvasID, nodeID: nodeID, artifactID: artifact.id,
                revisionID: target.id, expectedContentSHA256: target.contentSHA256
            )
        } catch {
            throw error
        }
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
                nodeID: nodeID
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
                throw FloeError.validationFailed("Template '\\(template.name)' payload is unavailable: \\(error.localizedDescription)")
            }
            guard !record.payload.isEmpty,
                  let markdown = String(data: record.payload, encoding: .utf8) else {
                throw FloeError.validationFailed("Template '\\(template.name)' has no readable DESIGN.md payload")
            }
            spec = DesignMDCodec.parse(markdown)
        }
        let specToApply = spec
        return try await service.mutate(
            runID: runID(for: caller),
            canvasID: canvasID,
            nodeID: nodeID,
            expectedRevision: expectedRevision,
            operationID: UUID().uuidString.lowercased()
        ) { design in
            design.template = template
            if let specToApply { DesignWorkflowEngine.updateSpec(specToApply, in: &design) }
        }
    }
}
#endif
