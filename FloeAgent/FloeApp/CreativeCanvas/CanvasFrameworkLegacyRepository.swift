// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeCanvasCore
import FloeCanvasIntegration
import FloeCanvasTemplates

/// Existing canvases retain their original JSON file and its CAS writer. The
/// complete kit state/history is an additive payload in that SAME commit.
final class CanvasFrameworkLegacyRepository: CanvasFrameworkRepository, Sendable {
    static let pendingEditorForkKey = "floe.framework.editorForkPending"
    let root: URL
    let record: PersonalContentRecord
    let originalURL: URL
    private struct State: Codable {
        var schemaVersion = 1
        var snapshot: CanvasSnapshot
        var history: CanvasHistoryState
        var receipts: [CanvasCommitReceipt]
        /// Read-only pre-fork evidence; it never participates in active undo
        /// or receipt lookup under the new document identity.
        var priorIdentityState: Data? = nil
    }

    /// Copy/identity-changing save uses the existing identity mapper, never
    /// blindly replaces UUID-like user content. Live runs/receipts do not fork.
    static func forkProject(_ source: FloeCore.CanvasProject, newID: UUID,
                            workspaceID: UUID?, name: String) throws -> FloeCore.CanvasProject {
        guard let bytes = source.canvasKitState else {
            var result = source; result.id = newID; result.workspaceID = workspaceID; result.name = name
            return result
        }
        var state = try JSONDecoder().decode(State.self, from: bytes)
        guard state.schemaVersion == 1, state.snapshot.id == source.id else { throw PersonalContentError.invalidProject }
        if state.snapshot.revision < source.revision {
            let record = identityRecord(source)
            let batch = try CanvasFrameworkProjection.batch(project: source, original: state.snapshot, record: record)
            state.snapshot = try CanvasDocumentEditEngine.apply(batch, to: state.snapshot).snapshot
        }
        let copied = CanvasIdentityMapper.copy(state.snapshot, newSnapshotID: newID)
        var snapshot = copied.snapshot
        var mapping = copied.idMapping
        var records = try CreativeRecords.read(state.snapshot)
        for record in records { mapping[record.id] = UUID() }
        func mapped(_ id: UUID) -> UUID { mapping[id] ?? id }
        for index in records.indices {
            records[index].id = mapped(records[index].id)
            records[index].nodeIDs = records[index].nodeIDs.map(mapped)
            records[index].relatedRecordIDs = records[index].relatedRecordIDs.map(mapped)
        }
        if !records.isEmpty { snapshot.metadata[CreativeRecords.metadataKey] = try CreativeRecords.encode(records) }
        var registrations = try TemplateRegistration.read(state.snapshot)
        for index in registrations.indices {
            let original = registrations[index].id
            let fresh = UUID(); mapping[original] = fresh; registrations[index].id = fresh
            registrations[index].recordIDs = registrations[index].recordIDs.map(mapped)
            for slot in registrations[index].slots.indices {
                registrations[index].slots[slot].nodeID = mapped(registrations[index].slots[slot].nodeID)
            }
        }
        if !registrations.isEmpty { snapshot.metadata[TemplateRegistration.metadataKey] = try TemplateRegistration.encode(registrations) }
        snapshot.metadata[TemplateOwnership.metadataKey] = String(decoding: try JSONEncoder().encode(
            TemplateOwnership(kind: workspaceID == nil ? .canvas : .workspace, ownerID: workspaceID ?? newID, directoryID: newID)), as: UTF8.self)
        for pi in snapshot.pages.indices {
            for ni in snapshot.pages[pi].nodes.indices {
                var node = snapshot.pages[pi].nodes[ni]
                if case .editor = node.content { node.metadata[pendingEditorForkKey] = "true" }
                if var purpose = try CreativePurpose.read(node) {
                    purpose.recordID = purpose.recordID.map(mapped); purpose.referenceNodeIDs = purpose.referenceNodeIDs.map(mapped)
                    try purpose.apply(to: &node)
                }
                if let provenance = node.metadata[CanvasTemplateEngine.provenanceKey] {
                    var parts = provenance.split(separator: "/").map(String.init)
                    if parts.count == 3, let old = UUID(uuidString: parts[2]), let fresh = mapping[old] {
                        parts[2] = fresh.uuidString; node.metadata[CanvasTemplateEngine.provenanceKey] = parts.joined(separator: "/")
                    }
                }
                if case .unknown(let kind, .object(var payload)) = node.content, kind == CanvasFrameworkProjection.frameworkNodeKind {
                    payload["id"] = .string(node.id.uuidString)
                    payload["createdByRunID"] = nil; payload["generationJobID"] = nil
                    if var group = node.groupID { group = mapped(group); payload["groupID"] = .string(group.uuidString) }
                    else { payload["groupID"] = nil }
                    node.content = .unknown(kind: kind, payload: .object(payload))
                }
                node.metadata["floe.canvas.runOutputBadge"] = nil
                node.metadata["floe.canvas.runOutputKey"] = nil
                snapshot.pages[pi].nodes[ni] = node
            }
        }
        var framework = source
        framework.id = newID; framework.workspaceID = workspaceID; framework.name = name
        framework.canvasKitState = nil
        if workspaceID == nil {
            framework.agentConversationID = nil; framework.assistantSessions = []
            framework.selectedAssistantSessionID = nil; framework.agentConversationIDsByDocument = [:]
        } else {
            framework.agentConversationIDsByDocument = Dictionary(source.agentConversationIDsByDocument.map { (mapped($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })
        }
        framework.createdAt = Date(); framework.updatedAt = Date(); framework.revision = 0
        snapshot.name = name; snapshot.createdAt = framework.createdAt; snapshot.updatedAt = framework.updatedAt
        snapshot.metadata[CanvasFrameworkProjection.frameworkStateKey] = String(decoding: try JSONEncoder().encode(framework), as: UTF8.self)
        var result = try CanvasFrameworkProjection.project(snapshot, record: identityRecord(framework))
        result.canvasKitState = try JSONEncoder().encode(State(snapshot: snapshot, history: .init(), receipts: [], priorIdentityState: bytes))
        return result
    }

    /// Called after the existing CAD package fork rewrites its source paths.
    static func reconcileForkedProject(_ project: FloeCore.CanvasProject) throws -> FloeCore.CanvasProject {
        guard let bytes = project.canvasKitState else { return project }
        var state = try JSONDecoder().decode(State.self, from: bytes)
        let batch = try CanvasFrameworkProjection.batch(project: project, original: state.snapshot, record: identityRecord(project))
        state.snapshot = try CanvasDocumentEditEngine.apply(batch, to: state.snapshot).snapshot
        state.snapshot.revision = project.revision
        var result = project; result.canvasKitState = try JSONEncoder().encode(state)
        return result
    }
    private static func identityRecord(_ project: FloeCore.CanvasProject) -> PersonalContentRecord {
        .init(id: project.id, kind: .canvas, title: project.name, createdAt: project.createdAt, modifiedAt: project.updatedAt,
              folders: [], relativePath: ".CanvasExtensions/" + project.id.uuidString + ".floeproject")
    }
    static func copyAuxiliaryAssets(from sourceID: UUID, to copyID: UUID) throws {
        let root = try PersonalContentLibrary.applicationRoot().appendingPathComponent(".CanvasExtensions", isDirectory: true)
        let source = root.appendingPathComponent(sourceID.uuidString + ".floeproject/Assets", isDirectory: true)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        guard (try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isSymbolicLink != true else { throw PersonalContentError.outsideLibrary }
        let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        for file in files {
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true else { throw PersonalContentError.outsideLibrary }
        }
        let parent = root.appendingPathComponent(copyID.uuidString + ".floeproject", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("Assets", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw PersonalContentError.changedDocument }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        for file in files { try FileManager.default.copyItem(at: file, to: target.appendingPathComponent(file.lastPathComponent)) }
    }

    init(record: PersonalContentRecord, originalURL: URL, root: URL) {
        self.record = record; self.originalURL = originalURL; self.root = root
    }

    func sourceURL(canvasID: UUID) -> URL { originalURL }
    func projectSynchronously() throws -> FloeCore.CanvasProject {
        try CanvasProjectFileWriter.shared.project(canvasID: record.id, at: originalURL)
    }

    private func read(_ canvasID: UUID) throws -> (FloeCore.CanvasProject, State) {
        guard canvasID == record.id else { throw PersonalContentError.changedDocument }
        let project = try CanvasProjectFileWriter.shared.project(canvasID: canvasID, at: originalURL)
        guard let bytes = project.canvasKitState else {
            return (project, State(snapshot: try CanvasFrameworkProjection.snapshot(project), history: .init(), receipts: []))
        }
        var state = try JSONDecoder().decode(State.self, from: bytes)
        guard state.schemaVersion == 1, state.snapshot.id == canvasID,
              state.snapshot.revision <= project.revision else { throw PersonalContentError.invalidProject }
        if state.snapshot.revision < project.revision {
            // Existing native/AI writers still edit the same project. Overlay
            // those edits on the retained richer snapshot rather than reset it.
            let previous = state.snapshot
            let batch = try CanvasFrameworkProjection.batch(project: project, original: previous, record: record)
            state.snapshot = try CanvasDocumentEditEngine.apply(batch, to: previous).snapshot
            state.snapshot.revision = project.revision
            state.snapshot.updatedAt = project.updatedAt
            state.history.undoStack.append(.init(snapshotBefore: previous, label: "canvas edit"))
            state.history.redoStack.removeAll()
        }
        return (project, state)
    }

    private func mutate(_ canvasID: UUID, _ change: (inout CanvasRepositoryEngine) throws -> CanvasCommitReceipt) throws -> CanvasCommitReceipt {
        let (original, state) = try read(canvasID)
        var engine = CanvasRepositoryEngine(snapshot: state.snapshot,
            existingReceipts: Dictionary(uniqueKeysWithValues: state.receipts.map { ($0.requestID, $0) }),
            historyState: state.history)
        let receipt = try change(&engine)
        let next = engine.snapshotForPersistence()
        if next.revision == state.snapshot.revision { return receipt } // exact replay
        var project = try CanvasFrameworkProjection.project(next, record: record)
        project.canvasKitState = try JSONEncoder().encode(State(snapshot: next,
            history: engine.historyForPersistence(), receipts: Array(engine.receiptsForPersistence().values),
            priorIdentityState: state.priorIdentityState))
        _ = try CanvasProjectFileWriter.shared.compareAndSwap(project, at: originalURL, expectedRevision: original.revision)
        NotificationCenter.default.post(name: .floeCanvasProjectDidChange, object: nil, userInfo: ["canvasID": canvasID])
        return receipt
    }

    func loadSynchronously(canvasID: UUID) throws -> CanvasSnapshot { try read(canvasID).1.snapshot }
    func load(canvasID: UUID) async throws -> CanvasSnapshot { try loadSynchronously(canvasID: canvasID) }
    func create(canvasID: UUID, snapshot: CanvasSnapshot, requestID: UUID) async throws {
        // This adapter is bound to an existing original. New canvases are
        // created by the host library, never by replacing this file.
        throw CanvasKitError.requestIDConflict(requestID: requestID)
    }
    func commit(_ batch: CanvasEditBatch, canvasID: UUID, expectedRevision: Int64, requestID: UUID) async throws -> CanvasCommitReceipt {
        try mutate(canvasID) { try $0.commit(batch, canvasID: canvasID, expectedRevision: expectedRevision, requestID: requestID) }
    }
    func commitDocument(_ batch: CanvasDocumentBatch, canvasID: UUID, expectedRevision: Int64, requestID: UUID) async throws -> CanvasCommitReceipt {
        try commitDocumentSynchronously(batch, canvasID: canvasID, expectedRevision: expectedRevision, requestID: requestID)
    }
    func commitDocumentSynchronously(_ batch: CanvasDocumentBatch, canvasID: UUID, expectedRevision: Int64, requestID: UUID) throws -> CanvasCommitReceipt {
        try mutate(canvasID) { try $0.commitDocument(batch, canvasID: canvasID, expectedRevision: expectedRevision, requestID: requestID) }
    }
    func undo(canvasID: UUID, expectedRevision: Int64, requestID: UUID) async throws -> CanvasCommitReceipt {
        try undoSynchronously(canvasID: canvasID, expectedRevision: expectedRevision, requestID: requestID)
    }
    func undoSynchronously(canvasID: UUID, expectedRevision: Int64, requestID: UUID) throws -> CanvasCommitReceipt {
        try mutate(canvasID) { try $0.undo(canvasID: canvasID, expectedRevision: expectedRevision, requestID: requestID) }
    }
    func redo(canvasID: UUID, expectedRevision: Int64, requestID: UUID) async throws -> CanvasCommitReceipt {
        try redoSynchronously(canvasID: canvasID, expectedRevision: expectedRevision, requestID: requestID)
    }
    func redoSynchronously(canvasID: UUID, expectedRevision: Int64, requestID: UUID) throws -> CanvasCommitReceipt {
        try mutate(canvasID) { try $0.redo(canvasID: canvasID, expectedRevision: expectedRevision, requestID: requestID) }
    }
    func undoHistory(canvasID: UUID) async throws -> [CanvasUndoEntry] { try read(canvasID).1.history.appliedEntries }
    func historyAvailability(canvasID: UUID) async throws -> CanvasHistoryAvailability { try historyAvailabilitySynchronously(canvasID: canvasID) }
    func historyAvailabilitySynchronously(canvasID: UUID) throws -> CanvasHistoryAvailability {
        let state = try read(canvasID).1.history
        return .init(undoCount: state.undoStack.count, redoCount: state.redoStack.count)
    }
}
#endif
