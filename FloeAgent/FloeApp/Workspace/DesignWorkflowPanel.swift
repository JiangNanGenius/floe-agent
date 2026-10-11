// FloeApp — Design workflow panel (Canvas-bound, separate view file).
//
// Thin integration: the canvas presents this sheet for the selected node. All
// state lives in the node's design subdocument and is written through the
// Canvas revision CAS; user actions here (adopt/reject/restore/spec save) are
// direct. "Authorize assistant adoption" mints a single-use grant that
// `canvas.designAdopt` must consume — the agent cannot adopt on its own.
//
// Review contracts:
// - A failed mutation sets the error and refreshes the canonical snapshot
//   WITHOUT clearing the error: the failure stays visible until the user
//   dismisses it or a later mutation succeeds.
// - Unsaved field edits survive refresh/conflict reloads: fields only re-load
//   from the design when the user has not edited them.
// - Adopting shows the ACTUAL original/candidate previews (payload bytes)
//   before the decision, not model text.
// - Adopt/reject notify the ORIGINATING assistant conversation durably.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeCore
import FloePersistence
import FloeProviders
import FloeTools

@MainActor
final class DesignWorkflowPanelModel: ObservableObject {
    @Published private(set) var snapshot: DesignCanvasService.Snapshot?
    /// Failure state: persists until explicit dismissal or a successful
    /// mutation (a refresh alone never clears it).
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSavedAt: Date?
    @Published private(set) var authorizedCandidateID: String?
    /// Preview bytes per revision id (base/proposed) for pending candidates.
    @Published private(set) var candidatePreviews: [String: CandidatePreviewPair] = [:]

    let canvasID: UUID
    let nodeID: UUID?
    let environment: AppEnvironment?

    private let service = DesignCanvasService(repository: FileCanvasDocumentRepository())
    private let templateStore: DesignTemplateStore?

    init(canvasID: UUID, nodeID: UUID?, environment: AppEnvironment? = nil) {
        self.canvasID = canvasID
        self.nodeID = nodeID
        self.environment = environment
        if let root = DesignTemplateStore.defaultRoot() {
            templateStore = DesignTemplateStore(root: root, builtIn: Self.builtInTemplates)
        } else {
            templateStore = nil
        }
    }

    var design: DesignProject? { snapshot?.design }

    func capabilities() -> DesignCapabilityRegistry {
        environment?.designAdapterCenter.capabilityRegistry() ?? .designCoreDefaults()
    }

    // MARK: - Snapshot

