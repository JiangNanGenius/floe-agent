import Foundation
import Testing
import FloeCanvasCore
import FloeCanvasIntegration
import FloeCanvasFlow
@testable import FloeCanvasTemplates

/// Explicit qualification host: records real calls through the public gateway.
/// It does not claim provider generation or a production editor.
actor TemplateQualificationHost: CanvasEditorGateway, TemplateEditorCreating, CanvasEditorForkGateway, CanvasStepExecutor, TemplateOwnershipResolving {
    var creations: [UUID: CanvasEditorReference] = [:]
    var createdKinds: [String] = []
    var owners: [UUID: TemplateOwnership] = [:]
    var requests: [CanvasStepExecutionRequest] = []
    var stepResults: [UUID: CanvasStepQueryResult] = [:]
    var delay = false
    var waiting = false
    var continuation: CheckedContinuation<Void, Never>?
    func setDelayed() { delay = true }
    func setOwner(_ owner: TemplateOwnership, for id: UUID) { owners[id] = owner }
    func ownership(for projectID: UUID) throws -> TemplateOwnership {
        guard let owner = owners[projectID] else { throw TemplateError.notFound(projectID) }
        return owner
    }
    func isWaiting() -> Bool { waiting }
    func release() { continuation?.resume(); continuation = nil }
    func createEditor(_ r: TemplateEditorCreateRequest) async -> CanvasEditorReference {
        if let old = creations[r.requestID] { return old }
        createdKinds.append(r.editorKind)
        let result = CanvasEditorReference(projectID: UUID(), appliedRevision: 1, editorKind: r.editorKind)
        creations[r.requestID] = result
        owners[result.projectID] = r.ownership
        if delay {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
        }
        return result
    }
    func openEditor(_ reference: CanvasEditorReference, context: CanvasRuntimeContext) {}
    func applyEditorResult(_ reference: CanvasEditorReference, context: CanvasRuntimeContext) -> CanvasEditorReference {
        var result = reference; result.appliedRevision += 1; return result
    }
    func forkEditor(_ r: CanvasEditorForkRequest) -> CanvasEditorForkResult {
        .init(original: r.reference, forked: .init(projectID: UUID(), appliedRevision: r.reference.appliedRevision,
                                                  editorKind: r.reference.editorKind))
    }
    func submitStep(_ r: CanvasStepExecutionRequest) -> CanvasStepQueryResult {
        if let old = stepResults[r.attemptID] { return old }
        requests.append(r)
        let value: FlowValue = .json(.object(["operation": r.node.parameters[TemplateOperation.parameterKey] ?? .null]))
        let result = CanvasStepQueryResult(attemptID: r.attemptID, nodeID: r.node.id, status: .succeeded,
                                          outputs: ["output": value], hostTaskBinding: r.attemptID)
        stepResults[r.attemptID] = result
        return result
    }
    func queryStep(attemptID: UUID, runID: UUID) throws -> CanvasStepQueryResult {
        guard let result = stepResults[attemptID] else { throw TemplateError.notFound(attemptID) }
        return result
    }
    func queryRun(runID: UUID) -> FlowRunCheckpoint { .init(runID: runID) }
    func cancelRun(runID: UUID) {}
    func submitted() -> [CanvasStepExecutionRequest] { requests }
}

extension TemplateTests {
    func owner() -> TemplateOwnership {
        .init(kind: .personal, ownerID: UUID(), directoryID: UUID(), owningTaskID: UUID(), environmentID: "qualification")
    }
    func workspace(_ root: URL, host: TemplateQualificationHost? = nil) throws -> CanvasTemplateWorkspace {
        let repo = try FileCanvasRepository(root: root.appendingPathComponent("documents"))
        let library = try CanvasTemplateLibrary(root: root.appendingPathComponent("workflows"))
        return CanvasTemplateWorkspace(documents: repo, library: library,
            editors: host, editorCreator: host, editorForker: host)
    }

