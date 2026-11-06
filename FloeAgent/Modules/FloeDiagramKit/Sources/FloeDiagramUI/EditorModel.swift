// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import UIKit
import FloeDiagramCore
import FloeDiagramIntegration
import FloeDiagramLayout
import FloeDiagramExchange

public enum DiagramEditorMode: String, CaseIterable, Identifiable, Sendable {
    case canvas, outline, board, gantt
    public var id: Self { self }
    public var title: String { switch self { case .canvas: DL("画布", "Canvas"); case .outline: DL("大纲", "Outline"); case .board: DL("看板", "Board"); case .gantt: DL("甘特图", "Gantt") } }
    public var icon: String { switch self { case .canvas: "point.3.connected.trianglepath.dotted"; case .outline: "list.bullet.indent"; case .board: "rectangle.split.3x1"; case .gantt: "chart.bar.xaxis" } }
}
public enum DiagramEditorTool: String, CaseIterable { case select, pan, connect, pencil }
public struct DiagramEditorScene: Sendable {
    public var document: DiagramDocument
    public var page: DiagramPage
    public var layout: DiagramLayoutResult
    public var generation: Int
}
public struct DiagramEditorNotice: Identifiable {
    public let id = UUID()
    public var title: String
    public var message: String
}
public struct DiagramPreparedMerge: Identifiable {
    public let id = UUID()
    public var expectedRevision: Int
    public var result: DiagramMergeResult
    public var context: DiagramEditContext = .init()
}
/// All editor-local state belongs to this instance. The host supplies the existing file and service authorities.
@Observable @MainActor public final class DiagramEditorModel {
    public private(set) var document: DiagramDocument
    public private(set) var scene: DiagramEditorScene?
    public private(set) var pageID: UUID
    public private(set) var mode: DiagramEditorMode = .canvas
    public var tool: DiagramEditorTool = .select
    public var selection: Set<UUID> = []
    public var selectedEdge: DiagramPathID?
    public var selectedTaskID: UUID?
    public var query = ""
    public var taskFilter: DiagramTaskStatus?
    public var tagFilter = ""
    public var showNavigator = false
    public var showInspector = false
    public var isPresenting = false
    public var focusID: UUID?
    public var fitRequest = 0
    public var centerRequest: UUID?
    public var zoomRequest: Double?
    public var zoom: Double = 1
    public var editingElementID: UUID?
    public var notice: DiagramEditorNotice?
    public var preparedMerge: DiagramPreparedMerge?
    public var exchangeIssues: [DiagramExchangeIssue] = []
    public private(set) var history = DiagramHistoryState(canUndo: false, canRedo: false)
    public private(set) var isSaving = false
    public private(set) var isWorking = false
    public private(set) var isLayingOut = false
    public private(set) var isClosed = false
    public private(set) var assetBytes: [UUID: Data] = [:]
    public private(set) var failedBatch: DiagramEditBatch?
    public private(set) var failedBase: DiagramDocument?
    public private(set) var recoveryDocumentID: UUID?
    public let repository: any DiagramRepository
    public let assets: any DiagramAssetStore
    public let callbacks: DiagramHostCallbacks
    public let templateDirectory: URL?
    @ObservationIgnored private let session: DiagramSession
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var layoutTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isClosing = false
    @ObservationIgnored private var pendingInk: (UUID, Data)?
    @ObservationIgnored private var inkTask: Task<Void, Never>?
    @ObservationIgnored private var imageTask: Task<Void, Never>?
    @ObservationIgnored private var requestedImages: Set<UUID> = []
    @ObservationIgnored private var failedContext = DiagramEditContext()
    @ObservationIgnored private var asyncOperations: [UUID: Task<Void, Never>] = [:]