    /// Refreshes the canonical snapshot. Never clears the failure state.
    func reload() async {
        await refreshTemplates()
        guard let nodeID else { return }
        do {
            snapshot = try await service.snapshot(canvasID: canvasID, nodeID: nodeID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - Mutations

    func createDesign(type: DesignContentType, goal: String, audience: String?) async {
        guard let nodeID, let revision = snapshot?.canvasRevision else { return }
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Inherit the canvas-level (project) spec when one exists.
        let inherited = await canvasSharedSpec()
        // The user's selected content type must be the one stored; the node-kind
        // mapping is only a fallback for agent-created subdocuments.
        await mutate(nodeID: nodeID, expectedRevision: revision, contentType: type) { design in
            DesignWorkflowEngine.updateBrief(
                DesignBrief(goal: goal, audience: audience, constraints: []),
                in: &design
            )
            if let inherited { DesignWorkflowEngine.updateSpec(inherited, in: &design) }
        }
    }

    func updateBrief(goal: String, audience: String?, constraints: [String]) async {
        guard let nodeID, let revision = snapshot?.canvasRevision else { return }
        let authority = try? await service.projectAuthority(canvasID: canvasID)
        do {
            _ = try await service.applyProjectAuthority(
                canvasID: canvasID,
                expectedRevision: revision,
                operationID: "project-brief-\(UUID().uuidString.lowercased())",
                brief: DesignBrief(goal: goal, audience: audience, constraints: constraints),
                spec: design?.spec ?? authority?.spec,
                inheritToExistingNodes: true
            )
            snapshot = try await service.snapshot(canvasID: canvasID, nodeID: nodeID)
            lastSavedAt = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            await reload()
        }
    }

    func updateSpec(_ spec: DesignSpec) async {
        guard let nodeID, let revision = snapshot?.canvasRevision else { return }
        let authority = try? await service.projectAuthority(canvasID: canvasID)
        do {
            _ = try await service.applyProjectAuthority(
                canvasID: canvasID,
                expectedRevision: revision,
                operationID: "project-spec-\(UUID().uuidString.lowercased())",
                brief: design?.brief ?? authority?.brief,
                spec: spec,
                inheritToExistingNodes: true
            )
            snapshot = try await service.snapshot(canvasID: canvasID, nodeID: nodeID)
            lastSavedAt = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            await reload()
        }
    }

    /// Freezes whatever content already exists on this node into a design
    /// revision (text body, retained asset bytes, or the bound CAD/Office
    /// workspace document) — no external export/reimport. Precise reasons
    /// surface for content that is not available.
    func useCurrentNode() async {
        guard let nodeID, let revision = snapshot?.canvasRevision, let environment else { return }
        do {
            let outcome = try await DesignWorkflowActions.useCurrentNode(
                service: service,
                adapters: environment.designAdapterCenter,
                environment: environment,
                caller: .trustedUI,
                canvasID: canvasID,
                nodeID: nodeID,
                expectedRevision: revision,
                operationID: "current-node-\(UUID().uuidString.lowercased())",
                displayName: nil
            )
            snapshot = outcome.snapshot
            lastSavedAt = Date()
            errorMessage = nil
        } catch let unavailable as DesignWorkflowActions.CurrentNodeUnavailable {
            errorMessage = unavailable.reason
        } catch {
            errorMessage = error.localizedDescription
            await reload()
        }
    }

    func applyTemplate(_ template: DesignTemplateManifest) async {
        guard let nodeID, let revision = snapshot?.canvasRevision else { return }
        do {
            snapshot = try await DesignWorkflowActions.applyTemplate(
                service: service,
                templateStore: templateStore,
                caller: .trustedUI,
                canvasID: canvasID,
                nodeID: nodeID,
                expectedRevision: revision,
                operationID: "template-\(template.id)-\(template.contentSHA256.prefix(16))",
                template: template
            )
            lastSavedAt = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            await reload()
        }
    }

    func importDesignMarkdown(_ markdown: String) async {
        let parsed = DesignMDCodec.parse(markdown)
        await updateSpec(parsed)
    }

    /// The canvas-level (project) brief/spec authority stored ON the Canvas
    /// project itself. New node designs inherit it; unrelated node edits can
    /// never change which payload is authoritative.
    func canvasSharedSpec() async -> DesignSpec? {
        try? await service.projectAuthority(canvasID: canvasID)?.spec
    }

    /// Applies the current node's spec to the Canvas project authority in ONE
    /// project CAS: the authority record AND every existing design
    /// subdocument inherit the payload in the same commit. Repeated identical
    /// payloads dedupe (no revision bump); conflicting revisions are
    /// reported, never overwritten blindly.
    @discardableResult
    func propagateSpecToCanvas() async -> (updated: Int, skipped: Int) {
        guard let nodeID, let revision = snapshot?.canvasRevision else { return (0, 0) }
        let existing = try? await service.projectAuthority(canvasID: canvasID)
        guard let spec = design?.spec ?? existing?.spec else { return (0, 0) }
        do {
            let result = try await service.applyProjectAuthority(
                canvasID: canvasID,
                expectedRevision: revision,
                operationID: "project-spec-\(UUID().uuidString.lowercased())",
                brief: design?.brief ?? existing?.brief,
                spec: spec,
                inheritToExistingNodes: true
            )
            snapshot = try await service.snapshot(canvasID: canvasID, nodeID: nodeID)
            errorMessage = nil
            return (result.updatedNodeIDs.count, result.skippedNodeIDs.count)
        } catch {
            errorMessage = error.localizedDescription
            await reload()
            return (0, 0)
        }
    }

    /// Exports the current spec as DESIGN.md (unknown sections preserved).
    func exportDesignMarkdown() -> Data? {
        guard let spec = design?.spec else { return nil }
        return DesignMDCodec.export(spec).data(using: .utf8)
    }

    /// UI parity: the SAME shared adoption transaction as
    /// `canvas.designAdopt` — replay/origin/grant checks, durable intent
    /// (full fingerprint) BEFORE the CAS, one CAS commit for metadata + real
    /// node content, then the throwing durable notice to the ORIGINATING
    /// assistant conversation (acknowledged only after it persists).
    func adopt(candidateID: String, mode: DesignAdoptMode) async {
        guard let nodeID, let revision = snapshot?.canvasRevision, let environment else { return }
        let outcome = await DesignWorkflowActions.adopt(
            service: service,
            adapters: environment.designAdapterCenter,
            environment: environment,
            caller: .trustedUI,
            outbox: DesignDecisionOutbox.shared,
            sink: Self.durableSink(environment: environment),
            canvasID: canvasID,
            nodeID: nodeID,
            expectedRevision: revision,
            operationID: UUID().uuidString.lowercased(),
            candidateID: candidateID,
            mode: mode
        )
        switch outcome {
        case .succeeded(let snapshot, _, _, _, let deliveryError):
            self.snapshot = snapshot
            lastSavedAt = Date()
            candidatePreviews[candidateID] = nil
            if let deliveryError {
                // Content committed; the notice is durable-pending and a
                // launch reconcile delivers it. Keep the adoption but surface
                // the delivery state instead of claiming full delivery.
                errorMessage = deliveryError
            } else {
                errorMessage = nil
            }
        case .failed(let error):
            // Preserve the failure across the canonical refresh; reload for
            // the next retry but keep the actionable error visible.
            errorMessage = error.localizedDescription
            await reload()
        }
    }

    func authorizeAssistantAdoption(candidateID: String) async {
        guard let nodeID,
              let candidate = design?.candidate(candidateID),
              let artifact = design?.artifact(candidate.artifactID),
              let proposed = artifact.revision(candidate.proposedRevisionID) else { return }
        // Mint the exact binding the assistant's `canvas.designAdopt` will
        // claim: the same candidate/base AND the actual proposed revision and
        // mode shown here (the panel offers the original-node update only).
        // A missing/mismatched claim fails closed with no side effects.
        _ = await DesignAdoptionAuthorization.shared.issue(
            canvasID: canvasID, nodeID: nodeID,
            candidateID: candidateID,
            baselineRevisionID: candidate.baseRevisionID,
            proposedRevisionID: proposed.id,
            mode: .updateOriginal
        )
        authorizedCandidateID = candidateID
    }

    func reject(candidateID: String) async {
        guard let nodeID, let revision = snapshot?.canvasRevision, let environment else { return }
        do {
            snapshot = try await DesignWorkflowActions.reject(
                service: service,
                caller: .trustedUI,
                outbox: DesignDecisionOutbox.shared,
                sink: Self.durableSink(environment: environment),
                canvasID: canvasID, nodeID: nodeID,
                expectedRevision: revision, operationID: UUID().uuidString.lowercased(),
                candidateID: candidateID
            )
            lastSavedAt = Date()
            errorMessage = nil
            candidatePreviews[candidateID] = nil
        } catch {
            // Preserve the failure across the canonical refresh.
            errorMessage = error.localizedDescription
            await reload()
        }
    }

    /// The REAL durable ingress for panel-initiated decisions: queued runtime
    /// input on the ORIGINATING conversation + idempotent transcript upsert.
    /// It THROWS (the shared action acknowledges the outbox only after this
    /// actually persists) — never `try?`.
    private static func durableSink(environment: AppEnvironment) -> @MainActor @Sendable (UUID, UUID, String, Int64?, String?) async throws -> Void {
        { conversationID, proposalID, decision, revision, sha256 in
            try await environment.conversationCenter.recordProposalDecision(
                conversationID: conversationID,
                proposalID: proposalID,
                decision: "design-candidate-\(decision)",
                revision: revision,
                sha256: sha256
            )
        }
    }

    func restoreLatestRevision(artifactID: String) async {
        guard let nodeID, let revision = snapshot?.canvasRevision, let environment,
              let artifact = design?.artifact(artifactID),
              let currentID = artifact.currentRevisionID else { return }
        let previous = artifact.revisions
            .filter { $0.id != currentID }
            .sorted { $0.number > $1.number }
            .first
        guard let previous else { return }
        do {
            snapshot = try await DesignWorkflowActions.restore(
                service: service,
                adapters: environment.designAdapterCenter,
                environment: environment,
                caller: .trustedUI,
                canvasID: canvasID,
                nodeID: nodeID,
                expectedRevision: revision,
                operationID: UUID().uuidString.lowercased(),
                artifactID: artifactID,
                revisionID: previous.id
            )
            lastSavedAt = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            await reload()
        }
    }

    /// Human feedback entry: anchored to the selected artifact revision with
    /// an explicit region/time/page/object anchor.
    func addFeedback(
        artifactID: String,
        anchor: DesignFeedbackAnchor,
        comment: String
    ) async {
        guard let nodeID, let revision = snapshot?.canvasRevision,
              !comment.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        await mutate(nodeID: nodeID, expectedRevision: revision) { design in
            _ = try DesignWorkflowEngine.addFeedback(
                in: &design,
                artifactID: artifactID,
                anchor: anchor,
                comment: comment,
                author: .user
            )
        }
    }

    /// Relocates a stale anchor to the artifact's current revision after the
    /// user confirms the new location.
    func relocateFeedback(feedbackID: String, artifactID: String) async {
        guard let nodeID, let revision = snapshot?.canvasRevision,
              let artifact = design?.artifact(artifactID),
              let anchor = design?.feedback(feedbackID)?.anchor else { return }
        await mutate(nodeID: nodeID, expectedRevision: revision) { design in
            try DesignWorkflowEngine.relocateAnchor(
                in: &design, feedbackID: feedbackID, anchor: anchor,
                toRevisionID: artifact.currentRevisionID
            )
        }
    }

    /// Human import: the adapter validates with the real editor boundary,
    /// the payload is retained under the artifact authority and the revision
    /// commits through the same Canvas CAS as the agent path.
    @discardableResult
    func importSourceFile(_ url: URL) async throws -> Bool {
        guard let nodeID, let revision = snapshot?.canvasRevision, let environment else {
            throw FloeError.invalidConfiguration("Design environment is unavailable")
        }
        let contentType = DesignContentTypeMapper.effectiveContentType(
            existing: design?.contentType,
            kind: snapshot?.nodeKind ?? .file,
            metadata: snapshot?.nodeMetadata ?? [:]
        )
        guard let adapter = await environment.designAdapterCenter.adapter(for: contentType) else {
            throw FloeError.validationFailed("No design adapter is connected for \(contentType.rawValue)")
        }
        let imported = try await adapter.importSource(fileURL: url, canvasID: canvasID, nodeID: nodeID)
        let digest = FloeDigest.sha256Hex(imported.bytes)
        let artifactID = UUID().uuidString.lowercased()
        let revisionID = UUID().uuidString.lowercased()
        let staged = try await environment.designAdapterCenter.stageRevisionPayload(
            canvasID: canvasID, nodeID: nodeID, artifactID: artifactID,
            revisionID: revisionID, bytes: imported.bytes, expectedContentSHA256: digest
        )
        try await environment.designAdapterCenter.commitRevisionPayload(staged)
        do {
            snapshot = try await service.mutate(
                canvasID: canvasID, nodeID: nodeID, expectedRevision: revision,
                operationID: UUID().uuidString.lowercased()
            ) { design in
                let artifact = DesignArtifact(
                    id: artifactID, contentType: contentType,
                    canvasNodeID: nodeID.uuidString.lowercased(),
                    identity: .init(
                        name: url.lastPathComponent,
                        positionX: 0, positionY: 0, width: 0, height: 0
                    )
                )
                DesignWorkflowEngine.addArtifact(artifact, to: &design)
                _ = try DesignWorkflowEngine.registerRevision(
                    in: &design, artifactID: artifactID, contentSHA256: digest,
                    origin: .importFile, payloadRelativePath: staged.relativePath,
                    payloadFormat: imported.format, revisionID: revisionID
                )
            }
        } catch {
            try? await environment.designAdapterCenter.removeRevisionPayload(
                canvasID: canvasID, nodeID: nodeID, artifactID: artifactID, revisionID: revisionID
            )
            throw error
        }
        lastSavedAt = Date()
        return true
    }

    /// Human verified export: recorded format only, real reopen validation,
    /// delivered through the existing share sheet with a scratch lease.
    func exportCurrentRevision(artifactID: String) async throws -> NotesExport.Artifact? {
        guard let nodeID, let environment,
              let artifact = design?.artifact(artifactID),
              let revision = artifact.currentRevision else {
            throw FloeError.validationFailed("No current revision to export")
        }
        let export = try await environment.designAdapterCenter.exportVerifiedRevision(
            canvasID: canvasID, nodeID: nodeID, artifactID: artifact.id,
            revision: revision, artifact: artifact, requestedFormat: nil
        )
        let lease = await StorageCleanupLeaseCenter.shared.acquireToken(path: export.url.path)
        return NotesExport.Artifact(url: export.url, lease: lease)
    }

    // MARK: - Previews (actual bytes, never model text)

    struct RevisionPreview: Sendable {
        enum Body: Sendable {
            case image(Data)
            case text(String)
            case unavailable(String)
        }
        let body: Body
        let byteCount: Int
        let contentSHA256: String
    }

    struct CandidatePreviewPair: Sendable {
        let base: RevisionPreview?
        let proposed: RevisionPreview?
    }

    /// Loads the real payload previews for a pending candidate's base and
    /// proposed revisions through the shared artifact authority.
    func loadCandidatePreview(_ candidateID: String) async {
        guard let environment, let design, let candidate = design.candidate(candidateID),
              let artifact = design.artifact(candidate.artifactID) else { return }
        let center = environment.designAdapterCenter
        func preview(for revisionID: String) -> RevisionPreview? {
            guard let revision = artifact.revision(revisionID) else { return nil }
            guard let relative = revision.payloadRelativePath else {
                return RevisionPreview(
                    body: .unavailable(String(localized: "design.panel.preview_not_retained")),
                    byteCount: 0, contentSHA256: revision.contentSHA256
                )
            }
            do {
                let data = try center.verifiedRevisionBytes(
                    canvasID: canvasID, nodeID: nodeID ?? UUID(),
                    artifactID: artifact.id, revisionID: revision.id,
                    expectedContentSHA256: revision.contentSHA256
                )
                _ = relative
                let body: RevisionPreview.Body
                if artifact.contentType == .image, let image = UIImage(data: data), image.size.width > 0 {
                    body = .image(data)
                } else if let text = String(data: data, encoding: .utf8) {
                    body = .text(String(text.prefix(4000)))
                } else {
                    body = .unavailable(String(localized: "design.panel.preview_binary"))
                }
                return RevisionPreview(body: body, byteCount: data.count, contentSHA256: revision.contentSHA256)
            } catch {
                return RevisionPreview(
                    body: .unavailable(error.localizedDescription),
                    byteCount: 0, contentSHA256: revision.contentSHA256
                )
            }
        }
        let pair = CandidatePreviewPair(
            base: preview(for: candidate.baseRevisionID),
            proposed: preview(for: candidate.proposedRevisionID)
        )
        candidatePreviews[candidateID] = pair
    }

    // MARK: - Templates

    @Published private(set) var templateList: [DesignTemplateManifest] = []

    func refreshTemplates() async {
        var all = templateStore?.builtIn ?? []
        all.append(contentsOf: (try? templateStore?.userTemplates().map(\.manifest)) ?? [])
        if let environment {
            all.append(contentsOf: await DesignSignedTemplateSource.installedTemplates(environment: environment))
        }
        templateList = all
    }

    func saveUserTemplate(name: String, markdown: Data) async -> String? {
        guard let templateStore, !name.trimmingCharacters(in: .whitespaces).isEmpty, !markdown.isEmpty else { return nil }
        let manifest = DesignTemplateManifest(
            id: "user.\(UUID().uuidString.lowercased())",
            name: name,
            contentType: design?.contentType ?? .webpage,
            capabilities: ["brief", "spec (DESIGN.md)"],
            inputs: ["DESIGN.md"],
            dependencies: [],
            outputFormats: ["design-spec"],
            license: "User-created",
            source: "local",
            version: "1",
            contentSHA256: FloeDigest.sha256Hex(markdown),
            origin: .user
        )
        return try? templateStore.saveUser(manifest: manifest, payload: markdown).id
    }

    // MARK: - Private

    private enum MutationOutcome: Sendable { case succeeded, failed }

    @discardableResult
    private func mutate(
        nodeID: UUID,
        expectedRevision: Int64,
        contentType: DesignContentType? = nil,
        _ body: @escaping @Sendable (inout DesignProject) throws -> Void
    ) async -> MutationOutcome {
        do {
            snapshot = try await service.mutate(
                canvasID: canvasID,
                nodeID: nodeID,
                expectedRevision: expectedRevision,
                operationID: UUID().uuidString.lowercased(),
                contentType: contentType,
                body: body
            )
            lastSavedAt = Date()
            errorMessage = nil
            return .succeeded
        } catch {
            // Preserve the failure across the snapshot refresh: reload the
            // canonical state for the next retry but keep the error visible.
            errorMessage = error.localizedDescription
            await reload()
            return .failed
        }
    }

    /// Honest built-in templates: capabilities list only what the template
    /// truly supports; inputs/dependencies/formats/license are real.
    static let builtInTemplates: [DesignTemplateManifest] = [
        DesignTemplateManifest(
            id: "builtin.webpage.landing", name: "Webpage — Landing",
            contentType: .webpage,
            capabilities: ["brief", "spec (DESIGN.md)", "source import", "region feedback", "browser snapshot capture", "verified export"],
            inputs: ["goal", "optional HTML source"],
            dependencies: ["browser session for page capture"],
            outputFormats: ["html", "json snapshot"],
            license: "Built into Floe", source: "app", version: "1",
            contentSHA256: FloeDigest.sha256Hex(Data("builtin.webpage.landing.v1".utf8)),
            origin: .builtIn
        ),
        DesignTemplateManifest(
            id: "builtin.image.concept", name: "Image — Concept",
            contentType: .image,
            capabilities: ["brief", "spec (DESIGN.md)", "source import", "region feedback", "verified export"],
            inputs: ["goal", "optional reference image"],
            dependencies: ["configured image generation model for generate"],
            outputFormats: ["png", "jpeg", "webp"],
            license: "Built into Floe", source: "app", version: "1",
            contentSHA256: FloeDigest.sha256Hex(Data("builtin.image.concept.v1".utf8)),
            origin: .builtIn
        ),
        DesignTemplateManifest(
            id: "builtin.notes.document", name: "Notes — Document",
            contentType: .notes,
            capabilities: ["brief", "spec (DESIGN.md)", "page feedback", "verified export"],
            inputs: ["goal"],
            dependencies: [],
            outputFormats: ["md", "text"],
            license: "Built into Floe", source: "app", version: "1",
            contentSHA256: FloeDigest.sha256Hex(Data("builtin.notes.document.v1".utf8)),
            origin: .builtIn
        ),
        DesignTemplateManifest(
            id: "builtin.prototype.flow", name: "Prototype — Flow",
            contentType: .prototype,
            capabilities: ["brief", "spec (DESIGN.md)", "source import", "region feedback", "browser snapshot capture", "verified export"],
            inputs: ["goal", "optional HTML source"],
            dependencies: ["browser session for page capture"],
            outputFormats: ["html", "json snapshot"],
            license: "Built into Floe", source: "app", version: "1",
            contentSHA256: FloeDigest.sha256Hex(Data("builtin.prototype.flow.v1".utf8)),
            origin: .builtIn
        )
    ]
}

// MARK: - View

struct DesignWorkflowPanel: View {
    @StateObject private var model: DesignWorkflowPanelModel
    @Environment(\.dismiss) private var dismiss

    @State private var newGoal = ""
    @State private var newAudience = ""
    @State private var newType: DesignContentType = .webpage
    @State private var briefGoal = ""
    @State private var briefAudience = ""
    @State private var paletteText = ""
    @State private var typographyText = ""
    @State private var layoutText = ""
    @State private var spacingText = ""
    @State private var voiceText = ""
    @State private var prohibitionsText = ""
    @State private var loadedDesignID: String?
    /// True while the user's field edits must survive snapshot reloads.
    @State private var fieldsDirty = false
    @State private var showsDesignMDImporter = false
    @State private var designMDExport: DesignMDExportItem?
    @State private var showsSourceImporter = false
    @State private var sourceImportError: String?
    @State private var exportedArtifact: NotesExport.Artifact?
    @State private var previewItem: PreviewItem?
    @State private var feedbackDraft: FeedbackDraft = FeedbackDraft()
    @State private var specPropagation: String?

    private struct FeedbackDraft {
        var artifactID = ""
        var anchorKind = 0 // 0 region, 1 time, 2 page, 3 object
        var x = "", y = "", width = "", height = "", seconds = "", page = "", objectID = ""
        var comment = ""
    }

    private struct PreviewItem: Identifiable {
        let id = UUID()
        let url: URL
        let lease: ScratchLeaseToken?
    }

    init(canvasID: UUID, nodeID: UUID?, environment: AppEnvironment? = nil) {
        _model = StateObject(wrappedValue: DesignWorkflowPanelModel(canvasID: canvasID, nodeID: nodeID, environment: environment))
    }

    var body: some View {
        NavigationStack {
            Form {
                if model.nodeID == nil {
                    Section {
                        ContentUnavailableView(
                            "design.panel.select_node",
                            systemImage: "square.dashed",
                            description: Text("design.panel.select_node_detail")
                        )
                    }
                }

                if let error = model.errorMessage {
                    Section {
                        HStack(alignment: .top) {
                            Text(error).foregroundStyle(.red)
                            Spacer()
                            Button("design.panel.dismiss_error") { model.dismissError() }
                                .buttonStyle(.borderless)
                        }
                    }
                }

                if model.design == nil && model.nodeID != nil {
                    Section("design.panel.new_design") {
                        Picker("design.panel.type", selection: $newType) {
                            ForEach(DesignContentType.allCases, id: \.self) { type in
                                Text(FloeL10n.l("design.panel.type.\(type.rawValue)")).tag(type)
                            }
                        }
                        DesignBriefFields(
                            goal: $newGoal, audience: $newAudience,
                            goalLabel: "design.panel.goal",
                            audienceLabel: "design.panel.audience",
                            goalIdentifier: "design.panel.create.goal",
                            audienceIdentifier: "design.panel.create.audience",
                            onEdit: { fieldsDirty = true })
                        Button("design.panel.create") {
                            fieldsDirty = false
                            Task {
                                await model.createDesign(
                                    type: newType, goal: newGoal,
                                    audience: newAudience.isEmpty ? nil : newAudience
                                )
                            }
                        }
                        .disabled(newGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if let design = model.design {
                    DisclosureGroup("design.panel.brief") {
                        DesignBriefFields(
                            goal: $briefGoal, audience: $briefAudience,
                            goalLabel: "design.panel.goal",
                            audienceLabel: "design.panel.audience",
                            goalIdentifier: "design.panel.brief.goal",
                            audienceIdentifier: "design.panel.brief.audience",
                            onEdit: { fieldsDirty = true })
                        Button("design.panel.save_brief") {
                            fieldsDirty = false
                            Task {
                                await model.updateBrief(
                                    goal: briefGoal,
                                    audience: briefAudience.isEmpty ? nil : briefAudience,
                                    constraints: design.brief?.constraints ?? []
                                )
                            }
                        }
                    }

                    DisclosureGroup("design.panel.spec") {
                        DesignSpecField(
                            label: "design.panel.palette", text: $paletteText,
                            identifier: "design.panel.spec.palette",
                            onEdit: { fieldsDirty = true })
                        DesignSpecField(
                            label: "design.panel.typography", text: $typographyText,
                            identifier: "design.panel.spec.typography",
                            onEdit: { fieldsDirty = true })
                        DesignSpecField(
                            label: "design.panel.layout", text: $layoutText,
                            identifier: "design.panel.spec.layout",
                            onEdit: { fieldsDirty = true })
                        DesignSpecField(
                            label: "design.panel.spacing", text: $spacingText,
                            identifier: "design.panel.spec.spacing",
                            onEdit: { fieldsDirty = true })
                        DesignSpecField(
                            label: "design.panel.voice", text: $voiceText,
                            identifier: "design.panel.spec.voice",
                            onEdit: { fieldsDirty = true })
                        DesignSpecField(
                            label: "design.panel.prohibitions", text: $prohibitionsText,
                            identifier: "design.panel.spec.prohibitions",
                            onEdit: { fieldsDirty = true })
                        Button("design.panel.save_spec") {
                            fieldsDirty = false
                            Task { await model.updateSpec(specFromFields(design)) }
                        }
                        Button("design.panel.propagate_spec") {
                            Task {
                                let result = await model.propagateSpecToCanvas()
                                specPropagation = FloeL10n.l(
                                    "design.panel.propagate_spec_result",
                                    result.updated, result.skipped
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                        if let specPropagation {
                            Text(specPropagation).font(.caption2).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("design.panel.export_designmd") {
                                if let data = model.exportDesignMarkdown() {
                                    designMDExport = DesignMDExportItem(data: data)
                                }
                            }
                            .disabled(design.spec == nil)
                            Button("design.panel.import_designmd") { showsDesignMDImporter = true }
                        }
                        .buttonStyle(.bordered)
                        if fieldsDirty {
                            Text("design.panel.unsaved_note").font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("design.panel.spec_frozen_note").font(.caption2).foregroundStyle(.secondary)
                    }

                    DisclosureGroup("design.panel.templates") {
                        ForEach(model.templateList) { template in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(template.name).font(.headline)
                                Text("design.panel.template_meta")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(template.capabilities.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.tertiary)
                                Button("design.panel.apply_template") {
                                    Task { await model.applyTemplate(template) }
                                }
                                .buttonStyle(.bordered)
                            }
                            .frame(minHeight: FloeTheme.minimumTarget)
                        }
                    }

                    DisclosureGroup("design.panel.artifacts") {
                        if design.artifacts.isEmpty {
                            Text("design.panel.no_value").foregroundStyle(.secondary)
                        }
                        Button("design.panel.import_source") { showsSourceImporter = true }
                            .buttonStyle(.bordered)
                        Button("design.panel.use_current_node") {
                            Task { await model.useCurrentNode() }
                        }
                        .buttonStyle(.bordered)
                        if let sourceImportError {
                            Text(sourceImportError).font(.caption2).foregroundStyle(.red)
                        }
                        ForEach(design.artifacts) { artifact in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(artifact.identity.name)
                                Text(FloeL10n.l("design.panel.revision_count", artifact.revisions.count))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let current = artifact.currentRevision {
                                    Text("\(FloeL10n.l("design.panel.current_revision")): #\(current.number) · \(DesignOwnerLabels.revisionOrigin(current.origin))")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                HStack {
                                    Button("design.panel.preview_current") {
                                        Task {
                                            do {
                                                if let artifact2 = try await model.exportCurrentRevision(artifactID: artifact.id) {
                                                    previewItem = PreviewItem(url: artifact2.url, lease: artifact2.lease)
                                                }
                                            } catch {
                                                sourceImportError = error.localizedDescription
                                            }
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    Button("design.panel.export_current") {
                                        Task {
                                            do {
                                                exportedArtifact = try await model.exportCurrentRevision(artifactID: artifact.id)
                                            } catch {
                                                sourceImportError = error.localizedDescription
                                            }
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                    if artifact.revisions.count >= 2 {
                                        Button("design.panel.restore_latest") {
                                            Task { await model.restoreLatestRevision(artifactID: artifact.id) }
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                            .frame(minHeight: FloeTheme.minimumTarget)
                        }
                    }

                    DisclosureGroup("design.panel.feedback") {
                        if design.feedback.isEmpty {
                            Text("design.panel.no_value").foregroundStyle(.secondary)
                        }
                        if let firstArtifact = design.artifacts.first {
                            Section("design.panel.add_feedback") {
                                Picker("design.panel.feedback_anchor", selection: $feedbackDraft.anchorKind) {
                                    Text("design.panel.anchor.region").tag(0)
                                    Text("design.panel.anchor.time").tag(1)
                                    Text("design.panel.anchor.page").tag(2)
                                    Text("design.panel.anchor.object").tag(3)
                                }
                                switch feedbackDraft.anchorKind {
                                case 0:
                                    HStack {
                                        TextField("x", text: $feedbackDraft.x).keyboardType(.decimalPad)
                                        TextField("y", text: $feedbackDraft.y).keyboardType(.decimalPad)
                                        TextField("design.panel.anchor.w", text: $feedbackDraft.width).keyboardType(.decimalPad)
                                        TextField("design.panel.anchor.h", text: $feedbackDraft.height).keyboardType(.decimalPad)
                                    }
                                case 1:
                                    TextField("design.panel.anchor.seconds", text: $feedbackDraft.seconds).keyboardType(.decimalPad)
                                case 2:
                                    TextField("design.panel.anchor.page_index", text: $feedbackDraft.page).keyboardType(.numberPad)
                                default:
                                    TextField("design.panel.anchor.object_id", text: $feedbackDraft.objectID)
                                }
                                TextField("design.panel.feedback_comment", text: $feedbackDraft.comment, axis: .vertical)
                                Button("design.panel.submit_feedback") {
                                    let anchor: DesignFeedbackAnchor
                                    switch feedbackDraft.anchorKind {
                                    case 0:
                                        anchor = .region(
                                            x: Double(feedbackDraft.x) ?? 0, y: Double(feedbackDraft.y) ?? 0,
                                            width: Double(feedbackDraft.width) ?? 0, height: Double(feedbackDraft.height) ?? 0
                                        )
                                    case 1:
                                        anchor = .time(seconds: Double(feedbackDraft.seconds) ?? 0)
                                    case 2:
                                        anchor = .page(index: Int(feedbackDraft.page) ?? 0)
                                    default:
                                        anchor = .objectID(feedbackDraft.objectID)
                                    }
                                    let comment = feedbackDraft.comment
                                    feedbackDraft.comment = ""
                                    Task { await model.addFeedback(artifactID: firstArtifact.id, anchor: anchor, comment: comment) }
                                }
                                .disabled(feedbackDraft.comment.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                        ForEach(design.feedback) { item in
                            DesignFeedbackRow(
                                comment: item.comment,
                                statusText: "\(item.anchor.kind) · \(item.status.rawValue)",
                                statusColor: .secondary,
                                busy: false,
                                showsRelocate: item.status == .staleAnchor
                                    && design.artifact(item.artifactID) != nil,
                                showsResolve: false,
                                relocateTitle: "design.panel.relocate_anchor",
                                onRelocate: {
                                    guard let artifact = design.artifact(item.artifactID) else { return }
                                    Task { await model.relocateFeedback(feedbackID: item.id, artifactID: artifact.id) }
                                },
                                onResolve: {})
                        }
                    }

                    DisclosureGroup("design.panel.candidates") {
                        if design.candidates.isEmpty {
                            Text("design.panel.no_value").foregroundStyle(.secondary)
                        }
                        ForEach(design.candidates) { candidate in
                            candidateSection(candidate)
                        }
                    }

                    DisclosureGroup("design.panel.capabilities") {
                        if let contentType = design.contentType as DesignContentType? {
                            let capability = model.capabilities().capability(for: contentType)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(FloeL10n.l("design.panel.capability_available")): "
                                     + (capability.available.map(\.rawValue).sorted().joined(separator: ", ")))
                                    .font(.caption2).foregroundStyle(.secondary)
                                ForEach(capability.unavailableReasons.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { operation in
                                    Text("\(FloeL10n.l("design.panel.capability_unavailable")) — \(operation.rawValue): \(capability.unavailableReasons[operation] ?? "")")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("design.panel.title")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("design.panel.close") { dismiss() }
                }
            }
            .task {
                await model.reload()
                loadFieldsIfNeeded(force: true)
            }
            .onChange(of: model.snapshot?.design?.updatedAt) { _, _ in
                // Refresh the canonical snapshot display, but never clobber
                // edits the user is still typing.
                loadFieldsIfNeeded(force: false)
            }
            .fileImporter(isPresented: $showsSourceImporter, allowedContentTypes: [.data]) { result in
                guard let url = try? result.get() else { return }
                sourceImportError = nil
                Task {
                    do { try await model.importSourceFile(url) }
                    catch { sourceImportError = error.localizedDescription }
                }
            }
            .sheet(item: $exportedArtifact) { item in
                NotesShareSheet(url: item.url, lease: item.lease)
            }
            .sheet(item: $previewItem) { item in
                NavigationStack {
                    QuickLookView(url: item.url)
                        .navigationTitle(item.url.lastPathComponent)
                        .onDisappear { item.lease?.release() }
                }
            }
            .fileImporter(isPresented: $showsDesignMDImporter, allowedContentTypes: [UTType(filenameExtension: "md") ?? .plainText]) { result in
                guard let url = try? result.get(), let data = try? Data(contentsOf: url),
                      let markdown = String(data: data, encoding: .utf8) else { return }
                fieldsDirty = false
                Task { await model.importDesignMarkdown(markdown) }
            }
            .sheet(item: $designMDExport) { item in
                NotesShareSheet(url: item.url, lease: item.lease)
            }
        }
        .frame(minWidth: 420, minHeight: 520)
    }

    @ViewBuilder
    private func candidateSection(_ candidate: DesignCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            DesignCandidateSummaryRow(
                summary: candidate.summary,
                statusText: candidate.status.rawValue,
                statusColor: .secondary)
            if candidate.status == .pending {
                Button("design.panel.show_previews") {
                    Task { await model.loadCandidatePreview(candidate.id) }
                }
                .buttonStyle(.bordered)
                if let pair = model.candidatePreviews[candidate.id] {
                    HStack(alignment: .top, spacing: 12) {
                        previewColumn("design.panel.preview_base", preview: pair.base)
                        previewColumn("design.panel.preview_proposed", preview: pair.proposed)
                    }
                    if let base = pair.base, let proposed = pair.proposed,
                       base.contentSHA256 != proposed.contentSHA256 {
                        Text("design.panel.preview_differs")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DesignCandidateActionButtons(
                    busy: false,
                    adoptTitle: "design.panel.adopt",
                    showsVariant: false,
                    rejectTitle: "design.panel.reject",
                    adoptIdentifier: "design.panel.adopt.\(candidate.id)",
                    rejectIdentifier: "design.panel.reject.\(candidate.id)",
                    onAdopt: { Task { await model.adopt(candidateID: candidate.id, mode: .updateOriginal) } },
                    onVariant: {},
                    onReject: { Task { await model.reject(candidateID: candidate.id) } })
                Button("design.panel.authorize_assistant") {
                    Task { await model.authorizeAssistantAdoption(candidateID: candidate.id) }
                }
                .buttonStyle(.bordered)
                if model.authorizedCandidateID == candidate.id {
                    Text("design.panel.authorized_note")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: FloeTheme.minimumTarget)
    }

    @ViewBuilder
    private func previewColumn(_ title: String, preview: DesignWorkflowPanelModel.RevisionPreview?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            if let preview {
                switch preview.body {
                case .image(let data):
                    if let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable().scaledToFit()
                            .frame(maxWidth: 180, maxHeight: 140)
                            .border(Color.secondary.opacity(0.3))
                    }
                case .text(let text):
                    Text(text).font(.caption2).lineLimit(8)
                        .frame(maxWidth: 180, alignment: .leading)
                        .padding(4)
                        .border(Color.secondary.opacity(0.3))
                case .unavailable(let reason):
                    Text(reason).font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: 180, alignment: .leading)
                }
                Text(ByteCountFormatter.string(fromByteCount: Int64(preview.byteCount), countStyle: .file))
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("design.panel.no_value").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 200)
    }

    private func loadFieldsIfNeeded(force: Bool) {
        guard let design = model.design else { return }
        guard !fieldsDirty || force else { return }
        let key = design.nodeID + ":" + ISO8601DateFormatter().string(from: design.updatedAt)
        guard loadedDesignID != key || force else { return }
        loadedDesignID = key
        briefGoal = design.brief?.goal ?? ""
        briefAudience = design.brief?.audience ?? ""
        paletteText = (design.spec?.palette ?? []).joined(separator: ", ")
        typographyText = design.spec?.typography ?? ""
        layoutText = design.spec?.layout ?? ""
        spacingText = design.spec?.spacing ?? ""
        voiceText = design.spec?.voice ?? ""
        prohibitionsText = (design.spec?.prohibitions ?? []).joined(separator: ", ")
    }

    private func specFromFields(_ design: DesignProject) -> DesignSpec {
        func list(_ text: String) -> [String]? {
            let values = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return values.isEmpty ? nil : values
        }
        func value(_ text: String) -> String? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return DesignSpec(
            palette: list(paletteText),
            typography: value(typographyText),
            layout: value(layoutText),
            spacing: value(spacingText),
            brandAssetRefs: design.spec?.brandAssetRefs,
            voice: value(voiceText),
            prohibitions: list(prohibitionsText),
            rawMarkdown: design.spec?.rawMarkdown
        )
    }
}

// MARK: - Shared design leaf controls (Canvas + owner panels)
//
// These are the ONE leaf implementations of the brief inputs, candidate
// decision row and feedback entry. Both the Canvas-bound panel and the
// generic owner sheet compose them, so the two surfaces can never drift.
// Neither component owns state or authority: every mutation stays with the
// panel whose workflow (Canvas project CAS vs owner envelope) owns it.

/// Brief leaf: goal + audience inputs with panel-specific labels and
/// accessibility identifiers. The save command stays with the owning panel.
struct DesignBriefFields: View {
    @Binding var goal: String
    @Binding var audience: String
    let goalLabel: LocalizedStringKey
    let audienceLabel: LocalizedStringKey
    let goalIdentifier: String
    let audienceIdentifier: String
    var onEdit: () -> Void = {}

    var body: some View {
        TextField(goalLabel, text: $goal, axis: .vertical)
            .lineLimit(1...3)
            .onChange(of: goal) { _, _ in onEdit() }
            .accessibilityIdentifier(goalIdentifier)
        TextField(audienceLabel, text: $audience)
            .onChange(of: audience) { _, _ in onEdit() }
            .accessibilityIdentifier(audienceIdentifier)
    }
}

/// Spec leaf: one labelled spec input (Canvas' structured fields and the
/// owner's raw-markdown spec both render through this control). The owning
/// panel decides how the value is stored — Canvas writes the structured
/// project authority, the owner stores raw markdown on its envelope.
struct DesignSpecField: View {
    let label: LocalizedStringKey
    @Binding var text: String
    var lineLimit: ClosedRange<Int>? = nil
    var identifier: String? = nil
    var onEdit: () -> Void = {}

    var body: some View {
        Group {
            if let lineLimit {
                TextField(label, text: $text, axis: .vertical)
                    .lineLimit(lineLimit)
            } else {
                TextField(label, text: $text, axis: .vertical)
            }
        }
        .onChange(of: text) { _, _ in onEdit() }
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// Candidate leaf: one-line summary + pending status + the bounded diff with
/// its honest truncation note. Mutations render through
/// `DesignCandidateActionButtons` below the content.
struct DesignCandidateSummaryRow: View {
    let summary: String
    let statusText: String
    let statusColor: Color
    var diffLines: [String]? = nil
    var diffTruncated = false
    var diffNote: String? = nil
    var emptySummaryKey: String = "design.owner.candidate"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label {
                    Text(summary.isEmpty ? FloeL10n.l(emptySummaryKey) : summary)
                } icon: {
                    Image(systemName: "sparkles")
                }
                Spacer()
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }
            if let diffLines {
                ForEach(Array(diffLines.prefix(40).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption2.monospaced())
                        .foregroundStyle(
                            line.hasPrefix("+") ? Color.green
                                : line.hasPrefix("-") ? Color.red
                                : Color.secondary)
                }
                if diffTruncated {
                    Text(diffNote ?? FloeL10n.l("design.owner.diff_truncated"))
                        .font(.caption2)
                        .foregroundStyle(FloeTheme.pending)
                }
            }
        }
    }
}

/// Candidate leaf: the shared adopt / variant / reject decision row. The
/// panel supplies mode availability and identifiers; it never re-implements
/// the decision buttons.
struct DesignCandidateActionButtons: View {
    let busy: Bool
    let adoptTitle: LocalizedStringKey
    let showsVariant: Bool
    var rejectTitle: LocalizedStringKey = "design.owner.reject"
    var adoptIdentifier: String? = nil
    var variantIdentifier: String? = nil
    var rejectIdentifier: String? = nil
    let onAdopt: () -> Void
    let onVariant: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button(adoptTitle, action: onAdopt)
                    .disabled(busy)
                    .accessibilityIdentifier(adoptIdentifier ?? "")
                Button(rejectTitle, role: .destructive, action: onReject)
                    .disabled(busy)
                    .accessibilityIdentifier(rejectIdentifier ?? "")
            }
            .buttonStyle(.borderless)
            if showsVariant {
                Button("design.owner.adopt_variant", action: onVariant)
                    .disabled(busy)
                    .accessibilityIdentifier(variantIdentifier ?? "")
            }
        }
    }
}

/// Feedback leaf: comment + status + the exact relocate/resolve commands.
struct DesignFeedbackRow: View {
    let comment: String
    let statusText: String
    let statusColor: Color
    let busy: Bool
    let showsRelocate: Bool
    let showsResolve: Bool
    var relocateTitle: LocalizedStringKey = "design.owner.feedback_relocate"
    var resolveTitle: LocalizedStringKey = "design.owner.feedback_resolve"
    let onRelocate: () -> Void
    let onResolve: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(comment)
                Spacer()
                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }
            if showsRelocate {
                Button(relocateTitle, action: onRelocate)
                    .disabled(busy)
            }
            if showsResolve {
                Button(resolveTitle, action: onResolve)
                    .disabled(busy)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DesignMDExportItem: Identifiable {
    let id = UUID()
    let url: URL
    let lease: ScratchLeaseToken?
    init?(data: Data) {
        guard let directory = try? FloeScratch.makeDirectory(purpose: "media") else { return nil }
        let url = directory.appendingPathComponent("DESIGN.md")
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        self.url = url
        self.lease = nil
    }
}
// MARK: - Generic owner workflow (file / chat attachment / creative)

/// Stable target constructors shared by every T6 design entrance. IDs are the
/// LIVE owner identities (workspace/file/attachment/creative request), never
/// invented Canvas UUIDs.
enum DesignOwnerTargets {
    static func file(workspaceID: UUID, relativePath: String) -> DesignTarget {
        DesignTarget(
            kind: .fileDocument,
            ownerID: workspaceID.uuidString,
            documentID: "",
            sourceID: relativePath)
    }

    static func chatAttachment(
        conversationID: UUID, messageID: UUID, attachmentID: UUID
    ) -> DesignTarget {
        DesignTarget(
            kind: .chatAttachment,
            ownerID: conversationID.uuidString,
            documentID: messageID.uuidString,
            sourceID: attachmentID.uuidString,
            originConversationID: conversationID.uuidString)
    }

    /// A creative START request. The request identity is the source; the
    /// owner is the stable creative-library surface. The requested output
    /// kind is part of the frozen identity and is never guessed later.
    static func creative(requestID: UUID, kind: DesignContentType) -> DesignTarget {
        DesignTarget(
            kind: .creativeDocument,
            ownerID: "creative-library",
            documentID: "",
            sourceID: requestID.uuidString,
            requestedOutputKind: kind)
    }
}

/// UI recency bookkeeping for creative START requests (the durable request
/// itself lives in the SAME owner design envelope). Presentation only: no
/// design state, no project store, no arbitrary paths.
enum DesignCreativeRequestStore {
    private static let key = "floe.design.creativeRequests"

    static func load() -> [DesignTarget] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let targets = try? JSONDecoder().decode([DesignTarget].self, from: data) else {
            return []
        }
        return targets.filter { $0.kind == .creativeDocument && $0.requestedOutputKind != nil }
    }

    static func remember(_ target: DesignTarget) {
        var targets = load().filter { $0.stableKey != target.stableKey }
        targets.insert(target, at: 0)
        if targets.count > 12 { targets = Array(targets.prefix(12)) }
        if let data = try? JSONEncoder().encode(targets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Trusted-UI confirmation for one assistant adoption: which candidate, which
/// mode, the single-use grant id the AI tool must present, and when that grant
/// expires. The id is only delivered through the existing runtime decision
/// channel; it is never shown as ordinary UI copy.
struct AssistantAdoptionAuthorization: Equatable {
    let candidateID: String
    let mode: DesignAdoptMode
    let grantID: String
    let expiresAt: Date
}

/// Frozen first-generation operation shown to the user BEFORE any provider
/// call: the actual configured model, the resolved parameters, an honest
/// fee advisory, and the exact operation identity the submission will use.
/// An image amount is shown ONLY from verified image-specific pricing
/// provenance (none exists today); ordinary token pricing never becomes a
/// per-image claim.
struct GenerationConfirmationRequest: Equatable {
    let prompt: String
    let goal: String
    let frozenOwnerRevision: Int64
    let idempotencyKey: String
    let providerID: UUID
    let modelID: UUID
    let modelTitle: String
    let parametersSummary: String
    /// A verified image-specific amount, when real image billing provenance
    /// exists. nil today: the model profile carries only TEXT token pricing,
    /// which is NOT a per-image price, so no amount is ever advertised.
    let costSummary: String?
}

/// One shared panel model for the three non-Canvas design owners. It drives
/// the SAME `DesignOwnerWorkflow` the agent tools use; Canvas never enters
/// this path (T3 C14 fails it closed).
@MainActor
final class DesignOwnerWorkflowModel: ObservableObject {
    @Published private(set) var envelope: DesignOwnerEnvelope?
    @Published private(set) var resolvedSource: DesignResolvedSource?
    @Published private(set) var sourceUnavailableReason: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusNote: String?
    @Published private(set) var busy = false
    @Published private(set) var comparison: DesignOwnerWorkflow.Comparison?
    /// Creative START only: real library assets that can become the FIRST
    /// materialized result of the request (existing service, no hidden
    /// content). Generation through the existing media tools remains the other
    /// supported first-result path.
    @Published private(set) var bindableCreativeAssets: [CreativeAssetRecord] = []
    /// Creative START: whether a REAL first-result generation route is
    /// connected for the requested output kind, with the honest reason when
    /// it is not. Derived from the same capability registry the agent tools
    /// and Canvas use.
    @Published private(set) var generationAvailable = false
    @Published private(set) var generationUnavailableReason: String?
    @Published private(set) var generating = false
    /// Creative generation bookkeeping from the DURABLE media job (never
    /// transient UI state):
    /// - `generationUnknownOutcome`: an earlier submission of this exact
    ///   frozen request exists whose remote outcome is unknown. It is never
    ///   resubmitted automatically; the user may explicitly discard it.
    /// - `generationResultAwaitingBind`: a ready job already produced a real
    ///   asset; the next Generate binds THAT result (no second paid call).
    @Published private(set) var generationUnknownOutcome = false
    @Published private(set) var generationResultAwaitingBind = false
    /// The durable job records a published result whose asset row/file no
    /// longer resolves on this device. The user must explicitly replace it
    /// (one acknowledged new generation) or discard the dangling record;
    /// nothing is sent automatically and the stale result id is never reused.
    @Published private(set) var generationResultMissing = false
    /// The dangling job identity behind `generationResultMissing`.
    @Published private(set) var generationMissingJobID: UUID?
    /// The user acknowledged a MISSING-result replacement: the next confirmed
    /// generation is the one explicit new attempt.
    private var generationReplacementPending = false
    /// The frozen operation shown for explicit user acceptance BEFORE the
    /// first provider call (model/parameters/possible cost). nil when no
    /// confirmation is pending.
    @Published private(set) var generationConfirmation: GenerationConfirmationRequest?
    /// True while the duplicate-charge warning for an acknowledged discard is
    /// being shown; nothing is discarded until the user confirms.
    @Published private(set) var generationDiscardWarning = false
    /// True while the acknowledged-discard warning for a MISSING result is
    /// being shown; nothing changes until the user confirms.
    @Published private(set) var generationMissingDiscardWarning = false
    /// Trusted-UI confirmation minted for the assistant's `design.adopt`
    /// tool: the SAME `DesignOwnerAuthorization` instance the tools consume,
    /// bound to this exact target/candidate/base/proposed-revision/mode. Only
    /// set AFTER the confirmation event was durably delivered to the frozen
    /// originating task.
    @Published private(set) var authorizedAssistantAdoption: AssistantAdoptionAuthorization?

    let target: DesignTarget
    private let environment: AppEnvironment
    private var operationCounter = 0
    /// The in-flight UI generation task, so the explicit Cancel action can
    /// stop waiting (a definite local cancellation).
    private var generationTask: Task<Void, Never>?

    init(target: DesignTarget, environment: AppEnvironment) {
        self.target = target
        self.environment = environment
    }

    var project: DesignProject? { envelope?.project }
    var currentArtifact: DesignArtifact? { project?.artifacts.first }
    var pendingCandidates: [DesignCandidate] {
        (project?.candidates ?? []).filter { $0.status == .pending }
    }
    var openFeedback: [DesignFeedback] {
        (project?.feedback ?? []).filter { $0.status == .open || $0.status == .staleAnchor }
    }
    var isImmutableOwner: Bool {
        target.kind == .chatAttachment || target.kind == .creativeDocument
    }
    var isCreativeAwaitingFirstResult: Bool {
        project?.creativeRequest?.state == .awaitingFirstResult
    }
    /// A creative target whose request has not been saved yet. In this stage
    /// the creative request editor owns goal/audience and the standalone
    /// brief editor must not render a second editor over the same fields.
    var isCreativeRequestUncreated: Bool {
        target.kind == .creativeDocument && project?.creativeRequest == nil
    }

    /// The FROZEN originating task a confirmation may notify: the target's own
    /// frozen origin, or the durable creative request's recorded origin. nil
    /// means no honest notify target exists — the panel then offers only the
    /// direct manual adopt, never a button that pretends to notify anyone.
    var confirmationOriginConversationID: UUID? {
        if let raw = target.originConversationID,
           let value = UUID(uuidString: raw) { return value }
        if let raw = project?.creativeRequest?.originConversationID,
           let value = UUID(uuidString: raw) { return value }
        return nil
    }
    var canAuthorizeAssistant: Bool { confirmationOriginConversationID != nil }

    private func operationID(_ suffix: String) -> String {
        operationCounter += 1
        return "ui-\(suffix)-\(UUID().uuidString.lowercased())"
    }

    func reload() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            envelope = try await environment.designOwnerWorkflow.state(target)
            errorMessage = nil
        } catch let error as DesignOwnerWorkflowError {
            if case .canvasRequiresCanvasAuthority = error {
                envelope = nil
                errorMessage = FloeL10n.l("design.owner.canvas_authority")
            } else {
                errorMessage = Self.friendly(error)
            }
        } catch {
            errorMessage = Self.friendly(error)
        }
        // Source bytes are resolved READ-ONLY for display (name/format/
        // editability). A missing source is an honest unavailable reason, not
        // a fabricated name.
        do {
            resolvedSource = try await environment.designTargetService.resolve(target)
            sourceUnavailableReason = nil
        } catch {
            resolvedSource = nil
            sourceUnavailableReason = Self.friendly(error)
        }
        if target.kind == .creativeDocument {
            refreshGenerationAvailability()
            await refreshGenerationJobState()
            await loadBindableCreativeAssets()
        }
    }

    /// Reads the DURABLE media job for this exact frozen creative request.
    /// A ready job whose asset still resolves only needs to be bound; a job
    /// whose recorded result row/file no longer resolves is an explicit
    /// missing-result state; an unresolved submission is reported as unknown.
    /// Nothing is ever resent from here.
    private func refreshGenerationJobState() async {
        // While THIS session is actively waiting on the provider, the job is
        // in flight (not an unknown crash remnant): leave the live state be.
        guard !generating else { return }
        generationResultAwaitingBind = false
        generationUnknownOutcome = false
        generationResultMissing = false
        generationMissingJobID = nil
        guard isCreativeAwaitingFirstResult,
              let request = project?.creativeRequest else { return }
        let key = Self.generationIdempotencyKey(target: target, request: request)
        guard let outcome = try? await environment.mediaGenerationService
            .recoverDesignCreativeImage(idempotencyKey: key) else { return }
        if outcome.asset != nil {
            generationResultAwaitingBind = true
        } else if outcome.resultMissing {
            generationResultMissing = true
            generationMissingJobID = outcome.job.id
        } else if !outcome.job.state.isTerminal {
            generationUnknownOutcome = outcome.job.providerTaskID == nil
        }
    }

    // MARK: - Creative first real result (import + bind)

    /// Real capability for the requested output kind: only an operation the
    /// adapter registry actually connects is offered; otherwise the honest
    /// reason is shown and no button pretends to generate.
    func refreshGenerationAvailability() {
        guard target.kind == .creativeDocument,
              let kind = target.requestedOutputKind else {
            generationAvailable = false
            generationUnavailableReason = nil
            return
        }
        let capability = environment.designAdapterCenter.capabilityRegistry()
            .capability(for: kind)
        generationAvailable = capability.available.contains(.generate)
        generationUnavailableReason = generationAvailable
            ? nil
            : DesignOwnerLabels.generationUnavailableReason(
                capability.unavailableReasons[.generate])
    }

    /// Loads real, local creative-library assets whose verified format matches
    /// the requested output kind. These are candidates for `bindFirstResult`
    /// (the generation path uses the existing media tools and the same bind).
    func loadBindableCreativeAssets() async {
        guard target.kind == .creativeDocument,
              let kind = target.requestedOutputKind else {
            bindableCreativeAssets = []
            return
        }
        let assets = (try? await environment.creativeAssetStore.allAssets()) ?? []
        bindableCreativeAssets = assets.filter { asset in
            guard let relative = asset.localRelativePath, !relative.isEmpty,
                  asset.byteCount <= Int64(AppWorkspaceFilePort.maxSourceBytes) else {
                return false
            }
            let format = (relative as NSString).pathExtension.lowercased()
            return DesignContentType.from(format: format) == kind
        }
    }

    /// Binds an EXISTING library asset as the first real result of the
    /// creative request. Bytes are read through the SAME bounded reader as
    /// the generation bind (real on-disk size cap BEFORE any read,
    /// symlink-resolved containment and digest verification); the same
    /// workflow call is used by both paths.
    func bindFirstExistingResult(_ asset: CreativeAssetRecord) async {
        guard !busy, isCreativeAwaitingFirstResult else { return }
        busy = true
        defer { busy = false }
        let frozenRevision = envelope?.revision ?? 0
        do {
            let resolved = try await AppCreativeDocumentPort.resolveVerifiedAssetBytes(
                assetStore: environment.creativeAssetStore,
                artifactRoot: { try FloeArtifactStore.root() },
                creationID: asset.id.uuidString)
            let outcome = try await environment.designOwnerWorkflow.bindFirstResult(
                target: target,
                operationID: operationID("bind-first-result"),
                expectedOwnerRevision: frozenRevision,
                bytes: resolved.data,
                format: resolved.format,
                displayName: asset.displayName,
                boundResultID: asset.id.uuidString)
            envelope = outcome.envelope
            errorMessage = nil
            statusNote = FloeL10n.l("design.owner.creative_bound")
        } catch {
            errorMessage = Self.friendly(error)
        }
    }

    /// REAL first-result generation through the EXISTING durable media
    /// generation service (job store + provider call + creative asset store):
    ///
    /// - everything is frozen BEFORE the first await (prompt/spec, owner
    ///   revision, model route, operation identity);
    /// - the durable job row is written before the provider call, so a crash
    ///   leaves an honest record and reopening finds the SAME original job;
    /// - the provider output is persisted as a REAL verified creative asset
    ///   and the job becomes ready, then the SAME `bindFirstResult` binds the
    ///   actual asset UUID (never a synthetic id);
    /// - an unresolved earlier submission is never resent automatically; a
    ///   ready result is bound without a second paid call; a manual edit that
    ///   landed during generation conflicts honestly with the result retained.
    /// UI entry for the FIRST generation call: freezes the exact operation
    /// (prompt/spec, owner revision, model route, parameters, operation
    /// identity) and publishes the confirmation the user must accept BEFORE
    /// any provider dispatch. No job row and no provider call happen here.
    func requestGenerationConfirmation() {
        guard !busy, !generating, isCreativeAwaitingFirstResult,
              let kind = target.requestedOutputKind else { return }
        refreshGenerationAvailability()
        guard generationAvailable else {
            errorMessage = generationUnavailableReason
                ?? FloeL10n.l("design.owner.generate_unavailable")
            return
        }
        // This lane connects still-image generation only; every other kind
        // reports its real capability instead of faking a result.
        guard kind == .image else {
            errorMessage = FloeL10n.l("design.owner.generate_unavailable")
            return
        }
        guard let request = project?.creativeRequest else {
            errorMessage = FloeL10n.l("design.owner.generate_needs_brief")
            return
        }
        let goal = project?.brief?.goal.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !goal.isEmpty else {
            errorMessage = FloeL10n.l("design.owner.generate_needs_brief")
            return
        }
        let frozenRevision = envelope?.revision ?? 0
        let prompt = Self.generationPrompt(
            goal: goal, audience: project?.brief?.audience,
            spec: project?.spec, kind: kind)
        let selection = ImageGenerationSelection()
        do {
            let route = try environment.conversationCenter.resolveAgentImageRoute(
                operation: .generate, modelID: nil, selection: selection,
                count: 1, referenceCount: 0)
            let effective = ImageGenerationPresetResolver.applyingDefaults(
                selection, provider: route.0, model: route.1, operation: .generate)
            generationConfirmation = GenerationConfirmationRequest(
                prompt: prompt,
                goal: goal,
                frozenOwnerRevision: frozenRevision,
                idempotencyKey: Self.generationIdempotencyKey(
                    target: target, request: request),
                providerID: route.0.id,
                modelID: route.1.id,
                modelTitle: Self.modelTitle(route.1),
                parametersSummary: Self.parametersSummary(effective),
                costSummary: Self.costSummary(for: route.1))
            errorMessage = nil
        } catch {
            errorMessage = Self.friendly(error)
        }
    }

    func dismissGenerationConfirmation() {
        generationConfirmation = nil
    }

    /// Programmatic confirm (tests/automation). The UI uses
    /// `startConfirmedGeneration` so the wait stays cancellable.
    func confirmGeneration() async {
        guard let confirmation = generationConfirmation else { return }
        generationConfirmation = nil
        await performGeneration(confirmation)
    }

    /// UI confirm: runs the confirmed operation as one cancellable task.
    func startConfirmedGeneration() {
        guard generationTask == nil, !generating,
              let confirmation = generationConfirmation else { return }
        generationConfirmation = nil
        generationTask = Task { [weak self] in
            guard let self else { return }
            await self.performGeneration(confirmation)
            self.generationTask = nil
        }
    }

    /// REAL first-result generation through the EXISTING durable media
    /// generation service (job store + provider call + creative asset store):
    ///
    /// - everything was frozen BEFORE the confirmation (prompt/spec, owner
    ///   revision, model route, operation identity);
    /// - the durable job row is written before the provider call, so a crash
    ///   leaves an honest record and reopening finds the SAME original job;
    /// - the provider output is persisted as a REAL verified creative asset
    ///   and the job becomes ready, then the SAME `bindFirstResult` binds the
    ///   actual asset UUID against the ORIGINAL submission revision (stored
    ///   on the job row), never the current envelope revision;
    /// - an unresolved earlier submission is never resent automatically; a
    ///   ready result binds without a second paid call; a manual edit that
    ///   landed during generation conflicts with the result retained for
    ///   explicit resolution.
    private func performGeneration(_ confirmation: GenerationConfirmationRequest) async {
        guard isCreativeAwaitingFirstResult,
              let request = project?.creativeRequest else { return }
        let idempotencyKey = Self.generationIdempotencyKey(target: target, request: request)
        generating = true
        defer { generating = false }
        // User-acknowledged REPLACEMENT of a missing published result: one
        // new durable submission under the SAME request identity through the
        // existing service; the stale ready row/id is never reused and this
        // never runs automatically.
        if generationReplacementPending, let missingJobID = generationMissingJobID {
            generationReplacementPending = false
            do {
                let outcome = try await environment.mediaGenerationService
                    .replaceMissingDesignCreativeResult(jobID: missingJobID)
                if let asset = outcome.asset {
                    generationResultMissing = false
                    generationMissingJobID = nil
                    generationUnknownOutcome = false
                    try await bindGeneratedAsset(
                        assetID: asset.id,
                        operationID: Self.generationOperationID(jobID: outcome.job.id),
                        frozenRevision: confirmation.frozenOwnerRevision)
                } else {
                    generationUnknownOutcome = outcome.awaitingUnknownOutcome
                    errorMessage = outcome.awaitingUnknownOutcome
                        ? FloeL10n.l("design.owner.generate_unknown")
                        : FloeL10n.l("design.owner.generate_in_progress")
                    statusNote = nil
                }
            } catch {
                if Task.isCancelled {
                    await refreshCancellationState(idempotencyKey: idempotencyKey)
                    return
                }
                errorMessage = Self.friendly(error)
            }
            return
        }
        do {
            // Recovery: a durable record for this EXACT frozen request already
            // exists. The service reconciles it WITHOUT any provider call — a
            // ready result, or a published result whose `.ready` transition
            // failed (repaired on read through the SAME store row), is bound
            // at its ORIGINAL submission revision from the durable payload;
            // a recorded result whose row/file no longer resolves is the
            // explicit missing-result state; anything else non-terminal is
            // unknown/in-flight and is never resent.
            if let existing = try? await environment.mediaGenerationService
                .recoverDesignCreativeImage(idempotencyKey: idempotencyKey) {
                if existing.resultMissing {
                    generationResultMissing = true
                    generationMissingJobID = existing.job.id
                    generationResultAwaitingBind = false
                    generationUnknownOutcome = false
                    errorMessage = FloeL10n.l("design.owner.generate_result_missing")
                    statusNote = nil
                    return
                }
                switch existing.job.state {
                case .ready:
                    guard let assetID = existing.job.localAssetID else {
                        throw FloeError.storageCorrupted(
                            "the durable generation job is ready without a committed asset")
                    }
                    guard let originalRevision = Self.generationOriginalRevision(
                        from: existing.job.requestJSON) else {
                        // Without the original revision a bind could silently
                        // adopt over an edit: refuse and keep the result.
                        generationResultAwaitingBind = true
                        errorMessage = FloeL10n.l(
                            "design.owner.generate_original_revision_unknown")
                        return
                    }
                    generationUnknownOutcome = false
                    try await bindGeneratedAsset(
                        assetID: assetID,
                        operationID: Self.generationOperationID(jobID: existing.job.id),
                        frozenRevision: originalRevision)
                    return
                case .preparing, .submitted, .running, .completed, .downloading:
                    generationUnknownOutcome = existing.job.providerTaskID == nil
                    generationResultAwaitingBind = false
                    errorMessage = generationUnknownOutcome
                        ? FloeL10n.l("design.owner.generate_unknown")
                        : FloeL10n.l("design.owner.generate_in_progress")
                    statusNote = nil
                    return
                case .failed, .cancelled, .expired:
                    // A definite local terminal state: the explicit confirmed
                    // click may start a NEW durable attempt.
                    break
                }
            }
            let originTask = confirmationOriginConversationID
            let submission = DesignCreativeImageSubmission(
                targetStableKey: target.stableKey,
                ownerID: target.ownerID,
                requestID: target.sourceID,
                environmentID: target.environmentID,
                originConversationID: originTask,
                originRunID: nil,
                owner: Self.mediaJobOwner(
                    originConversationID: originTask,
                    targetStableKey: target.stableKey),
                providerID: confirmation.providerID,
                modelID: confirmation.modelID,
                prompt: confirmation.prompt,
                selection: ImageGenerationSelection(),
                displayNameStem: Self.generatedNameStem(goal: confirmation.goal),
                idempotencyKey: idempotencyKey,
                frozenOwnerRevision: confirmation.frozenOwnerRevision)
            let outcome = try await environment.mediaGenerationService
                .submitDesignCreativeImage(submission)
            if let asset = outcome.asset {
                generationUnknownOutcome = false
                generationResultMissing = false
                generationMissingJobID = nil
                try await bindGeneratedAsset(
                    assetID: asset.id,
                    operationID: Self.generationOperationID(jobID: outcome.job.id),
                    frozenRevision: confirmation.frozenOwnerRevision)
            } else if outcome.resultMissing {
                generationResultMissing = true
                generationMissingJobID = outcome.job.id
                generationResultAwaitingBind = false
                generationUnknownOutcome = false
                errorMessage = FloeL10n.l("design.owner.generate_result_missing")
                statusNote = nil
            } else {
                generationUnknownOutcome = outcome.awaitingUnknownOutcome
                generationResultAwaitingBind = false
                errorMessage = outcome.awaitingUnknownOutcome
                    ? FloeL10n.l("design.owner.generate_unknown")
                    : FloeL10n.l("design.owner.generate_in_progress")
                statusNote = nil
            }
        } catch let workflowError as DesignOwnerWorkflowError {
            if case .ownerConflict = workflowError {
                // The result IS retained (ready job + real asset). The owner
                // moved during generation: never overwrite, never pay twice.
                // The retained result can be bound to the current revision
                // only through the explicit user action below.
                generationResultAwaitingBind = true
                errorMessage = FloeL10n.l("design.owner.generate_conflict")
                return
            }
            errorMessage = Self.friendly(workflowError)
        } catch {
            if Task.isCancelled {
                // Stop-waiting: report the ACTUAL durable job. A cancellation
                // observed before dispatch is durably `.cancelled` (definite,
                // nothing was sent); only a post-dispatch stop is an unknown
                // remote outcome. No refund or price is ever claimed.
                await refreshCancellationState(idempotencyKey: idempotencyKey)
                return
            }
            errorMessage = Self.friendly(error)
        }
    }

    /// After a stop-waiting cancellation, read the durable job and set the
    /// truthful distinct state: `.cancelled` = definite pre-dispatch cancel;
    /// any other non-terminal state = unknown remote outcome (never resent).
    private func refreshCancellationState(idempotencyKey: String) async {
        generationUnknownOutcome = false
        generationResultMissing = false
        generationResultAwaitingBind = false
        generationMissingJobID = nil
        let outcome = try? await environment.mediaGenerationService
            .recoverDesignCreativeImage(idempotencyKey: idempotencyKey)
        guard let outcome else {
            // No durable row exists: the cancel was observed before any
            // submission reached the provider.
            statusNote = FloeL10n.l("design.owner.generate_canceled_confirmed")
            return
        }
        if outcome.asset != nil {
            generationResultAwaitingBind = true
            statusNote = FloeL10n.l("design.owner.generate_ready_to_bind")
        } else if outcome.resultMissing {
            generationResultMissing = true
            generationMissingJobID = outcome.job.id
            errorMessage = FloeL10n.l("design.owner.generate_result_missing")
            statusNote = nil
        } else if outcome.job.state == .cancelled {
            statusNote = FloeL10n.l("design.owner.generate_canceled_confirmed")
        } else if !outcome.job.state.isTerminal {
            generationUnknownOutcome = true
            statusNote = FloeL10n.l("design.owner.generate_stopped_unknown")
        }
    }

    /// Explicit user action for a MISSING published result: opens the SAME
    /// confirmation dialog (actual model/parameters/fee advisory) and, once
    /// accepted, performs ONE acknowledged replacement through the existing
    /// durable job/request service. Never automatic; the stale result id is
    /// not reused.
    func requestReplaceMissingResult() {
        guard generationResultMissing, !busy, !generating else { return }
        generationReplacementPending = true
        requestGenerationConfirmation()
        if generationConfirmation == nil {
            generationReplacementPending = false
        }
    }

    /// First step of the acknowledged discard for a MISSING result: show the
    /// honest warning. Nothing changes until the user confirms.
    func requestDiscardMissingResult() {
        guard generationResultMissing else { return }
        generationMissingDiscardWarning = true
    }

    func dismissMissingDiscardWarning() {
        generationMissingDiscardWarning = false
    }

    /// Confirmed discard of a verified-missing result: closes the dangling
    /// local record with the honest reason; canonical bytes/drafts are
    /// untouched and nothing is resent. A later explicit generation creates a
    /// new durable attempt.
    func confirmDiscardMissingGeneration() async {
        generationMissingDiscardWarning = false
        guard generationResultMissing, let jobID = generationMissingJobID else { return }
        busy = true
        defer { busy = false }
        do {
            try await environment.mediaGenerationService
                .discardMissingDesignCreativeResult(jobID: jobID)
            generationResultMissing = false
            generationMissingJobID = nil
            errorMessage = nil
            statusNote = FloeL10n.l("design.owner.generate_missing_discarded")
        } catch {
            errorMessage = Self.friendly(error)
        }
    }

    /// Explicit resolution of a retained result whose original revision
    /// moved: bind the ready asset to the CURRENT revision after the user
    /// accepted the conflict (never automatic).
    func bindRetainedResultToCurrentRevision() async {
        guard !busy, !generating, generationResultAwaitingBind,
              let request = project?.creativeRequest else { return }
        let currentRevision = envelope?.revision ?? 0
        let key = Self.generationIdempotencyKey(target: target, request: request)
        busy = true
        defer { busy = false }
        do {
            let store = MediaGenerationJobStore(database: environment.database)
            guard let existing = try? await store.ownedJob(idempotencyKey: key),
                  existing.job.state == .ready,
                  let assetID = existing.job.localAssetID else {
                throw FloeError.validationFailed(
                    FloeL10n.l("design.owner.generate_ready_result_missing"))
            }
            try await bindGeneratedAsset(
                assetID: assetID,
                operationID: Self.generationOperationID(jobID: existing.job.id),
                frozenRevision: currentRevision)
        } catch let workflowError as DesignOwnerWorkflowError {
            if case .ownerConflict = workflowError {
                generationResultAwaitingBind = true
                errorMessage = FloeL10n.l("design.owner.generate_conflict")
                return
            }
            errorMessage = Self.friendly(workflowError)
        } catch {
            errorMessage = Self.friendly(error)
        }
    }

    /// The current model is displayed BEFORE the first call.
    static func modelTitle(_ model: ModelProfile) -> String {
        let name = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? model.remoteModelID : "\(name) (\(model.remoteModelID))"
    }

    /// Human-readable resolved parameters, or the honest provider-defaults
    /// note when the user made no explicit selection.
    static func parametersSummary(_ selection: ImageGenerationSelection) -> String {
        var parts: [String] = []
        if let value = selection.aspectRatio { parts.append("aspectRatio=\(value)") }
        if let value = selection.resolution { parts.append("resolution=\(value)") }
        if let value = selection.quality { parts.append("quality=\(value)") }
        if let value = selection.nativeSizeOverride { parts.append("size=\(value)") }
        return parts.isEmpty
            ? FloeL10n.l("design.owner.generation_confirm_defaults")
            : parts.joined(separator: ", ")
    }

    /// Image confirmation NEVER advertises an amount from the model profile's
    /// ordinary text token pricing (`inputPerMillion`/`outputPerMillion`):
    /// that metadata is not verified per-image billing and has no image unit,
    /// so presenting it would fabricate a price. No image-specific pricing
    /// provenance exists today; this returns nil and the dialog states only
    /// that the configured provider may charge. A real verified image price
    /// would be surfaced here once such provenance/unit exists.
    static func costSummary(for model: ModelProfile) -> String? {
        nil
    }

    /// The ORIGINAL owner revision recorded at submission time on the durable
    /// job payload. nil means the record is unreadable: the caller must not
    /// bind (a current revision would silently adopt over edits).
    static func generationOriginalRevision(from payload: Data) -> Int64? {
        (try? JSONDecoder().decode(
            DesignCreativeImageRequestPayload.self, from: payload))?
            .frozenOwnerRevision
    }

    /// Binds one verified, already-committed creative asset as the creative
    /// request's first result through the SAME `bindFirstResult` the agent
    /// tool uses. The asset bytes are re-read with the shared bounded reader
    /// and digest-verified against the store record.
    private func bindGeneratedAsset(
        assetID: UUID, operationID: String, frozenRevision: Int64
    ) async throws {
        let resolved = try await AppCreativeDocumentPort.resolveVerifiedAssetBytes(
            assetStore: environment.creativeAssetStore,
            artifactRoot: { try FloeArtifactStore.root() },
            creationID: assetID.uuidString)
        let outcome = try await environment.designOwnerWorkflow.bindFirstResult(
            target: target,
            operationID: operationID,
            expectedOwnerRevision: frozenRevision,
            bytes: resolved.data,
            format: resolved.format,
            displayName: resolved.displayName,
            boundResultID: assetID.uuidString)
        envelope = outcome.envelope
        generationResultAwaitingBind = false
        generationUnknownOutcome = false
        generationResultMissing = false
        generationMissingJobID = nil
        errorMessage = nil
        statusNote = FloeL10n.l("design.owner.creative_generated")
    }

    func cancelGeneration() {
        generationTask?.cancel()
        generationTask = nil
    }

    /// First step of the ACKNOWLEDGED discard: show the duplicate-charge
    /// warning. No job state changes until the user confirms.
    func requestDiscardUnknownGeneration() {
        guard generationUnknownOutcome else { return }
        generationDiscardWarning = true
    }

    func dismissDiscardWarning() {
        generationDiscardWarning = false
    }

    /// Confirmed discard: closes the LOCAL unresolved record with an honest
    /// reason (the provider may still have generated/charged). This is the
    /// only way an unknown submission is ever abandoned — never automatic.
    func confirmDiscardUnknownGeneration() async {
        generationDiscardWarning = false
        guard generationUnknownOutcome,
              let request = project?.creativeRequest else { return }
        let key = Self.generationIdempotencyKey(target: target, request: request)
        do {
            let store = MediaGenerationJobStore(database: environment.database)
            guard let existing = try? await store.ownedJob(idempotencyKey: key) else {
                generationUnknownOutcome = false
                return
            }
            if !existing.job.state.isTerminal {
                try await environment.mediaGenerationService
                    .discardUnknownDesignCreativeImage(jobID: existing.job.id)
            }
            generationUnknownOutcome = false
            errorMessage = nil
            statusNote = FloeL10n.l("design.owner.generate_unknown_discarded")
        } catch {
            errorMessage = Self.friendly(error)
        }
    }

    /// Frozen operation identity for one submitting request: reconstructible
    /// from durable state only (target identity + request creation time), so
    /// closing/reopening finds the SAME original job.
    static func generationIdempotencyKey(
        target: DesignTarget, request: DesignCreativeRequest
    ) -> String {
        // The creative request is persisted inside the owner envelope with
        // ISO-8601 SECOND precision. The key must therefore be computed at
        // whole-second granularity: a millisecond timestamp would differ
        // after a reload, lose the durable job link, and make a reopen
        // dispatch a second paid generation. Both the submitting and the
        // reloading side use this same function.
        let seconds = Int64(request.createdAt.timeIntervalSince1970)
        return "design-creative-image|\(target.stableKey)|\(seconds)"
    }

    /// Deterministic bind operation id per durable job: recovery binds the
    /// same job exactly once, and a replay returns the recorded revision.
    static func generationOperationID(jobID: UUID) -> String {
        "ui-creative-generate-\(jobID.uuidString.lowercased())"
    }

    /// The durable job owner: the originating task when one exists, otherwise
    /// a deterministic design-request identity derived from the frozen target
    /// stable key (no parallel store, no random owner per launch).
    static func mediaJobOwner(
        originConversationID: UUID?, targetStableKey: String
    ) -> MediaJobOwner {
        if let task = originConversationID { return .conversation(task) }
        return .document(deterministicJobOwnerID(targetStableKey: targetStableKey))
    }

    static func deterministicJobOwnerID(targetStableKey: String) -> UUID {
        var hex = targetStableKey.lowercased()
        hex = String(hex.prefix(32))
        if hex.count < 32 { hex += String(repeating: "0", count: 32 - hex.count) }
        let formatted = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))"
            + "-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))"
            + "-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: formatted) ?? UUID()
    }

    static func generatedNameStem(goal: String) -> String {
        let stem = goal.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .prefix(4)
            .joined(separator: "-")
        return String(stem.prefix(32))
    }

    static func generationPrompt(
        goal: String, audience: String?, spec: DesignSpec?, kind: DesignContentType
    ) -> String {
        var lines: [String] = [goal]
        if let audience, !audience.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Audience: \(audience)")
        }
        if let raw = spec?.rawMarkdown, !raw.isEmpty {
            lines.append("Design spec:\n\(raw)")
        }
        if let palette = spec?.palette, !palette.isEmpty {
            lines.append("Palette: \(palette.joined(separator: ", "))")
        }
        if let typography = spec?.typography, !typography.isEmpty {
            lines.append("Typography: \(typography)")
        }
        return lines.joined(separator: "\n")
    }

    func saveBrief(goal: String, audience: String) async {
        guard !busy else { return }
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            envelope = try await environment.designOwnerWorkflow.updateBrief(
                target: target,
                operationID: operationID("brief"),
                expectedOwnerRevision: envelope?.revision,
                brief: DesignBrief(
                    goal: trimmedGoal,
                    audience: audience.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil : audience))
            errorMessage = nil
            statusNote = FloeL10n.l("design.owner.brief_saved")
        } catch {
            errorMessage = Self.friendly(error)
        }
    }

    func saveSpec(rawMarkdown: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            var spec = project?.spec ?? DesignSpec()
            let trimmed = rawMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            spec.rawMarkdown = trimmed.isEmpty ? nil : rawMarkdown
            envelope = try await environment.designOwnerWorkflow.updateSpec(
                target: target,
                operationID: operationID("spec"),
                expectedOwnerRevision: envelope?.revision,
                spec: spec)
            errorMessage = nil
            statusNote = FloeL10n.l("design.owner.spec_saved")
        } catch {
            errorMessage = Self.friendly(error)
        }
    }

    func beginCreativeRequest(goal: String, audience: String) async {
        guard !busy, target.kind == .creativeDocument else { return }
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGoal.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            let outcome = try await environment.designOwnerWorkflow.beginCreativeRequest(
                target: target,
                operationID: operationID("creative-start"),
                expectedOwnerRevision: envelope?.revision,
                brief: DesignBrief(
                    goal: trimmedGoal,
                    audience: audience.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil : audience))
            envelope = outcome.envelope
            DesignCreativeRequestStore.remember(target)
            await loadBindableCreativeAssets()
            errorMessage = nil
            statusNote = FloeL10n.l("design.owner.creative_request_saved")
        } catch {
            errorMessage = Self.friendly(error)
        }
    }

    func freezeInput() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let outcome = try await environment.designOwnerWorkflow.freezeInput(
                target: target,
                operationID: operationID("freeze"),
                expectedOwnerRevision: envelope?.revision,
                artifactID: currentArtifact?.id,
                displayName: resolvedSource?.displayName)
            envelope = outcome.envelope
            resolvedSource = outcome.source
            errorMessage = nil
            statusNote = FloeL10n.l("design.owner.frozen")
        } catch {
            errorMessage = Self.friendly(error)
        }
    }

    /// Trusted-UI concrete confirmation for the assistant's `design.adopt`:
    ///
    /// 1. an exact single-use grant is minted through the SAME
    ///    `DesignOwnerAuthorization` instance the registered tool consumes;
    /// 2. a structured confirmation event (target/candidate/base/proposed/
    ///    mode/grant/expiry) is durably DELIVERED to the FROZEN originating
    ///    task through the existing ConversationCenter ingress;
    /// 3. only after that durable write does the UI claim the assistant was
    ///    notified. A failed delivery surfaces an error and never arms the
    ///    transient note; clicking again retries.
    ///
    /// A repeated click for the SAME candidate/mode while the minted grant is
    /// still live reuses that grant and re-delivers the SAME event id
    /// (idempotent upsert): the confirmation is neither lost nor duplicated.
    /// The grant store is process-local, so after an app restart the model
    /// must obtain a fresh confirmation — the recorded event stays historical.
    func authorizeAssistantAdoption(_ candidateID: String, mode: DesignAdoptMode) async {
        guard !busy, let candidate = project?.candidate(candidateID) else { return }
        guard let origin = confirmationOriginConversationID else {
            errorMessage = FloeL10n.l("design.owner.authorize_no_origin")
            return
        }
        busy = true
        defer { busy = false }
        let baselineRevisionID = candidate.baseRevisionID
        let proposedRevisionID = candidate.proposedRevisionID
        // Reuse an exact, still-live confirmation instead of minting a second
        // grant for the same frozen operation.
        if let existing = authorizedAssistantAdoption,
           existing.candidateID == candidateID,
           existing.mode == mode,
           existing.expiresAt > Date(),
           await environment.designOwnerAdoptionGrants.validateOwnerAdoption(
                grantID: existing.grantID,
                targetStableKey: target.stableKey,
                candidateID: candidateID,
                baselineRevisionID: baselineRevisionID,
                proposedRevisionID: proposedRevisionID,
                mode: mode,
                scope: .aiTool) {
            do {
                guard let grantUUID = UUID(uuidString: existing.grantID) else {
                    throw FloeError.validationFailed(
                        "the confirmation service returned an invalid grant identity")
                }
                try await deliverAssistantConfirmation(
                    origin: origin,
                    candidateID: candidateID,
                    baselineRevisionID: baselineRevisionID,
                    proposedRevisionID: proposedRevisionID,
                    mode: mode,
                    grantID: grantUUID,
                    expiresAt: existing.expiresAt)
                errorMessage = nil
                statusNote = FloeL10n.l("design.owner.authorized_note")
            } catch {
                errorMessage = Self.friendly(error)
            }
            return
        }
        let ttl: TimeInterval = 300
        let expiresAt = Date().addingTimeInterval(ttl)
        let grantID = await environment.designOwnerAdoptionGrants.issueOwnerAdoption(
            targetStableKey: target.stableKey,
            candidateID: candidateID,
            baselineRevisionID: baselineRevisionID,
            proposedRevisionID: proposedRevisionID,
            mode: mode,
            scope: .aiTool,
            ttl: ttl)
        do {
            guard let grantUUID = UUID(uuidString: grantID) else {
                throw FloeError.validationFailed(
                    "the confirmation service returned an invalid grant identity")
            }
            try await deliverAssistantConfirmation(
                origin: origin,
                candidateID: candidateID,
                baselineRevisionID: baselineRevisionID,
                proposedRevisionID: proposedRevisionID,
                mode: mode,
                grantID: grantUUID,
                expiresAt: expiresAt)
            authorizedAssistantAdoption = AssistantAdoptionAuthorization(
                candidateID: candidateID, mode: mode,
                grantID: grantID, expiresAt: expiresAt)
            errorMessage = nil
            statusNote = FloeL10n.l("design.owner.authorized_note")
        } catch {
            // The grant was minted but the task was NOT notified: never arm
            // the transient "assistant authorized" state. The un-delivered
            // grant expires unused (nobody holds its id) and the user can
            // retry, which mints a fresh single-use confirmation.
            errorMessage = Self.friendly(error)
        }
    }

    /// The ONE durable-delivery call: a structured confirmation event to the
    /// frozen originating task. THROWS when persistence fails so the caller
    /// cannot claim the assistant was notified.
    private func deliverAssistantConfirmation(
        origin: UUID,
        candidateID: String,
        baselineRevisionID: String,
        proposedRevisionID: String,
        mode: DesignAdoptMode,
        grantID: UUID,
        expiresAt: Date
    ) async throws {
        guard let candidateUUID = UUID(uuidString: candidateID) else {
            throw FloeError.validationFailed(
                "candidate id is not a deliverable identity")
        }
        try await environment.conversationCenter.recordDesignAssistantConfirmation(
            conversationID: origin,
            targetStableKey: target.stableKey,
            candidateID: candidateUUID,
            baselineRevisionID: baselineRevisionID,
            proposedRevisionID: proposedRevisionID,
            mode: mode,
            grantID: grantID,
            grantExpiresAt: expiresAt)
    }

    func compare(_ candidateID: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            comparison = try await environment.designOwnerWorkflow.compare(
                target: target, candidateID: candidateID)
            errorMessage = nil
        } catch {
            errorMessage = Self.friendly(error)
        }
    }

    func adopt(_ candidateID: String, mode: DesignAdoptMode) async {
        guard !busy, let revision = envelope?.revision else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await environment.designOwnerWorkflow.adopt(
                target: target,
                operationID: operationID("adopt"),
                expectedOwnerRevision: revision,
                candidateID: candidateID,
                mode: mode,
                runID: nil,
                verifyReopen: DesignOwnerWorkflowFactory.verifier(
                    adapters: environment.designAdapterCenter))
            envelope = result.envelope
            errorMessage = nil
            statusNote = Self.adoptionNote(result)
        } catch {
            errorMessage = Self.friendly(error)
        }
    }

    func reject(_ candidateID: String) async {
        guard !busy, let revision = envelope?.revision else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await environment.designOwnerWorkflow.reject(
                target: target,
                operationID: operationID("reject"),
                expectedOwnerRevision: revision,
                candidateID: candidateID)
            envelope = result.envelope
            errorMessage = nil
            statusNote = Self.adoptionNote(result)
        } catch {
            errorMessage = Self.friendly(error)
        }
    }

    func addFeedback(_ comment: String) async {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !trimmed.isEmpty, let artifact = currentArtifact else { return }
        busy = true
        defer { busy = false }
        do {
            let outcome = try await environment.designOwnerWorkflow.addFeedback(
                target: target,
                operationID: operationID("feedback"),
                expectedOwnerRevision: envelope?.revision,
                artifactID: artifact.id,
                revisionID: artifact.currentRevisionID,
                anchor: .region(x: 0, y: 0, width: 1, height: 1),
                comment: trimmed,
                author: .user)
            envelope = outcome.envelope
            errorMessage = nil
            statusNote = FloeL10n.l("design.owner.feedback_saved")
        } catch {
            errorMessage = Self.friendly(error)
        }
    }

    func resolveFeedback(_ feedbackID: String) async {
        guard !busy, let artifact = currentArtifact,
              let current = artifact.currentRevisionID else { return }
        busy = true
        defer { busy = false }
        do {
            envelope = try await environment.designOwnerWorkflow.resolveFeedback(
                target: target,
                operationID: operationID("resolve-feedback"),
                expectedOwnerRevision: envelope?.revision,
                feedbackID: feedbackID,
                resolvedByRevisionID: current)
            errorMessage = nil
            statusNote = FloeL10n.l("design.owner.feedback_resolved")
        } catch {
            errorMessage = Self.friendly(error)
        }
    }

    func relocateAnchor(_ feedbackID: String) async {
        guard !busy, let artifact = currentArtifact else { return }
        busy = true
        defer { busy = false }
        do {
            envelope = try await environment.designOwnerWorkflow.relocateAnchor(
                target: target,
                operationID: operationID("relocate-feedback"),
                expectedOwnerRevision: envelope?.revision,
                feedbackID: feedbackID,
                anchor: .region(x: 0, y: 0, width: 1, height: 1),
                toRevisionID: artifact.currentRevisionID)
            errorMessage = nil
            statusNote = FloeL10n.l("design.owner.feedback_relocated")
        } catch {
            errorMessage = Self.friendly(error)
        }
    }

    /// Verified export: retained bytes + digest re-check + the owner's REAL
    /// reopen parser. Returns nil (with an honest error) when verification
    /// cannot run.
    func exportVerified() async -> (data: Data, format: String)? {
        guard !busy, let artifact = currentArtifact,
              let revisionID = artifact.currentRevisionID else { return nil }
        busy = true
        defer { busy = false }
        do {
            let data = try await environment.designOwnerWorkflow.exportVerified(
                target: target,
                artifactID: artifact.id,
                revisionID: revisionID,
                verifyReopen: DesignOwnerWorkflowFactory.verifier(
                    adapters: environment.designAdapterCenter))
            let format = artifact.revision(revisionID)?.payloadFormat ?? "bin"
            errorMessage = nil
            statusNote = FloeL10n.l("design.owner.export_verified")
            return (data, format)
        } catch {
            errorMessage = Self.friendly(error)
            return nil
        }
    }

    private static func adoptionNote(_ result: DesignOwnerWorkflow.DecisionResult) -> String {
        if result.replayed {
            return FloeL10n.l("design.owner.decision_replayed")
        }
        switch result.publication {
        case .published(let receipt):
            return FloeL10n.l("design.owner.published", receipt.destination)
        case .pending(let reason):
            return FloeL10n.l("design.owner.publication_pending", reason)
        case .notRequired(let reason):
            if result.delivery.isDelivered {
                return FloeL10n.l("design.owner.adopted_delivered")
            }
            return FloeL10n.l("design.owner.adopted_delivery_pending", reason)
        }
    }

    /// User-facing error mapping: never surface raw UUIDs/paths or service
    /// internals in the normal flow; the stable reason token remains in logs.
    static func friendly(_ error: Error) -> String {
        if let targetError = error as? DesignTargetError {
            switch targetError {
            case .unsupportedKind: return FloeL10n.l("design.owner.error.unsupported")
            case .notAuthorized: return FloeL10n.l("design.owner.error.not_authorized")
            case .notFound: return FloeL10n.l("design.owner.error.not_found")
            case .invalidReference: return FloeL10n.l("design.owner.error.invalid_reference")
            case .unverifiable: return FloeL10n.l("design.owner.error.unverifiable")
            case .unavailable(let reason): return reason
            case .moved: return FloeL10n.l("design.owner.error.moved")
            case .pendingFirstResult: return FloeL10n.l("design.owner.error.pending_first_result")
            case .firstResultAlreadyBound: return FloeL10n.l("design.owner.error.first_result_bound")
            }
        }
        if let workflowError = error as? DesignOwnerWorkflowError {
            switch workflowError {
            case .ownerConflict:
                return FloeL10n.l("design.owner.error.conflict")
            case .replayMismatch:
                return FloeL10n.l("design.owner.error.replayed_different")
            case .missingPayload:
                return FloeL10n.l("design.owner.error.missing_payload")
            case .notInPlaceOwner:
                return FloeL10n.l("design.owner.error.not_in_place")
            case .deletedSource:
                return FloeL10n.l("design.owner.error.not_found")
            case .adoptionPendingRecovery:
                return FloeL10n.l("design.owner.error.pending_recovery")
            case .canvasRequiresCanvasAuthority:
                return FloeL10n.l("design.owner.canvas_authority")
            case .resultPublicationUnavailable:
                return FloeL10n.l("design.owner.error.publication_unavailable")
            }
        }
        return FloeL10n.l("design.owner.error.generic")
    }
}

/// Exact verified bytes handed to the system file exporter.
private struct DesignOwnerExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct DesignOwnerExportItem: Identifiable {
    let id = UUID()
    let document: DesignOwnerExportDocument
    let filename: String
}

/// Human, localized labels for the persisted routing enums shown in the
/// design panels. Raw enum values are durable identifiers for storage and
/// routing, never ordinary UI copy; an unknown future case falls back to its
/// token instead of rendering a dotted catalog key.
private enum DesignOwnerLabels {
    static func ownerKind(_ kind: DesignTargetKind) -> String {
        localizedOrToken("design.owner.kind.\(kind.rawValue)", token: kind.rawValue)
    }

    static func outputType(_ kind: DesignContentType) -> String {
        localizedOrToken("design.panel.type.\(kind.rawValue)", token: kind.rawValue)
    }

    static func revisionOrigin(_ origin: DesignRevisionOrigin) -> String {
        localizedOrToken(
            "design.owner.revision_origin.\(origin.rawValue)", token: origin.rawValue)
    }

    /// The capability registry reports English build-routing reasons. Normal
    /// panel copy is localized and actionable, and the raw service string is
    /// never shown as an ordinary description. Every known category maps to a
    /// localized note; an unknown reason keeps the honest generic
    /// "not connected" statement, so a failure is still surfaced and never
    /// converted into an available route.
    static func generationUnavailableReason(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else {
            return FloeL10n.l("design.owner.generate_unavailable_not_connected")
        }
        if raw.hasPrefix("Image generation needs a configured image model") {
            return FloeL10n.l("design.owner.generate_unavailable_model")
        }
        return FloeL10n.l("design.owner.generate_unavailable_not_connected")
    }

    private static func localizedOrToken(_ key: String, token: String) -> String {
        let value = FloeL10n.l(key)
        return value == key ? token : value
    }
}

/// The shared collapsible owner panel: one surface for the approval stages of
/// a file document, chat attachment or creative request. Canvas nodes use the
/// existing `DesignWorkflowPanel` (the canvas authority path).
struct DesignOwnerWorkflowSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: DesignOwnerWorkflowModel

    @State private var briefGoal = ""
    @State private var briefAudience = ""
    @State private var specText = ""
    @State private var feedbackDraft = ""
    @State private var exportItem: DesignOwnerExportItem?
    @State private var loadedRevision: Int64?

    init(target: DesignTarget, environment: AppEnvironment) {
        _model = StateObject(wrappedValue: DesignOwnerWorkflowModel(
            target: target, environment: environment))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error = model.errorMessage {
                    Section {
                        HStack(alignment: .top) {
                            Text(error).foregroundStyle(FloeTheme.destructive)
                            Spacer()
                        }
                        .accessibilityIdentifier("design.owner.error")
                    }
                }
                if let note = model.statusNote {
                    Section {
                        Label(note, systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("design.owner.statusNote")
                    }
                }
                sourceSection
                if model.target.kind == .creativeDocument {
                    // Stages: request (one goal/audience editor + Save
                    // request) → spec → first result → revisions/candidates/
                    // feedback. Before the request exists the request editor
                    // owns goal/audience, so the standalone brief editor is
                    // suppressed; after the request is saved (also while the
                    // first result is pending) brief and spec stay editable.
                    // Freezing is owned by the first-result bind while the
                    // request is still awaiting its result.
                    creativeRequestSection
                    if !model.isCreativeRequestUncreated {
                        briefSection
                    }
                    specSection
                    if !model.isCreativeAwaitingFirstResult {
                        frozenSection
                    }
                } else {
                    briefSection
                    specSection
                    frozenSection
                }
                artifactsSection
                candidatesSection
                feedbackSection
            }
            .navigationTitle("design.owner.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.close") { dismiss() }
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await model.reload() }
                    } label: {
                        if model.busy { ProgressView() } else { Text("design.owner.reload") }
                    }
                    .disabled(model.busy)
                    .accessibilityIdentifier("design.owner.reload")
                }
            }
            .task {
                await model.reload()
                loadFieldsIfNeeded(force: loadedRevision == nil)
            }
            .onChange(of: model.envelope?.revision) { _, _ in
                loadFieldsIfNeeded(force: false)
            }
        }
        .fileExporter(
            isPresented: Binding(
                get: { exportItem != nil },
                set: { presented in if !presented { exportItem = nil } }
            ),
            document: exportItem?.document,
            contentType: .data,
            defaultFilename: exportItem?.filename ?? "design-export"
        ) { _ in exportItem = nil }
        // The user must accept the ACTUAL configured model, inputs,
        // parameters and (only when published) possible cost BEFORE the
        // first provider call.
        .confirmationDialog(
            "design.owner.generation_confirm_title",
            isPresented: Binding(
                get: { model.generationConfirmation != nil },
                set: { presented in
                    if !presented { model.dismissGenerationConfirmation() }
                }),
            titleVisibility: .visible
        ) {
            Button("design.owner.generation_confirm_button") {
                model.startConfirmedGeneration()
            }
            .accessibilityIdentifier("design.owner.generationConfirm")
            Button("action.cancel", role: .cancel) {
                model.dismissGenerationConfirmation()
            }
        } message: {
            if let confirmation = model.generationConfirmation {
                Text(Self.confirmationDetails(confirmation))
            }
        }
        // Acknowledged discard: the remote outcome is unknown and a new
        // attempt may be charged twice. No state changes until confirmed.
        .confirmationDialog(
            "design.owner.discard_unknown_title",
            isPresented: Binding(
                get: { model.generationDiscardWarning },
                set: { presented in
                    if !presented { model.dismissDiscardWarning() }
                }),
            titleVisibility: .visible
        ) {
            Button("design.owner.discard_unknown_confirm", role: .destructive) {
                Task { await model.confirmDiscardUnknownGeneration() }
            }
            .accessibilityIdentifier("design.owner.discardUnknownConfirm")
            Button("action.cancel", role: .cancel) {
                model.dismissDiscardWarning()
            }
        } message: {
            Text("design.owner.discard_unknown_warning")
        }
        // Acknowledged discard of a verified-MISSING result: closes the
        // dangling local record; a later explicit generation is a new attempt.
        .confirmationDialog(
            "design.owner.discard_missing_title",
            isPresented: Binding(
                get: { model.generationMissingDiscardWarning },
                set: { presented in
                    if !presented { model.dismissMissingDiscardWarning() }
                }),
            titleVisibility: .visible
        ) {
            Button("design.owner.discard_missing_confirm", role: .destructive) {
                Task { await model.confirmDiscardMissingGeneration() }
            }
            .accessibilityIdentifier("design.owner.discardMissingConfirm")
            Button("action.cancel", role: .cancel) {
                model.dismissMissingDiscardWarning()
            }
        } message: {
            Text("design.owner.discard_missing_warning")
        }
    }

    /// Frozen details shown for acceptance before the first call: actual
    /// model, upload/input scope, resolved parameters, and an honest fee
    /// advisory. No per-image amount is shown unless verified image-specific
    /// pricing provenance exists (it does not today); token pricing is never
    /// presented as an image price.
    private static func confirmationDetails(
        _ confirmation: GenerationConfirmationRequest
    ) -> String {
        var lines = [
            FloeL10n.l("design.owner.generation_confirm_model", confirmation.modelTitle),
            FloeL10n.l("design.owner.generation_confirm_inputs"),
            FloeL10n.l(
                "design.owner.generation_confirm_parameters",
                confirmation.parametersSummary)
        ]
        if let cost = confirmation.costSummary {
            lines.append(FloeL10n.l("design.owner.generation_confirm_cost", cost))
        }
        lines.append(FloeL10n.l("design.owner.generation_confirm_fees"))
        return lines.joined(separator: "\n")
    }

    // MARK: Sections

    private var sourceSection: some View {
        Section("design.owner.source") {
            if let source = model.resolvedSource {
                LabeledContent("design.owner.source_name", value: source.displayName)
                LabeledContent("design.owner.source_format", value: source.format)
                Label {
                    Text(source.allowsInPlaceUpdate
                         ? "design.owner.source_in_place"
                         : "design.owner.source_read_only")
                } icon: {
                    Image(systemName: source.allowsInPlaceUpdate ? "square.and.pencil" : "lock")
                }
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
            } else if let reason = model.sourceUnavailableReason {
                Text(reason).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            LabeledContent(
                "design.owner.owner_kind",
                value: DesignOwnerLabels.ownerKind(model.target.kind))
                .font(FloeTheme.Typography.metadata)
        }
    }

    @ViewBuilder
    private var creativeRequestSection: some View {
        if let request = model.project?.creativeRequest {
            switch request.state {
            case .awaitingFirstResult:
                Section {
                    Label("design.owner.creative_awaiting", systemImage: "hourglass")
                    Text(FloeL10n.l(
                        "design.owner.creative_awaiting.detail",
                        DesignOwnerLabels.outputType(request.requestedKind)))
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                    // REAL generation route: offered only when the requested
                    // output kind really has a connected generation
                    // capability. Otherwise the honest reason is shown and no
                    // button pretends to generate.
                    if model.generationAvailable {
                        if model.generationResultMissing {
                            // The recorded result no longer resolves on this
                            // device: explicit recovery only — replace with an
                            // acknowledged new generation, or discard the
                            // dangling record. Never automatic, never a bind
                            // from the stale id.
                            Text("design.owner.generate_result_missing")
                                .font(FloeTheme.Typography.metadata)
                                .foregroundStyle(FloeTheme.pending)
                                .accessibilityIdentifier("design.owner.generateResultMissing")
                            HStack(spacing: 10) {
                                Button("design.owner.replace_missing_result") {
                                    model.requestReplaceMissingResult()
                                }
                                .disabled(model.busy || model.generating)
                                .accessibilityIdentifier("design.owner.replaceMissingResult")
                                Button("design.owner.discard_missing_result", role: .destructive) {
                                    model.requestDiscardMissingResult()
                                }
                                .disabled(model.busy || model.generating)
                                .accessibilityIdentifier("design.owner.discardMissingResult")
                            }
                        } else if model.generationUnknownOutcome {
                            // An earlier submission's remote outcome is
                            // unknown: never resubmitted automatically.
                            Text("design.owner.generate_unknown")
                                .font(FloeTheme.Typography.metadata)
                                .foregroundStyle(FloeTheme.pending)
                                .accessibilityIdentifier("design.owner.generateUnknown")
                            Button("design.owner.generate_discard_unknown", role: .destructive) {
                                model.requestDiscardUnknownGeneration()
                            }
                            .disabled(model.busy)
                            .accessibilityIdentifier("design.owner.discardUnknownGeneration")
                        } else {
                            // The confirmation dialog shows the actual model,
                            // parameters and (when published) cost BEFORE any
                            // provider call.
                            Button("design.owner.generate_first_result") {
                                model.requestGenerationConfirmation()
                            }
                            .disabled(model.busy || model.generating)
                            .accessibilityIdentifier("design.owner.generateFirstResult")
                            if model.generating {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text("design.owner.generating")
                                        .font(FloeTheme.Typography.metadata)
                                        .foregroundStyle(.secondary)
                                    Button("design.owner.cancel_generation") {
                                        model.cancelGeneration()
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("design.owner.cancelGeneration")
                                }
                                .accessibilityIdentifier("design.owner.generating")
                            }
                        }
                        if model.generationResultAwaitingBind {
                            Text("design.owner.generate_ready_to_bind")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("design.owner.generateReadyToBind")
                            // Explicit resolution: bind the retained result to
                            // the CURRENT revision after the user accepted a
                            // conflict. Never automatic.
                            Button("design.owner.bind_retained_current") {
                                Task { await model.bindRetainedResultToCurrentRevision() }
                            }
                            .disabled(model.busy || model.generating)
                            .accessibilityIdentifier("design.owner.bindRetainedToCurrent")
                        }
                    } else if let reason = model.generationUnavailableReason {
                        // The reason is already a localized, standalone
                        // explanation of the real capability limit (for image
                        // output, how to configure a model). The raw service
                        // string never reaches ordinary copy.
                        Text(reason)
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("design.owner.generateUnavailable")
                    }
                    // REAL import path: an existing verified library asset of
                    // the requested kind. The generation path uses the SAME
                    // bindFirstResult.
                    if model.bindableCreativeAssets.isEmpty {
                        Text("design.owner.creative_bind_empty")
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("design.owner.creative_bind_hint")
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                        ForEach(model.bindableCreativeAssets) { asset in
                            Button {
                                Task { await model.bindFirstExistingResult(asset) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(asset.displayName)
                                    if let relative = asset.localRelativePath {
                                        Text(relative)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .disabled(model.busy)
                            .accessibilityIdentifier("design.owner.bindFirstResult.\(asset.id.uuidString)")
                        }
                    }
                } header: {
                    Text("design.owner.creative_request")
                }
            case .firstResultBound:
                Section("design.owner.creative_request") {
                    Label("design.owner.creative_bound", systemImage: "checkmark.seal")
                    if let hash = request.boundContentSHA256 {
                        LabeledContent("design.owner.content_hash", value: String(hash.prefix(12)))
                            .font(FloeTheme.Typography.metadata)
                    }
                }
            }
        } else {
            Section {
                if let kind = model.target.requestedOutputKind {
                    LabeledContent(
                        "design.owner.requested_output_type",
                        value: DesignOwnerLabels.outputType(kind))
                        .font(FloeTheme.Typography.metadata)
                }
                DesignBriefFields(
                    goal: $briefGoal, audience: $briefAudience,
                    goalLabel: "design.owner.brief_goal",
                    audienceLabel: "design.owner.brief_audience",
                    goalIdentifier: "design.owner.creativeGoal",
                    audienceIdentifier: "design.owner.creativeAudience")
                Button("design.owner.creative_start") {
                    Task { await model.beginCreativeRequest(goal: briefGoal, audience: briefAudience) }
                }
                .disabled(model.busy || briefGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("design.owner.creativeStart")
            } header: {
                Text("design.owner.creative_request")
            } footer: {
                Text("design.owner.creative_footer")
            }
        }
    }

    private var briefSection: some View {
        Section("design.owner.brief") {
            DesignBriefFields(
                goal: $briefGoal, audience: $briefAudience,
                goalLabel: "design.owner.brief_goal",
                audienceLabel: "design.owner.brief_audience",
                goalIdentifier: "design.owner.briefGoal",
                audienceIdentifier: "design.owner.briefAudience")
            Button("design.owner.save_brief") {
                Task { await model.saveBrief(goal: briefGoal, audience: briefAudience) }
            }
            .disabled(model.busy || briefGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("design.owner.saveBrief")
        }
    }

    private var specSection: some View {
        Section {
            DesignSpecField(
                label: "design.owner.spec", text: $specText,
                lineLimit: 2...8,
                identifier: "design.owner.spec")
            Button("design.owner.save_spec") {
                Task { await model.saveSpec(rawMarkdown: specText) }
            }
            .disabled(model.busy)
            .accessibilityIdentifier("design.owner.saveSpec")
        } header: {
            Text("design.owner.spec_header")
        } footer: {
            Text("design.owner.spec_footer")
        }
    }

    @ViewBuilder
    private var frozenSection: some View {
        Section("design.owner.frozen") {
            if let frozen = model.project?.frozenRun {
                LabeledContent("design.owner.frozen_input",
                               value: frozen.inputRevisionID.map { String($0.prefix(12)) } ?? "—")
                    .font(FloeTheme.Typography.metadata)
                LabeledContent("design.owner.frozen_spec",
                               value: frozen.specSHA256.map { String($0.prefix(12)) } ?? "—")
                    .font(FloeTheme.Typography.metadata)
                LabeledContent("design.owner.frozen_target",
                               value: frozen.targetRevisionID.map { String($0.prefix(12)) } ?? "—")
                    .font(FloeTheme.Typography.metadata)
                Text("design.owner.frozen_note")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            } else {
                Text("design.owner.not_frozen")
                    .foregroundStyle(.secondary)
                Button("design.owner.freeze") {
                    Task { await model.freezeInput() }
                }
                .disabled(model.busy || model.resolvedSource == nil)
                .accessibilityIdentifier("design.owner.freeze")
            }
        }
    }

    @ViewBuilder
    private var artifactsSection: some View {
        if let artifact = model.currentArtifact {
            Section("design.owner.revisions") {
                LabeledContent("design.owner.current_revision",
                               value: artifact.currentRevisionID.map { String($0.prefix(12)) } ?? "—")
                    .font(FloeTheme.Typography.metadata)
                ForEach(artifact.revisions.suffix(5)) { revision in
                    HStack {
                        Text("#\(revision.number) · \(DesignOwnerLabels.revisionOrigin(revision.origin))")
                            .font(FloeTheme.Typography.metadata)
                        Spacer()
                        Text(String(revision.contentSHA256.prefix(10)))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Button("design.owner.export_verified") {
                    Task {
                        guard let result = await model.exportVerified() else { return }
                        exportItem = DesignOwnerExportItem(
                            document: DesignOwnerExportDocument(data: result.data),
                            filename: "design-\(DesignOwnerLabels.ownerKind(model.target.kind)).\(result.format)")
                    }
                }
                .disabled(model.busy || artifact.currentRevisionID == nil)
                .accessibilityIdentifier("design.owner.export")
            }
        }
    }

    @ViewBuilder
    private var candidatesSection: some View {
        if !model.pendingCandidates.isEmpty {
            Section("design.owner.candidates") {
                ForEach(model.pendingCandidates) { candidate in
                    VStack(alignment: .leading, spacing: 6) {
                        let comparison = model.comparison?.candidateID == candidate.id
                            ? model.comparison : nil
                        DesignCandidateSummaryRow(
                            summary: candidate.summary,
                            statusText: FloeL10n.l("design.owner.pending"),
                            statusColor: FloeTheme.pending,
                            diffLines: comparison.map(\.diff) ?? candidate.diff,
                            diffTruncated: comparison?.diffTruncated ?? false,
                            diffNote: comparison?.diffNote)
                        if let comparison, !comparison.changed {
                            Text("design.owner.no_change").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Button("design.owner.compare") {
                                Task { await model.compare(candidate.id) }
                            }
                            .disabled(model.busy)
                            .accessibilityIdentifier("design.owner.compare.\(candidate.id)")
                        }
                        DesignCandidateActionButtons(
                            busy: model.busy,
                            adoptTitle: model.isImmutableOwner
                                ? "design.owner.adopt_return"
                                : "design.owner.adopt",
                            showsVariant: !model.isImmutableOwner,
                            rejectTitle: "design.owner.reject",
                            adoptIdentifier: "design.owner.adopt.\(candidate.id)",
                            variantIdentifier: "design.owner.adoptVariant.\(candidate.id)",
                            rejectIdentifier: "design.owner.reject.\(candidate.id)",
                            onAdopt: { Task { await model.adopt(candidate.id, mode: .updateOriginal) } },
                            onVariant: { Task { await model.adopt(candidate.id, mode: .variant) } },
                            onReject: { Task { await model.reject(candidate.id) } })
                        // Trusted-UI mint for the assistant's design.adopt:
                        // same confirmation service the tools consume, bound
                        // to this exact candidate/base/proposed/mode, and
                        // DURABLY delivered to the frozen originating task.
                        // Only offered when an honest origin exists; a target
                        // without one shows the manual adopt only.
                        if model.canAuthorizeAssistant {
                            Menu {
                                Button("design.owner.authorize_update") {
                                    Task { await model.authorizeAssistantAdoption(candidate.id, mode: .updateOriginal) }
                                }
                                if !model.isImmutableOwner {
                                    Button("design.owner.authorize_variant") {
                                        Task { await model.authorizeAssistantAdoption(candidate.id, mode: .variant) }
                                    }
                                }
                            } label: {
                                Label("design.owner.authorize_assistant", systemImage: "checkmark.shield")
                            }
                            .disabled(model.busy)
                            .accessibilityIdentifier("design.owner.authorizeAssistant.\(candidate.id)")
                        }
                        if model.authorizedAssistantAdoption?.candidateID == candidate.id {
                            Text("design.owner.authorized_note")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("design.owner.authorizedNote.\(candidate.id)")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var feedbackSection: some View {
        Section("design.owner.feedback") {
            ForEach(model.openFeedback) { feedback in
                DesignFeedbackRow(
                    comment: feedback.comment,
                    statusText: feedback.status == .staleAnchor
                        ? FloeL10n.l("design.owner.feedback_stale")
                        : FloeL10n.l("design.owner.feedback_open"),
                    statusColor: feedback.status == .staleAnchor
                        ? FloeTheme.pending : Color.secondary,
                    busy: model.busy,
                    showsRelocate: feedback.status == .staleAnchor,
                    showsResolve: feedback.status != .staleAnchor
                        && model.currentArtifact?.currentRevisionID != nil,
                    onRelocate: { Task { await model.relocateAnchor(feedback.id) } },
                    onResolve: { Task { await model.resolveFeedback(feedback.id) } })
            }
            TextField("design.owner.feedback_comment", text: $feedbackDraft, axis: .vertical)
                .lineLimit(1...4)
                .accessibilityIdentifier("design.owner.feedbackComment")
            Button("design.owner.feedback_add") {
                Task {
                    await model.addFeedback(feedbackDraft)
                    feedbackDraft = ""
                }
            }
            .disabled(model.busy || feedbackDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("design.owner.feedbackAdd")
        }
    }

    private func loadFieldsIfNeeded(force: Bool) {
        guard let envelope = model.envelope else { return }
        guard loadedRevision != envelope.revision || force else { return }
        loadedRevision = envelope.revision
        briefGoal = envelope.project.brief?.goal ?? briefGoal
        briefAudience = envelope.project.brief?.audience ?? briefAudience
        specText = envelope.project.spec?.rawMarkdown ?? specText
    }
}
#endif
