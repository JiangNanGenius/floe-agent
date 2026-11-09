// SPDX-License-Identifier: MPL-2.0
import Foundation
import Observation
import FloeElectronicsCore

public enum EDADocumentContext: Hashable, Sendable {
    case schematic(sheetID: UUID), board(boardID: UUID)
    case symbol(definitionID: UUID), footprint(definitionID: UUID)
}
public struct EDASelection: Hashable, Sendable {
    public var context: EDADocumentContext?
    public var objectIDs: Set<UUID>
    public init(context: EDADocumentContext? = nil, objectIDs: Set<UUID> = []) {
        self.context = context; self.objectIDs = objectIDs
    }
    public static let none = Self()
}
public struct EDAFocusRequest: Hashable, Sendable {
    public var context: EDADocumentContext
    public var positionMillimetres: EDAPoint
    public var objectIDs: Set<UUID>
    public var token: UUID
    public var fitBounds: EDAViewBounds?
    public var viewport: EDACanvasViewport?
    public init(context: EDADocumentContext, positionMillimetres: EDAPoint, objectIDs: Set<UUID> = [],
                fitBounds: EDAViewBounds? = nil, viewport: EDACanvasViewport? = nil) {
        self.context = context; self.positionMillimetres = positionMillimetres
        self.objectIDs = objectIDs; token = UUID(); self.fitBounds = fitBounds; self.viewport = viewport
    }
}
public struct EDWorkbenchFailure: Error, Hashable, Sendable {
    public let operation: String
    public let message: String
    public let underlying: String
}

@MainActor @Observable public final class EDWorkbenchSession {
    public let store: EDAProjectStore
    private var editing: EDAEditingSession
    public var project: EDAProject { editing.project }
    public var revision: UInt64 { project.revision }
    public var isDirty: Bool { editing.isDirty }
    public var canUndo: Bool { editing.canUndo && !busy && !isRouting && !isFilling && !isClosed }
    public var canRedo: Bool { editing.canRedo && !busy && !isRouting && !isFilling && !isClosed }
    public private(set) var busy = false
    public private(set) var isClosed = false
    private var closing = false
    public private(set) var lastError: EDWorkbenchFailure?
    public private(set) var conflictWithOriginal = false
    public private(set) var isChecking = false
    public private(set) var isRouting = false
    public private(set) var isFilling = false
    public private(set) var isCommittingCopperFill = false
    public var canCancelFilling: Bool { isFilling && !busy && !isCommittingCopperFill && !closing && !isClosed && cancelledFillGeneration != fillGeneration }
    public private(set) var copperFillReport: EDACopperFillReport?
    public private(set) var copperFillIssues: [EDACopperFillIssue] = []
    @ObservationIgnored private var fillTask: Task<EDACopperFillPlan, Error>?
    @ObservationIgnored private var fillGeneration: UUID?
    private var cancelledFillGeneration: UUID?
    public private(set) var isExporting = false
    @ObservationIgnored private var exportTask: Task<EDAExchangeBundle, Error>?
    public private(set) var ercReport: EDAERCReport?
    public private(set) var drcReport: EDADRCReport?
    private enum CheckResult: Sendable { case erc(EDAERCReport), drc(EDADRCReport) }
    @ObservationIgnored private var checkTask: Task<CheckResult, Error>?
    @ObservationIgnored private var routeTask: Task<EDATrack, Error>?
    public var selection = EDASelection.none
    public private(set) var focusRequest: EDAFocusRequest?
    @ObservationIgnored private let crossProbeOwnerID = UUID()
    @ObservationIgnored private var canvasViewports: [EDADocumentContext: EDACanvasViewport] = [:]
    @ObservationIgnored private var appliedFocusTokens: [EDADocumentContext: UUID] = [:]
    private var crossProbeReturn: EDACrossProbeReturn?
    public var canReturnFromCrossProbe: Bool {
        guard let point = crossProbeReturn else { return false }
        return !isClosed && !closing && !busy && point.source.id == project.id && point.source.revision == revision
    }
    public var onSaved: (@MainActor (EDAStoredProject) -> Void)?
    public var onChange: (@MainActor () -> Void)?
    public var fingerDrawingEnabled = false
    public var snapToGrid = true
    public var gridSizeMillimetres = 1.27

