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
              let candidate = design?.candidate(candidateID) else { return }
        _ = await DesignAdoptionAuthorization.shared.issue(
            canvasID: canvasID, nodeID: nodeID,
            candidateID: candidateID,
            baselineRevisionID: candidate.baseRevisionID
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
        let contentType = design?.contentType
            ?? DesignContentTypeMapper.contentType(for: snapshot?.nodeKind ?? .file)
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
                        TextField("design.panel.goal", text: $newGoal, axis: .vertical).lineLimit(1...3)
                            .onChange(of: newGoal) { _, _ in fieldsDirty = true }
                        TextField("design.panel.audience", text: $newAudience)
                            .onChange(of: newAudience) { _, _ in fieldsDirty = true }
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
                        TextField("design.panel.goal", text: $briefGoal, axis: .vertical)
                            .onChange(of: briefGoal) { _, _ in fieldsDirty = true }
                        TextField("design.panel.audience", text: $briefAudience)
                            .onChange(of: briefAudience) { _, _ in fieldsDirty = true }
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
                        TextField("design.panel.palette", text: $paletteText, axis: .vertical)
                            .onChange(of: paletteText) { _, _ in fieldsDirty = true }
                        TextField("design.panel.typography", text: $typographyText, axis: .vertical)
                            .onChange(of: typographyText) { _, _ in fieldsDirty = true }
                        TextField("design.panel.layout", text: $layoutText, axis: .vertical)
                            .onChange(of: layoutText) { _, _ in fieldsDirty = true }
                        TextField("design.panel.spacing", text: $spacingText, axis: .vertical)
                            .onChange(of: spacingText) { _, _ in fieldsDirty = true }
                        TextField("design.panel.voice", text: $voiceText, axis: .vertical)
                            .onChange(of: voiceText) { _, _ in fieldsDirty = true }
                        TextField("design.panel.prohibitions", text: $prohibitionsText, axis: .vertical)
                            .onChange(of: prohibitionsText) { _, _ in fieldsDirty = true }
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
                                    Text("\(FloeL10n.l("design.panel.current_revision")): #\(current.number) · \(current.origin.rawValue)")
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
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.comment)
                                Text("\(item.anchor.kind) · \(item.status.rawValue)")
                                    .font(.caption2).foregroundStyle(.secondary)
                                if item.status == .staleAnchor,
                                   let artifact = design.artifact(item.artifactID) {
                                    Button("design.panel.relocate_anchor") {
                                        Task { await model.relocateFeedback(feedbackID: item.id, artifactID: artifact.id) }
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
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
            Text(candidate.summary)
            Text(candidate.status.rawValue)
                .font(.caption2).foregroundStyle(.secondary)
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
                HStack {
                    Button("design.panel.adopt") {
                        Task { await model.adopt(candidateID: candidate.id, mode: .updateOriginal) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("design.panel.reject") {
                        Task { await model.reject(candidateID: candidate.id) }
                    }
                    .buttonStyle(.bordered)
                }
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
#endif
