// FloeApp — Design workflow panel (Canvas-bound, separate view file).
//
// Thin integration: the canvas presents this sheet for the selected node. All
// state lives in the node's design subdocument and is written through the
// Canvas revision CAS; user actions here (adopt/reject/restore/spec save) are
// direct. "Authorize assistant adoption" mints a single-use grant that
// `canvas.designAdopt` must consume — the agent cannot adopt on its own.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeTools

@MainActor
final class DesignWorkflowPanelModel: ObservableObject {
    @Published private(set) var snapshot: DesignCanvasService.Snapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastSavedAt: Date?
    @Published private(set) var authorizedCandidateID: String?

    let canvasID: UUID
    let nodeID: UUID?

    private let service = DesignCanvasService(repository: FileCanvasDocumentRepository())
    private let capabilities = DesignCapabilityRegistry.designCoreDefaults()

    init(canvasID: UUID, nodeID: UUID?) {
        self.canvasID = canvasID
        self.nodeID = nodeID
    }

    var design: DesignProject? { snapshot?.design }

    func capability(for type: DesignContentType) -> DesignAdapterCapability {
        capabilities.capability(for: type)
    }

    func reload() async {
        guard let nodeID else { return }
        do {
            snapshot = try await service.snapshot(canvasID: canvasID, nodeID: nodeID)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createDesign(type: DesignContentType, goal: String, audience: String?) async {
        guard let nodeID, let revision = snapshot?.canvasRevision else { return }
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // The user's selected content type must be the one stored; the node-kind
        // mapping is only a fallback for agent-created subdocuments.
        await mutate(nodeID: nodeID, expectedRevision: revision, contentType: type) { design in
            DesignWorkflowEngine.updateBrief(
                DesignBrief(goal: goal, audience: audience, constraints: []),
                in: &design
            )
        }
    }

    func updateBrief(goal: String, audience: String?, constraints: [String]) async {
        guard let nodeID, let revision = snapshot?.canvasRevision else { return }
        await mutate(nodeID: nodeID, expectedRevision: revision) { design in
            DesignWorkflowEngine.updateBrief(
                DesignBrief(goal: goal, audience: audience, constraints: constraints),
                in: &design
            )
        }
    }

    func updateSpec(_ spec: DesignSpec) async {
        guard let nodeID, let revision = snapshot?.canvasRevision else { return }
        await mutate(nodeID: nodeID, expectedRevision: revision) { design in
            DesignWorkflowEngine.updateSpec(spec, in: &design)
        }
    }

    func adopt(candidateID: String, mode: DesignAdoptMode) async {
        guard let nodeID, let revision = snapshot?.canvasRevision else { return }
        await mutate(nodeID: nodeID, expectedRevision: revision) { design in
            _ = try DesignWorkflowEngine.adoptCandidate(in: &design, candidateID: candidateID, mode: mode)
        }
    }

    func authorizeAssistantAdoption(candidateID: String) async {
        guard let nodeID,
              let candidate = design?.candidate(candidateID) else { return }
        _ = await DesignAdoptionGrantStore.shared.issue(
            canvasID: canvasID, nodeID: nodeID,
            candidateID: candidateID,
            baselineRevisionID: candidate.baseRevisionID
        )
        authorizedCandidateID = candidateID
    }

    func reject(candidateID: String) async {
        guard let nodeID, let revision = snapshot?.canvasRevision else { return }
        await mutate(nodeID: nodeID, expectedRevision: revision) { design in
            try DesignWorkflowEngine.rejectCandidate(in: &design, candidateID: candidateID)
        }
    }

    func restoreLatestRevision(artifactID: String) async {
        guard let nodeID, let revision = snapshot?.canvasRevision,
              let artifact = design?.artifact(artifactID),
              let currentID = artifact.currentRevisionID else { return }
        let previous = artifact.revisions
            .filter { $0.id != currentID }
            .sorted { $0.number > $1.number }
            .first
        guard let previous else { return }
        await mutate(nodeID: nodeID, expectedRevision: revision) { design in
            _ = try DesignWorkflowEngine.restoreRevision(
                in: &design, artifactID: artifactID, revisionID: previous.id
            )
        }
    }

    private func mutate(
        nodeID: UUID,
        expectedRevision: Int64,
        contentType: DesignContentType? = nil,
        _ body: @escaping (inout DesignProject) throws -> Void
    ) async {
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
        } catch {
            errorMessage = error.localizedDescription
            await reload()
        }
    }
}

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