    public init(store: EDAProjectStore) async throws {
        let original = try await store.load()
        self.store = store
        editing = try EDAEditingSession(project: original.project, savedDigest: original.digest)
    }
    public static func createNew(root: URL, title: String, id: UUID = UUID()) async throws -> (EDWorkbenchSession, EDAProject) {
        let project = EDABuiltinLibrary.makeProject(id: id, title: title)
        let store = try await EDAProjectStore.create(root: root, project: project)
        return (try await Self(store: store), project)
    }
    private func requireOpen(expectedRevision: UInt64? = nil) throws {
        guard !isClosed, !closing else { throw EDAError.cancelled }
        guard !busy else { throw EDAError.invalid("another edit is saving") }
        if let expectedRevision, expectedRevision != revision {
            throw EDAError.staleRevision(expected: expectedRevision, actual: revision)
        }
    }
    private func perform(_ operation: String, expectedRevision: UInt64?, beforeCommit: (() throws -> Void)? = nil,
                         _ change: (inout EDAEditingSession) throws -> Void) async throws {
        try requireOpen(expectedRevision: expectedRevision)
        guard !isRouting else { throw EDAError.invalid("routing is still running") }
        guard !conflictWithOriginal else { throw EDAError.invalid("resolve the saved original conflict first") }
        busy = true; defer { busy = false }
        var candidate = editing
        var enteredStore = false
        do {
            try change(&candidate)
            guard candidate.project != editing.project else { return }
            let digest = try savedDigest()
            // The final cancellation check and CAS admission run on this
            // actor without an await. Nothing is published before admission.
            try beforeCommit?()
            enteredStore = true
            let saved = try await store.save(candidate.project, expectedRevision: editing.savedRevision,
                expectedDigest: digest)
            try candidate.markSaved(saved)
            editing = candidate; lastError = nil; conflictWithOriginal = false
            copperFillReport = nil; copperFillIssues = []
            onSaved?(saved); onChange?()
        } catch {
            // A failed CAS retains the local proposal and its undo stack.
            // Only an explicit discard/refresh may replace those edits.
            // A pre-admission cancelled fill discards its private proposal.
            // A real CAS failure keeps the original proposal/undo semantics.
            if beforeCommit == nil || enteredStore { editing = candidate }
            if case EDAError.staleRevision = error { conflictWithOriginal = true }
            report(error, operation: operation)
            throw error
        }
    }
    private func savedDigest() throws -> String {
        guard let value = editing.savedDigest else { throw EDAError.invalid("saved digest missing") }
        return value
    }
    public func apply(_ edits: [EDAEdit], expectedRevision: UInt64? = nil, cancelBeforeCommit: Bool = false) async throws {
        if cancelBeforeCommit { try Task.checkCancellation() }
        let check: (() throws -> Void)? = cancelBeforeCommit ? { try Task.checkCancellation() } : nil
        try await perform("apply", expectedRevision: expectedRevision, beforeCommit: check) { candidate in
            try candidate.apply(edits, expectedRevision: candidate.project.revision)
        }
    }
    public func transaction(expectedRevision: UInt64? = nil, _ change: (inout EDAProject) throws -> Void) async throws {
        try await perform("edit", expectedRevision: expectedRevision) { candidate in
            try candidate.transaction(expectedRevision: candidate.project.revision, change)
        }
    }
    public func undo(expectedRevision: UInt64? = nil) async throws {
        try await perform("undo", expectedRevision: expectedRevision) { try $0.undo(expectedRevision: $0.project.revision) }
    }
    public func redo(expectedRevision: UInt64? = nil) async throws {
        try await perform("redo", expectedRevision: expectedRevision) { try $0.redo(expectedRevision: $0.project.revision) }
    }
    public func save() async throws -> EDAStoredProject {
        try requireOpen(); return try await saveBound()
    }
    private func saveBound() async throws -> EDAStoredProject {
        busy = true; defer { busy = false }
        do {
            let wasDirty = isDirty
            let saved = try await store.save(project, expectedRevision: editing.savedRevision, expectedDigest: try savedDigest())
            try editing.markSaved(saved); conflictWithOriginal = false; lastError = nil
            if wasDirty { onSaved?(saved); onChange?() }
            return saved
        } catch {
            if case EDAError.staleRevision = error { conflictWithOriginal = true }
            report(error, operation: "save"); throw error
        }
    }
    public func refresh(discardChanges: Bool = false) async throws {
        try requireOpen()
        guard !isDirty || discardChanges else { throw EDAError.invalid("unsaved changes retained") }
        busy = true; defer { busy = false }
        do {
            let saved = try await store.load()
            editing = try EDAEditingSession(project: saved.project, savedDigest: saved.digest)
            copperFillReport = nil; copperFillIssues = []
            conflictWithOriginal = false; lastError = nil; onChange?()
        } catch { report(error, operation: "refresh"); throw error }
    }
    public func flushForClose() async -> Bool {
        do {
            try requireOpen(); closing = true; defer { closing = false }
            let ownedFill = fenceFillForClose()
            if let checkTask {checkTask.cancel();_ = try? await checkTask.value;self.checkTask=nil;isChecking=false}
            if let routeTask {routeTask.cancel();_ = try? await routeTask.value;self.routeTask=nil;isRouting=false}
            if let exportTask{exportTask.cancel();_ = try? await exportTask.value;self.exportTask=nil;isExporting=false}
            if let ownedFill { _ = try? await ownedFill.value }
            finishFillForClose()
            _ = try await saveBound(); isClosed = true; selection = .none
            return true
        } catch { report(error, operation: "close"); return false }
    }
    public func close() async {
        guard !busy, !isDirty, !closing, !isClosed else { return }
        closing = true; defer { closing = false }
        // Fence before joining any unrelated worker. A fill whose geometry
        // finishes during another join cannot enter a late save.
        let ownedFill = fenceFillForClose()
        if let checkTask {checkTask.cancel();_ = try? await checkTask.value;self.checkTask=nil;isChecking=false}
        if let routeTask {routeTask.cancel();_ = try? await routeTask.value;self.routeTask=nil;isRouting=false}
        if let exportTask{exportTask.cancel();_ = try? await exportTask.value;self.exportTask=nil;isExporting=false}
        if let ownedFill { _ = try? await ownedFill.value }
        finishFillForClose()
        guard !busy, !isDirty else { return }
        isClosed = true; selection = .none
    }
    private func fenceFillForClose() -> Task<EDACopperFillPlan, Error>? {
        let task = fillTask
        fillGeneration = nil; cancelledFillGeneration = nil
        task?.cancel()
        return task
    }
    private func finishFillForClose() {
        fillTask = nil; isFilling = false; isCommittingCopperFill = false
    }
    public func cancelExport() { exportTask?.cancel() }
    /// Own the bounded worker in the document session, preserve the saved
    /// source and fence both native edits and independent original writers.
    public func export(format:EDAExportFormat,boardID:UUID?,variant:String,gerberLayers:[String]?=nil) async throws -> EDAExchangeBundle {
        try requireOpen()
        guard !isExporting else{throw EDAError.invalid("an export is already running")}
        isExporting=true;defer{exportTask=nil;isExporting=false}
        try Task.checkCancellation()
        let saved=try await save(),snapshot=saved.project
        guard !isClosed, !closing else { throw EDAError.cancelled }
        try Task.checkCancellation()
        let task=Task.detached(priority:.userInitiated){try EDAExchange.export(snapshot,format:format,boardID:boardID,variant:variant,gerberLayers:gerberLayers,cancelled:{Task.isCancelled})}
        exportTask=task
        let result=try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
        try Task.checkCancellation()
        let current=try await store.load()
        guard !isClosed,!closing else{throw EDAError.cancelled}
        guard revision==snapshot.revision,current.digest==saved.digest else{throw EDAError.staleRevision(expected:snapshot.revision,actual:current.project.revision)}
        return result
    }
    public func netlist() throws -> EDANetlist { try requireOpen(); return try EDAConnectivity.derive(project) }
    public func erc() throws -> EDAERCReport { try requireOpen(); return try EDAERC.check(project) }
    public func drc(boardID: UUID) throws -> EDADRCReport { try requireOpen(); return try EDADRC.check(project, boardID: boardID) }
    public func forwardAnnotation(boardID: UUID, expectedRevision: UInt64? = nil) async throws {
        try await perform("synchronize", expectedRevision: expectedRevision) { candidate in
            let plan = try EDAForwardAnnotation.plan(candidate.project, boardID: boardID)
            try EDAForwardAnnotation.apply(plan, to: &candidate)
        }
    }
    public func backAnnotation(_ plan: EDABackAnnotationPlan,
                               cancelled: @escaping @Sendable () -> Bool = { false }) async throws {
        try await perform("backAnnotation", expectedRevision: plan.sourceRevision, beforeCommit: {
            try Task.checkCancellation()
            guard !cancelled(), !self.isClosed, !self.closing else { throw EDAError.cancelled }
        }) { candidate in
            try EDABackAnnotation.apply(plan, to: &candidate, cancelled: cancelled)
        }
    }
    public func createCopperZone(boardID: UUID, netID: String, layer: String, outline: [EDAPoint],
                                 expectedRevision: UInt64? = nil, cancelBeforeCommit: Bool = false) async throws {
        let zone = EDACopperFill.newZone(netID: netID, layer: layer, outline: outline)
        try await apply([.putZone(board: boardID, zone)], expectedRevision: expectedRevision, cancelBeforeCommit: cancelBeforeCommit)
        guard !isClosed, !closing, project.boards.first(where: { $0.id == boardID })?.zones.contains(where: { $0.id == zone.id }) == true else { return }
        selection = .init(context: .board(boardID: boardID), objectIDs: [zone.id])
    }
    @discardableResult
    public func refillCopper(boardID: UUID, expectedRevision: UInt64? = nil,
                             cancelled: @escaping @Sendable () -> Bool = { false }) async throws -> EDACopperFillReport {
        try requireOpen(expectedRevision: expectedRevision)
        guard !isFilling, !isRouting else { throw EDAError.invalid("a board geometry operation is running") }
        guard !conflictWithOriginal else { throw EDAError.invalid("resolve the saved original conflict first") }
        let snapshot = project, generation = UUID()
        let task = Task.detached(priority: .userInitiated) {
            try EDACopperFill.plan(snapshot, boardID: boardID, cancelled: { Task.isCancelled || cancelled() })
        }
        fillGeneration = generation; cancelledFillGeneration = nil
        fillTask = task; isFilling = true; isCommittingCopperFill = false
        copperFillIssues = []; copperFillReport = nil
        defer { if fillGeneration == generation {
            fillTask = nil; fillGeneration = nil; cancelledFillGeneration = nil
            isFilling = false; isCommittingCopperFill = false
        } }
        do {
            let plan = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard !cancelled(), fillGeneration == generation, cancelledFillGeneration != generation else { throw EDAError.cancelled }
            var result: EDACopperFillReport?
            try await perform("refillCopper", expectedRevision: snapshot.revision, beforeCommit: {
                guard !Task.isCancelled, !cancelled(), self.fillGeneration == generation,
                      self.cancelledFillGeneration != generation, !self.isClosed, !self.closing else { throw EDAError.cancelled }
                self.isCommittingCopperFill = true
            }) { candidate in
                result = try candidate.applyCopperFill(plan, expectedRevision: snapshot.revision, cancelled: cancelled)
            }
            guard let result else { throw EDAError.invalid("copper fill result missing") }
            // CAS already returned success (or the operation was a no-op).
            // Closing/new edits fence UI adoption, not the saved fact.
            if !isClosed, !closing, fillGeneration == generation, result.resultRevision == revision {
                copperFillReport = result
            }
            return result
        } catch {
            if !isClosed, !closing, fillGeneration == generation {
                copperFillIssues = (error as? EDACopperFillFailure)?.issues ?? []
                report(error, operation: "refillCopper")
            }
            throw error
        }
    }
    @discardableResult
    public func cancelFilling() -> Bool {
        guard canCancelFilling, let generation = fillGeneration else { return false }
        cancelledFillGeneration = generation
        fillTask?.cancel()
        return true
    }
    public func route(boardID: UUID, from start: EDAPoint, to end: EDAPoint, layer: String, width: Double,
                      expectedRevision: UInt64? = nil) async throws {
        try requireOpen(expectedRevision: expectedRevision)
        try Task.checkCancellation()
        guard !isRouting, !isFilling else { throw EDAError.invalid("a board geometry operation is running") }
        let snapshot = project
        let task = Task.detached(priority: .userInitiated) {
            try EDAInteractiveRouting.track(snapshot, boardID: boardID, from: start, to: end,
                layer: layer, width: width, cancelled: { Task.isCancelled })
        }
        routeTask = task; isRouting = true
        defer { routeTask = nil; isRouting = false }
        let track = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        try Task.checkCancellation()
        isRouting = false
        try await perform("route", expectedRevision: snapshot.revision, beforeCommit: {
            try Task.checkCancellation()
            if task.isCancelled { throw EDAError.cancelled }
        }) { candidate in
            try candidate.apply([.putTrack(board: boardID, track)], expectedRevision: snapshot.revision)
        }
    }
    public func cancelRouting() { routeTask?.cancel() }
    public func requestFocus(_ request: EDAFocusRequest) {
        focusRequest = request; selection = .init(context: request.context, objectIDs: request.objectIDs)
    }
    public func canvasViewport(for context: EDADocumentContext) -> EDACanvasViewport? { canvasViewports[context] }
    public func rememberCanvasViewport(_ viewport: EDACanvasViewport, for context: EDADocumentContext) {
        guard !isClosed, !closing, viewport.isValid else { return }
        canvasViewports[context] = viewport
    }
    /// A focus event is applied once, so reopening a tab preserves later pan/zoom.
    public func consumeFocusRequest(for context: EDADocumentContext) -> EDAFocusRequest? {
        guard !isClosed, !closing, let request = focusRequest, request.context == context,
              appliedFocusTokens[context] != request.token else { return nil }
        appliedFocusTokens[context] = request.token
        return request
    }
    public func makeCrossProbeRequest(variant: String? = nil) throws -> EDACrossProbeRequest {
        try requireOpen()
        guard !isDirty, !conflictWithOriginal else { throw EDACrossProbeError.sourceChanged }
        return .init(resolution: try EDACrossProbe.resolve(project, selection: selection, variant: variant),
            ownerID: crossProbeOwnerID, source: project, digest: try savedDigest(), selection: selection)
    }
    private func validateCrossProbe(_ request: EDACrossProbeRequest) throws {
        guard request.ownerID == crossProbeOwnerID else { throw EDACrossProbeError.ownerChanged }
        try requireOpen()
        guard request.source == project, !isDirty, !conflictWithOriginal else { throw EDACrossProbeError.sourceChanged }
        guard request.selection == selection else { throw EDACrossProbeError.selectionChanged }
        try Task.checkCancellation()
    }
    /// Read-only navigation: the actual saved original is fenced before selection
    /// or focus changes. No save, revision, undo, annotation or onSaved callback.
    @discardableResult public func crossProbe(_ request: EDACrossProbeRequest,
                                              targetID: String? = nil) async throws -> EDACrossProbeTarget {
        try validateCrossProbe(request)
        let target: EDACrossProbeTarget
        if let targetID {
            guard let chosen = request.resolution.targets.first(where: { $0.id == targetID }) else {
                throw EDACrossProbeError.invalidTarget
            }
            target = chosen
        } else {
            guard request.resolution.targets.count == 1 else { throw EDACrossProbeError.chooseTarget }
            target = request.resolution.targets[0]
        }
        let saved = try await store.load()
        try validateCrossProbe(request)
        guard saved.digest == request.digest, saved.project == request.source else { throw EDACrossProbeError.sourceChanged }
        crossProbeReturn = .init(source: request.source, digest: request.digest, selection: request.selection,
            viewport: request.selection.context.flatMap { canvasViewports[$0] }, position: request.resolution.sourcePosition)
        requestFocus(.init(context: target.context, positionMillimetres: target.bounds.center,
            objectIDs: [target.objectID], fitBounds: target.bounds))
        return target
    }
    public func returnFromCrossProbe() async throws {
        try requireOpen(); try Task.checkCancellation()
        guard let point = crossProbeReturn, let context = point.selection.context else { throw EDACrossProbeError.noReturnPoint }
        guard point.source == project, !isDirty, !conflictWithOriginal else { throw EDACrossProbeError.sourceChanged }
        let saved = try await store.load()
        try requireOpen(); try Task.checkCancellation()
        guard crossProbeReturn?.id == point.id, point.source == project, !isDirty, !conflictWithOriginal,
              saved.digest == point.digest, saved.project == point.source else { throw EDACrossProbeError.sourceChanged }
        requestFocus(.init(context: context, positionMillimetres: point.viewport?.center ?? point.position,
            objectIDs: point.selection.objectIDs, viewport: point.viewport))
        crossProbeReturn = nil
    }
    public func cancelCheck() {checkTask?.cancel()}
    public func runCheck(boardID: UUID? = nil) async {
        do {try requireOpen()} catch {report(error);return}
        guard !isChecking else{return}
        let snapshot=project
        let task=Task.detached(priority:.userInitiated) { () throws -> CheckResult in
            if let boardID{return .drc(try EDADRC.check(snapshot,boardID:boardID,cancelled:{Task.isCancelled}))}
            return .erc(try EDAERC.check(snapshot,cancelled:{Task.isCancelled}))
        }
        checkTask=task;isChecking=true
        defer {checkTask=nil;isChecking=false}
        do {
            let result=try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
            guard !isClosed,!closing,revision==snapshot.revision else{return}
            switch result{case .erc(let report):ercReport=report;case .drc(let report):drcReport=report}
            lastError=nil
        } catch {if !isClosed && !closing && !(error is CancellationError){report(error,operation:"check")}}
    }
    public func report(_ error: any Error, operation: String = "edit") {
        if error is CancellationError { lastError = nil; return }
        if case EDAError.cancelled = error { lastError = nil; return }
        let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        let message: String
        if case EDAError.staleRevision = error {
            message = chinese ? "原件已改变。未保存的修改仍保留，请检查后重新载入。" : "The original changed. Unsaved edits are retained; review them before reloading."
        } else if case EDAError.invalid(let reason) = error, reason == "start routing on a connected pad, track or via" {
            message = chinese ? "请从已连接网络的焊盘、导线或过孔开始布线。" : "Start routing on a connected pad, track or via."
        } else if case EDAError.invalid(let reason) = error, reason == "routing would join different nets" {
            message = chinese ? "终点属于另一个网络，请重新选择。" : "The endpoint belongs to another net. Choose a different endpoint."
        } else if case EDAError.invalid(let reason) = error, reason.hasPrefix("route violates ") {
            message = chinese ? "这条路径违反间距、板边或禁布规则，请调整走线。" : "This route violates a clearance, board-edge or keepout rule. Adjust the path."
        } else if error is EDACopperFillFailure {
            message = chinese ? "未能重填铜区，请检查铜区设置和详细原因。" : "Copper zones could not be refilled. Review their settings and details."
        } else {
            message = chinese ? "未能完成操作，原件和待保存的修改仍保留。" : "The operation could not finish. The original and pending edits are retained."
        }
        lastError = .init(operation: operation, message: message, underlying: String(describing: error))
    }
}