    @Test func blankThenAppendMixSaveReopenAndUndoUseOneAuthority() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let ws = try workspace(root)
        let initial = try await ws.create(name: "Mixed", ownership: owner())
        let first = try await ws.activate(canvasID: initial.id)
        _ = try await ws.append(BuiltInCanvasTemplates.all[5], to: first, inputs: ["brief": .text("Synthetic song")])
        let s1 = try await ws.documents.load(canvasID: initial.id)
        #expect(s1.pages.count == 1)
        #expect(s1.pages[0].flowGraphs.count == 1)
        #expect(try TemplateRegistration.read(s1).count == 1)
        let second = try await ws.activate(canvasID: initial.id)
        _ = try await ws.append(BuiltInCanvasTemplates.all[4], to: second)
        let s2 = try await ws.documents.load(canvasID: initial.id)
        #expect(s2.pages[0].flowGraphs.count == 2)
        #expect(try TemplateRegistration.read(s2).count == 2)
        #expect(try CreativeRecords.read(s2).count == 5)
        #expect(Set(s2.pages[0].nodes.map(\.id)).count == s2.pages[0].nodes.count)
        let repo = try FileCanvasRepository(root: root.appendingPathComponent("documents"))
        #expect(try await repo.load(canvasID: initial.id) == s2)
        _ = try await repo.undo(canvasID: initial.id, expectedRevision: s2.revision, requestID: UUID())
        let undone = try await repo.load(canvasID: initial.id)
        #expect(undone.pages[0].flowGraphs.count == 1)
        #expect(try TemplateRegistration.read(undone).count == 1)
        #expect(try CreativeRecords.read(undone).isEmpty)
    }

    @Test func personalWorkflowRoundTripAndFolderRelocation() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let ws = try workspace(root)
        let s = try await ws.create(name: "Song", ownership: owner(),
            template: BuiltInCanvasTemplates.all[5], inputs: ["brief": .text("A melody")])
        let session = try await ws.activate(canvasID: s.id)
        let saved = try await ws.saveWorkflow(title: .init("My song method", "我的歌曲流程"),
                                               category: .music, from: session)
        #expect(!saved.latest.isBuiltIn)
        let new = try await ws.create(name: "Another", ownership: owner(), template: saved.latest)
        #expect(new.id != s.id)
        #expect(new.pages[0].nodes.map(\.id) != s.pages[0].nodes.map(\.id))
        let originalOwner = try await ws.documents.load(canvasID: s.id).metadata[TemplateOwnership.metadataKey]
        let destination = root.appendingPathComponent("moved-documents")
        try FileManager.default.moveItem(at: root.appendingPathComponent("documents"), to: destination)
        let relocated = try FileCanvasRepository(root: destination)
        let recovered = try await relocated.load(canvasID: s.id)
        #expect(recovered.metadata[TemplateOwnership.metadataKey] == originalOwner)
        #expect(try TemplateRegistration.read(recovered).count == 1)
    }

    @Test func realRuntimeDispatchesPresetStepsWithFrozenOwnership() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let host = TemplateQualificationHost()
        let ws = try workspace(root, host: host)
        let ownership = owner()
        let s = try await ws.create(name: "Music", ownership: ownership,
            template: BuiltInCanvasTemplates.all[5], inputs: ["brief": .text("Synthetic melody")])
        let session = try await ws.activate(canvasID: s.id)
        let runtime = FlowRuntimeService(executor: TemplateStepExecutorAdapter(upstream: host),
            bindingResolver: TemplateCanvasBindingResolver(documents: ws.documents))
        let runID = try await ws.startFlow(graphID: s.pages[0].flowGraphs[0].id, session: session,
                                           runtime: runtime, configurationDigest: "qualification-only")
        let deadline = Date().addingTimeInterval(3)
        while await runtime.result(runID: runID) == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let result = await runtime.result(runID: runID)
        #expect(result != nil)
        #expect(result?.terminalStatus == .completed)
        let requests = await host.submitted()
        #expect(requests.count == 4)
        #expect(requests.allSatisfy { $0.context.canvasID == s.id
            && $0.context.owningTaskID == ownership.owningTaskID
            && $0.context.environmentID == ownership.environmentID })
        #expect(requests.first?.inputs["references"] != nil)
        guard let result else { Issue.record("missing terminal result"); return }
        _ = try await ws.applyRunResult(result, session: session)
        let saved = try await ws.documents.load(canvasID: s.id)
        #expect(saved.pages[0].nodes.filter { $0.createdByRunID == runID }.count == 5)
        #expect(saved.pages[0].nodes.contains {
            if case .code(language: "json", source: _) = $0.content { return true }; return false
        })
        let reopened = try FileCanvasRepository(root: root.appendingPathComponent("documents"))
        #expect(try await reopened.load(canvasID: s.id) == saved)
        let fresh = try await ws.activate(canvasID: s.id)
        do {
            _ = try await ws.applyRunResult(result, session: fresh)
            Issue.record("old run overwrote a newer canvas")
        } catch let e as TemplateError { #expect(e == .staleContext) }
    }

    @Test func editorCreateApplyAndLateCallbackNeverCrossSessions() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let host = TemplateQualificationHost(), ws = try workspace(root, host: host)
        let s = try await ws.create(name: "Music", ownership: owner())
        let session = try await ws.activate(canvasID: s.id)
        let editor = try await ws.createEditor(kind: "music", name: "Song", session: session)
        #expect(editor.attached)
        let fresh = try await ws.activate(canvasID: s.id)
        _ = try await ws.applyEditor(nodeID: editor.nodeID!, session: fresh)
        let after = try await ws.documents.load(canvasID: s.id)
        guard case .editor(let updated) = after.pages[0].nodes[0].content else {
            Issue.record("missing editor"); return
        }
        #expect(updated.projectID == editor.reference.projectID)
        #expect(updated.appliedRevision == 2)
        let old = try await ws.activate(canvasID: s.id)
        await host.setDelayed()
        let task = Task { try await ws.createEditor(kind: "video", name: "Video", session: old) }
        let deadline = Date().addingTimeInterval(2)
        while !(await host.isWaiting()) && Date() < deadline { await Task.yield() }
        #expect(await host.isWaiting())
        await ws.deactivate()
        await host.release()
        let late = try await task.value
        #expect(!late.attached)
        #expect(late.recoveryReason != nil)
        #expect(try await ws.documents.load(canvasID: s.id).pages[0].nodes.count == 1)
    }

    @Test func sourceEditsAndSelectionCannotBorrowAnotherOwner() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let ws = try workspace(root)
        let a = try await ws.create(name: "A", ownership: owner(), template: BuiltInCanvasTemplates.all[0])
        let b = try await ws.create(name: "B", ownership: owner())
        let old = try await ws.activate(canvasID: a.id)
        _ = try await ws.activate(canvasID: b.id)
        do {
            _ = try await ws.append(BuiltInCanvasTemplates.all[1], to: old)
            Issue.record("stale session accepted")
        } catch let e as TemplateError { #expect(e == .staleContext) }
        let aa = try await ws.activate(canvasID: a.id)
        _ = try await ws.bindInput(nodeID: a.pages[0].nodes[0].id, content: .text("Updated"), session: aa)
        do {
            _ = try await ws.prepareFlow(graphID: a.pages[0].flowGraphs[0].id, session: aa)
            Issue.record("old revision accepted")
        } catch let e as TemplateError { #expect(e == .staleContext) }
    }

    @Test func purposesRemainPropertiesOnOrdinaryNodes() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let ws = try workspace(root)
        let s = try await ws.create(name: "Film", ownership: owner(), template: BuiltInCanvasTemplates.all[4])
        let session = try await ws.activate(canvasID: s.id)
        let original = s.pages[0].nodes.first { (try? CreativePurpose.read($0))?.role == .characterReference }!
        _ = try await ws.setPurpose(nil, nodeID: original.id, session: session)
        let updated = try await ws.documents.load(canvasID: s.id).pages[0].nodes.first { $0.id == original.id }!
        #expect(updated.id == original.id && updated.kind == original.kind && updated.content == original.content)
        #expect(try CreativePurpose.read(updated) == nil)
    }

    @Test func currentFileOwnershipControlsReturnAndFencesMovedCanvas() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let host = TemplateQualificationHost()
        let repo = try FileCanvasRepository(root: root.appendingPathComponent("documents"))
        let library = try CanvasTemplateLibrary(root: root.appendingPathComponent("workflows"))
        let bridge = TemplateEditorHostBridge(
            resolve: { try await host.ownership(for: $0) },
            create: { await host.createEditor($0) },
            open: { await host.openEditor($0, context: $1) },
            apply: { await host.applyEditorResult($0, context: $1) },
            fork: { await host.forkEditor($0) })
        let ws = CanvasTemplateWorkspace(documents: repo, library: library,
            editors: bridge, editorCreator: bridge, editorForker: bridge, ownershipResolver: bridge)
        let originalOwner = owner()
        let canvas = try await ws.create(name: "Movable", ownership: originalOwner)
        await host.setOwner(originalOwner, for: canvas.id)
        let session = try await ws.activate(canvasID: canvas.id)
        let child = try await ws.createEditor(kind: "music", name: "Song", session: session)
        #expect(try await ws.returnDestination(for: child.reference) == .canvas(canvas.id))
        var newOwner = originalOwner
        newOwner.kind = .workspace; newOwner.directoryID = UUID()
        await host.setOwner(newOwner, for: child.reference.projectID)
        #expect(try await ws.returnDestination(for: child.reference) == .directory(newOwner.directoryID))
        let current = try await ws.activate(canvasID: canvas.id)
        await host.setOwner(newOwner, for: canvas.id)
        do {
            _ = try await ws.append(BuiltInCanvasTemplates.all[0], to: current)
            Issue.record("moved canvas accepted an old ownership context")
        } catch let e as TemplateError { #expect(e == .staleContext) }
        let fresh = try await ws.activate(canvasID: canvas.id)
        #expect(fresh.ownership == newOwner)
        #expect(fresh.ownership.environmentID == originalOwner.environmentID)
    }

    @Test func retainUsedEditorVersionAndResumeWithoutDocumentUndoNoise() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let host = TemplateQualificationHost(), ws = try workspace(root, host: host)
        let canvas = try await ws.create(name: "Film", ownership: owner())
        let session = try await ws.activate(canvasID: canvas.id)
        let child = try await ws.createEditor(kind: "music", name: "Score", session: session)
        let fresh = try await ws.activate(canvasID: canvas.id)
        let kept = try await ws.retainEditorVersionBeforeMove(nodeID: child.nodeID!, session: fresh)
        #expect(kept.retained.attached && kept.original == child.reference)
        #expect(kept.retained.reference.projectID != child.reference.projectID)
        let saved = try await ws.documents.load(canvasID: canvas.id)
        #expect(saved.pages[0].nodes[0].content == .editor(kept.retained.reference))
        #expect(kept.retained.reference.appliedRevision == child.reference.appliedRevision)
        let historyBefore = try await ws.documents.undoHistory(canvasID: canvas.id)
        let navRoot = root.appendingPathComponent("navigation")
        let navigation = try TemplateNavigationStore(root: navRoot)
        let position = TemplateWorkingPosition.editor(pageID: fresh.pageID, nodeID: child.nodeID!)
        try await navigation.save(position, canvasID: canvas.id)
        let reopened = try TemplateNavigationStore(root: navRoot)
        #expect(try await reopened.load(canvasID: canvas.id)?.validated(in: saved) == position)
        #expect(try await ws.documents.undoHistory(canvasID: canvas.id) == historyBefore)
        #expect(TemplateWorkingPosition.editor(pageID: fresh.pageID, nodeID: UUID()).validated(in: saved)
            == .canvas(pageID: fresh.pageID))
    }

    @Test func filmRecordsAlsoWorkWithoutChoosingATemplate() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let ws = try workspace(root)
        let canvas = try await ws.create(name: "Blank", ownership: owner())
        let session = try await ws.activate(canvasID: canvas.id)
        let shot = CreativeRecord(kind: .shot, name: "Opening", order: 0, duration: 4, dialogue: "Synthetic dialogue")
        _ = try await ws.upsertRecord(shot, session: session)
        let updated = try await ws.documents.load(canvasID: canvas.id)
        #expect(try TemplateRegistration.read(updated).isEmpty)
        #expect(try CreativeRecords.read(updated) == [shot])
        let saved = try await ws.saveWorkflow(title: .init("Blank method", "空白流程"), category: .film,
            from: ws.activate(canvasID: canvas.id))
        #expect(saved.latest.snapshot.pages.count == 1)
        #expect(saved.latest.records == [shot])
    }
}