    public init(document: DiagramDocument, repository: any DiagramRepository, assets: any DiagramAssetStore,
                callbacks: DiagramHostCallbacks = .init(), templateDirectory: URL? = nil) {
        self.document = document; self.repository = repository; self.assets = assets; self.callbacks = callbacks
        self.templateDirectory = templateDirectory; pageID = document.pages[0].id
        session = DiagramSession(documentID: document.id, repository: repository)
        rebuildScene()
        Task { [weak self] in await self?.updateHistory() }
    }
    public var page: DiagramPage { document.page(pageID) ?? document.pages[0] }
    public var selectedElement: DiagramElement? { selection.count == 1 ? page.elements.first { selection.contains($0.id) } : nil }
    public var selectedConnection: DiagramConnection? {
        guard case .connection(let id) = selectedEdge else { return nil }; return page.connections.first { $0.id == id }
    }
    public var selectedTask: DiagramTask? {
        let id = selectedTaskID ?? selectedElement?.taskID
        return document.tasks.first { $0.id == id }
    }
    public var selectedTaskIDs: Set<UUID> {
        var ids = Set(scene?.page.elements.filter { selection.contains($0.id) }.compactMap(\.taskID) ?? [])
        if let selectedTaskID { ids.insert(selectedTaskID) }; return ids
    }
    public var visibleElements: [DiagramElement] {
        let tasks = Dictionary(uniqueKeysWithValues: document.tasks.map { ($0.id, $0) })
        return page.elements.filter {
            (query.isEmpty || ($0.title + " " + $0.content.map(\.plainText).joined(separator: " ") + " " + $0.tags.joined(separator: " ")).localizedCaseInsensitiveContains(query)) &&
            (tagFilter.isEmpty || $0.tags.contains(tagFilter)) &&
            (taskFilter == nil || $0.taskID.flatMap { tasks[$0]?.status } == taskFilter)
        }
    }
    public func selectPage(_ id: UUID) {
        guard document.page(id) != nil else { return }
        flushPendingInk(); tool = .select
        pageID = id; selection = []; selectedEdge = nil; selectedTaskID = nil; focusID = nil; editingElementID = nil; centerRequest = nil
        rebuildScene(); fitRequest += 1
    }
    public func selectMode(_ newMode: DiagramEditorMode) {
        mode = newMode; selection = []; selectedEdge = nil; selectedTaskID = nil; editingElementID = nil; centerRequest = nil
        tool = .select; rebuildScene(); fitRequest += 1
    }
    public func select(_ id: UUID?, extending: Bool = false) {
        selectedEdge = nil; selectedTaskID = nil
        guard let id else { if !extending { selection = [] }; return }
        if let task = scene?.page.elements.first(where: { $0.id == id })?.taskID, mode == .board || mode == .gantt {
            selectedTaskID = task; selection = [id]; showInspector = true; return
        }
        if mode == .board || mode == .gantt { selection = []; return }
        if extending { if !selection.insert(id).inserted { selection.remove(id) } } else { selection = [id] }
    }
    public func selectEdge(_ edge: DiagramPathID) {
        selection = []; selectedTaskID = nil
        if mode == .board || mode == .gantt {
            let raw = scene?.page.connections.first { $0.id == edge.uuid }?.metadata["dependencyID"]
            if let dependencyID = raw.flatMap(UUID.init(uuidString:)), let dependency = document.dependencies.first(where: { $0.id == dependencyID }) { selectedTaskID = dependency.successorID }
            selectedEdge = nil
        } else { selectedEdge = edge }
        showInspector = true
    }
    public func focus(_ id: UUID?) { focusID = id; rebuildScene(); fitRequest += 1 }
    public func reveal(_ id: UUID) {
        let currentPage = pageID
        perform(DL("展开路径", "Reveal path")) { doc in
            guard let page = doc.page(currentPage) else { return [] }; let index = DiagramPageIndex(page)
            var cursor = index.elements[id]?.parentID, edits: [DiagramEdit] = []
            while let nodeID = cursor, var node = index.elements[nodeID] { if node.collapsed { node.collapsed = false; edits.append(.upsertElement(pageID: currentPage, element: node)) }; cursor = node.parentID }
            return edits
        }
        selection = [id]; selectedEdge = nil; centerRequest = id
    }
    public func follow(_ link: DiagramLink) {
        guard !document.isBroken(link,sourcePageID: pageID) else { notice = .init(title: DL("链接目标已不存在", "The linked item is missing"),message: DL("请选择新的页面或主题作为目标。", "Choose a new page or topic as the target.")); return }
        if let page = link.pageID { selectPage(page); if let node = link.elementID { reveal(node) }; return }
        if let raw = link.url, let url = URL(string: raw), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { UIApplication.shared.open(url) }
    }
    /// Builders execute in sequence against the latest successfully committed snapshot, preventing stale field overwrites.
    public func perform(_ title: String, context: DiagramEditContext = .init(),
                        _ builder: @escaping @MainActor (DiagramDocument) throws -> [DiagramEdit]) {
        guard !isClosing, !isClosed else { return }
        enqueue { model in
            guard model.failedBatch == nil else { return }
            let before = model.document, edits = try builder(before)
            guard !edits.isEmpty else { return }
            let batch = DiagramEditBatch(documentID: before.id, expectedRevision: before.revision, title: title, edits: edits)
            do { model.accept(try await model.session.commit(batch, context: context)) }
            catch {
                let retain: Bool
                if let error = error as? DiagramError {
                    switch error { case .conflict, .io, .cancelled: retain = true; default: retain = false }
                } else { retain = true }
                if retain { model.failedBatch = batch; model.failedBase = before; model.failedContext = context }
                throw error
            }
        }
    }
    private func enqueue(_ operation: @escaping @MainActor (DiagramEditorModel) async throws -> Void) {
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            guard let self, !self.isClosed, !Task.isCancelled else { return }
            self.isSaving = true
            do { try await operation(self) } catch { self.report(error) }
            await self.updateHistory(); self.isSaving = false
        }
    }
    public func waitForIdle() async { flushPendingInk(); await queue?.value; await layoutTask?.value }
    public func waitForHostOperations() async { let tasks = Array(asyncOperations.values); for task in tasks { await task.value }; await waitForIdle() }
    public func scheduleInk(_ data: Data, pageID: UUID) {
        guard !isClosing, !isClosed else { return }; pendingInk = (pageID, data)
        inkTask?.cancel(); inkTask = Task { [weak self] in try? await Task.sleep(for: .milliseconds(500)); guard !Task.isCancelled else { return }; self?.flushPendingInk() }
    }
    public func flushPendingInk() {
        inkTask?.cancel()
        guard let (p, data) = pendingInk else { return }; pendingInk = nil
        perform(DL("手写批注", "Ink annotation")) { doc in guard doc.page(p)?.ink != data else { return [] }; return [.setInk(pageID: p, data: data)] }
    }
    public func undo(redo: Bool = false) {
        enqueue { model in
            guard model.failedBatch == nil else { return }
            model.accept(try await model.session.undo(expectedRevision: model.document.revision, redo: redo))
        }
    }
    public func retrySave() {
        enqueue { model in
            guard let batch = model.failedBatch else { return }
            let result = try await model.session.commit(batch, context: model.failedContext)
            model.failedBatch = nil; model.failedBase = nil; model.accept(result)
        }
    }
    /// Resolves an external CAS conflict against the actual file. It never discards the unsaved local batch.
    public func prepareConflictRecovery() {
        launch { model in
            guard let batch = model.failedBatch, let base = model.failedBase else { return }
            let draft = try DiagramEditEngine.applying(batch, to: base, context: model.failedContext)
            let latest = try await model.repository.load(base.id)
            let merge = try DiagramMerge.threeWay(base: base, local: latest, incoming: draft)
            model.preparedMerge = .init(expectedRevision: latest.revision, result: merge, context: model.failedContext)
        }
    }
    public func applyPreparedMerge() {
        guard let prepared = preparedMerge else { return }
        enqueue { model in
            let latest = try await model.repository.load(model.document.id)
            guard latest.revision == prepared.expectedRevision else { throw DiagramError.conflict(expected: prepared.expectedRevision, actual: latest.revision) }
            // Save the incoming version first, before publishing a merge that keeps local conflict fields.
            if let recovery = prepared.result.incomingRecovery {
                do {
                    let existing = try await model.repository.load(recovery.id)
                    guard existing == recovery else { throw DiagramError.invalid("recovery identity collision") }
                } catch DiagramError.notFound { try await model.repository.create(recovery) }
                model.recoveryDocumentID = recovery.id
            }
            let edits = try DiagramDiff.edits(from: latest, to: prepared.result.document)
            let result = edits.isEmpty ? latest : try await model.session.commit(.init(documentID: latest.id, expectedRevision: latest.revision, title: DL("合并修改", "Merge changes"), edits: edits), context: prepared.context)
            model.failedBatch = nil; model.failedBase = nil; model.preparedMerge = nil; model.accept(result)
        }
    }
    public func reload() {
        enqueue { model in
            guard model.failedBatch == nil else { throw DiagramError.invalid(DL("请先恢复尚未保存的修改", "Recover unsaved changes first")) }
            model.accept(try await model.session.snapshot())
        }
    }
    private func accept(_ snapshot: DiagramDocument) {
        guard !isClosed, snapshot.id == document.id else { return }
        document = snapshot
        if snapshot.page(pageID) == nil { pageID = snapshot.pages[0].id }
        if mode == .canvas || mode == .outline { selection.formIntersection(page.elements.map(\.id)) }
        rebuildScene()
    }
    private func updateHistory() async { if let value = try? await repository.history(document.id), !isClosed { history = value } }
    public func report(_ error: Error) {
        guard !isClosed else { return }
        let conflict: Bool = if case DiagramError.conflict = error { true } else { false }
        let message: String
        switch error {
        case DiagramError.protectedContent: message = DL("选区包含锁定内容。请先解锁，或缩小修改范围。", "The selection contains locked content. Unlock it or choose a smaller selection.")
        case DiagramError.outsideSelection: message = DL("这次修改超出了选区。请调整选区后重试。", "This change extends beyond the selection. Adjust the selection and try again.")
        case DiagramError.notFound: message = DL("所选内容已发生变化，请重新选择。", "The selected content has changed. Select it again.")
        case DiagramError.unsupported: message = DL("目标格式无法保留这些内容。请保留原生文件，或调整导出范围。", "The target format cannot retain this content. Keep the native file or adjust the export scope.")
        case DiagramError.corruptRecord, DiagramError.io: message = DL("文件未能读取或保存。已有内容仍保留，请重试或导出副本。", "The file couldn’t be read or saved. Existing content is retained. Retry or export a copy.")
        case DiagramError.invalid: message = DL("内容或结构需要调整。请检查输入和选区后重试，当前草稿仍保留。", "Check the content, structure and selection, then try again. Your current draft is retained.")
        default: message = DL("暂时无法完成操作。已有内容仍保留，请重试。", "The action couldn’t be completed. Existing content is retained. Try again.")
        }
        notice = .init(title: conflict ? DL("文件有新修改", "The file has changed") : DL("未能完成操作", "Couldn’t complete the action"),
                       message: conflict ? DL("你的修改已保留。请合并文件中的新版本后继续。", "Your changes are retained. Merge the newer file version to continue.") : message)
    }
    public func launch(_ operation: @escaping @MainActor (DiagramEditorModel) async throws -> Void) {
        guard !isClosing, !isClosed else { return }
        let id = UUID()
        asyncOperations[id] = Task { [weak self] in
            guard let self, !self.isClosed else { return }; self.isWorking = true
            do { try await operation(self) } catch is CancellationError {} catch { self.report(error) }
            self.asyncOperations.removeValue(forKey: id); self.isWorking = !self.asyncOperations.isEmpty
        }
    }
    public func close() async {
        guard !isClosed, !isClosing else { return }
        flushPendingInk(); isClosing = true; await queue?.value
        isClosed = true; generation += 1
        queue?.cancel(); layoutTask?.cancel(); imageTask?.cancel(); asyncOperations.values.forEach { $0.cancel() }; asyncOperations.removeAll()
        await session.close()
    }
    public func rebuildScene() {
        isLayingOut = true
        imageTask?.cancel(); requestedImages = []
        generation += 1; let token = generation, snapshot = document, originalPage = page, selectedMode = mode, focused = focusID
        layoutTask?.cancel()
        layoutTask = Task { [weak self] in
            do {
                var result = try await Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    var presentation = snapshot, page = originalPage
                    if selectedMode == .board || selectedMode == .gantt {
                        presentation = try DiagramPlanProjection.document(snapshot, board: selectedMode == .board)
                        page = presentation.pages[0]
                    } else if let focused {
                        let ids = DiagramPageIndex(page).descendants(of: [focused]); page.elements = page.elements.filter { ids.contains($0.id) }
                        for n in page.elements.indices { if page.elements[n].parentID.map({ !ids.contains($0) }) == true { page.elements[n].parentID = nil }; page.elements[n].containerID = nil; page.elements[n].memberIDs = page.elements[n].memberIDs.filter(ids.contains) }
                        page.connections = page.connections.filter { ids.contains($0.from) && ids.contains($0.to) }; presentation.pages = [page]
                    }
                    var layout = try DiagramLayoutEngine.layout(page)
                    if let inkBounds = try DiagramNativeInk.bounds(page.ink) { layout.bounds = layout.bounds.union(inkBounds) }
                    return DiagramEditorScene(document: presentation, page: page, layout: layout, generation: token)
                }.value
                guard let self, !self.isClosed, self.generation == token, !Task.isCancelled else { return }
                result.layout.bounds = try DiagramNativeRenderer.contentBounds(result.layout,ink: result.page.ink)
                self.scene = result
                self.isLayingOut = false
                await self.loadVisibleAssets(generation: token)
            } catch is CancellationError {} catch { if let self, self.generation == token { self.isLayingOut = false; self.scene = nil; if !snapshot.tasks.isEmpty || selectedMode == .canvas || selectedMode == .outline { self.report(error) } } }
        }
    }
    private func loadVisibleAssets(generation: Int) async {
        // Only cache a bounded number of image bytes; the viewport further bounds decoded image memory.
        var remaining = 24*1_024*1_024, loaded: [UUID: Data] = [:]
        for descriptor in document.assets where descriptor.mediaType.hasPrefix("image/") && descriptor.byteCount <= remaining {
            guard !Task.isCancelled, !isClosed, self.generation == generation else { return }
            if let bytes = try? await assets.data(for: descriptor) { loaded[descriptor.id] = bytes; remaining -= bytes.count }
        }
        guard !isClosed, self.generation == generation else { return }; assetBytes = loaded
    }
    public func requestAssets(_ ids: Set<UUID>) {
        guard !ids.isEmpty, !ids.isSubset(of: Set(assetBytes.keys)), ids != requestedImages, !isClosed else { return }
        requestedImages = ids; imageTask?.cancel()
        let descriptors = document.assets.filter { ids.contains($0.id) }, token = generation
        imageTask = Task { [weak self] in
            guard let self else { return }; var loaded: [UUID: Data] = [:], remaining = 24*1_024*1_024
            for asset in descriptors {
                guard !Task.isCancelled, !self.isClosed, token == self.generation else { return }
                if asset.byteCount > remaining && !loaded.isEmpty { continue }
                do { let bytes = try await self.assets.data(for: asset); loaded[asset.id] = bytes; remaining -= bytes.count }
                catch { self.report(error) }
            }
            guard !Task.isCancelled, !self.isClosed, token == self.generation else { return }
            self.assetBytes = loaded; self.requestedImages = []
        }
    }
}

func DL(_ chinese: String, _ english: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("zh") == true ? chinese : english
}
#endif