    init(canvasID: UUID, nodeID: UUID?) {
        _model = StateObject(wrappedValue: DesignWorkflowPanelModel(canvasID: canvasID, nodeID: nodeID))
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
                    Section { Text(error).foregroundStyle(.red) }
                }

                if model.design == nil && model.nodeID != nil {
                    Section("design.panel.new_project") {
                        Picker("design.panel.type", selection: $newType) {
                            ForEach(DesignContentType.allCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        TextField("design.panel.goal", text: $newGoal, axis: .vertical).lineLimit(1...3)
                        TextField("design.panel.audience", text: $newAudience)
                        Button("design.panel.create") {
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
                    Section("design.panel.brief") {
                        TextField("design.panel.goal", text: $briefGoal, axis: .vertical)
                        TextField("design.panel.audience", text: $briefAudience)
                        Button("design.panel.save_brief") {
                            Task {
                                await model.updateBrief(
                                    goal: briefGoal,
                                    audience: briefAudience.isEmpty ? nil : briefAudience,
                                    constraints: design.brief?.constraints ?? []
                                )
                            }
                        }
                    }

                    Section {
                        TextField("design.panel.palette", text: $paletteText, axis: .vertical)
                        TextField("design.panel.typography", text: $typographyText, axis: .vertical)
                        TextField("design.panel.layout", text: $layoutText, axis: .vertical)
                        TextField("design.panel.spacing", text: $spacingText, axis: .vertical)
                        TextField("design.panel.voice", text: $voiceText, axis: .vertical)
                        TextField("design.panel.prohibitions", text: $prohibitionsText, axis: .vertical)
                        Button("design.panel.save_spec") {
                            Task { await model.updateSpec(specFromFields(design)) }
                        }
                        Text("design.panel.spec_frozen_note").font(.caption2).foregroundStyle(.secondary)
                    } header: {
                        Text("design.panel.spec")
                    }

                    Section("design.panel.artifacts") {
                        if design.artifacts.isEmpty {
                            Text("design.panel.no_value").foregroundStyle(.secondary)
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
                                if artifact.revisions.count >= 2 {
                                    Button("design.panel.restore_latest") {
                                        Task { await model.restoreLatestRevision(artifactID: artifact.id) }
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .frame(minHeight: FloeTheme.minimumTarget)
                        }
                    }

                    Section("design.panel.feedback") {
                        if design.feedback.isEmpty {
                            Text("design.panel.no_value").foregroundStyle(.secondary)
                        }
                        ForEach(design.feedback) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.comment)
                                Text("\(item.anchor.kind) · \(item.status.rawValue)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section("design.panel.candidates") {
                        if design.candidates.isEmpty {
                            Text("design.panel.no_value").foregroundStyle(.secondary)
                        }
                        ForEach(design.candidates) { candidate in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.summary)
                                Text(candidate.status.rawValue)
                                    .font(.caption2).foregroundStyle(.secondary)
                                if candidate.status == .pending {
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
                        }
                    }

                    Section("design.panel.capabilities") {
                        ForEach(DesignContentType.allCases, id: \.self) { type in
                            let capability = model.capability(for: type)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.rawValue).font(.headline)
                                Text("\(FloeL10n.l("design.panel.capability_available")): "
                                     + capability.available.map(\.rawValue).sorted().joined(separator: ", "))
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
                loadFieldsIfNeeded()
            }
            .onChange(of: model.snapshot?.design?.updatedAt) { _, _ in
                loadFieldsIfNeeded()
            }
        }
        .frame(minWidth: 420, minHeight: 520)
    }

    private func loadFieldsIfNeeded() {
        guard let design = model.design, loadedDesignID != design.nodeID + ":" + ISO8601DateFormatter().string(from: design.updatedAt) else { return }
        loadedDesignID = design.nodeID + ":" + ISO8601DateFormatter().string(from: design.updatedAt)
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
#endif
