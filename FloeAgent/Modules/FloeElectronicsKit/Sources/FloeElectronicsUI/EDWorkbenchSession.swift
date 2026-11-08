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
    public init(context: EDADocumentContext, positionMillimetres: EDAPoint, objectIDs: Set<UUID> = []) {
        self.context = context; self.positionMillimetres = positionMillimetres
        self.objectIDs = objectIDs; token = UUID()
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
    public var canUndo: Bool { editing.canUndo && !busy && !isRouting && !isClosed }
    public var canRedo: Bool { editing.canRedo && !busy && !isRouting && !isClosed }
    public private(set) var busy = false
    public private(set) var isClosed = false
    private var closing = false
    public private(set) var lastError: EDWorkbenchFailure?
    public private(set) var conflictWithOriginal = false
    public private(set) var isChecking = false
    public private(set) var isRouting = false
    public private(set) var ercReport: EDAERCReport?
    public private(set) var drcReport: EDADRCReport?
    private enum CheckResult: Sendable { case erc(EDAERCReport), drc(EDADRCReport) }
    @ObservationIgnored private var checkTask: Task<CheckResult, Error>?
    @ObservationIgnored private var routeTask: Task<EDATrack, Error>?
    public var selection = EDASelection.none
    public private(set) var focusRequest: EDAFocusRequest?
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
    private func perform(_ operation: String, expectedRevision: UInt64?,
                         _ change: (inout EDAEditingSession) throws -> Void) async throws {
        try requireOpen(expectedRevision: expectedRevision)
        guard !isRouting else { throw EDAError.invalid("routing is still running") }
        guard !conflictWithOriginal else { throw EDAError.invalid("resolve the saved original conflict first") }
        busy = true; defer { busy = false }
        var candidate = editing
        do {
            try change(&candidate)
            guard candidate.project != editing.project else { return }
            let saved = try await store.save(candidate.project, expectedRevision: editing.savedRevision,
                expectedDigest: try savedDigest())
            try candidate.markSaved(saved)
            editing = candidate; lastError = nil; conflictWithOriginal = false
            onSaved?(saved); onChange?()
        } catch {
            // A failed CAS retains the local proposal and its undo stack.
            // Only an explicit discard/refresh may replace those edits.
            editing = candidate
            if case EDAError.staleRevision = error { conflictWithOriginal = true }
            report(error, operation: operation)
            throw error
        }
    }
    private func savedDigest() throws -> String {
        guard let value = editing.savedDigest else { throw EDAError.invalid("saved digest missing") }
        return value
    }
    public func apply(_ edits: [EDAEdit], expectedRevision: UInt64? = nil) async throws {
        try await perform("apply", expectedRevision: expectedRevision) { candidate in
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
            conflictWithOriginal = false; lastError = nil; onChange?()
        } catch { report(error, operation: "refresh"); throw error }
    }
    public func flushForClose() async -> Bool {
        do {
            try requireOpen(); closing = true; defer { closing = false }
            if let checkTask {checkTask.cancel();_ = try? await checkTask.value;self.checkTask=nil;isChecking=false}
            if let routeTask {routeTask.cancel();_ = try? await routeTask.value;self.routeTask=nil;isRouting=false}
            _ = try await saveBound(); isClosed = true; selection = .none
            return true
        } catch { report(error, operation: "close"); return false }
    }
    public func close() async {
        guard !busy, !isDirty else { return }
        if let checkTask {checkTask.cancel();_ = try? await checkTask.value;self.checkTask=nil;isChecking=false}
        if let routeTask {routeTask.cancel();_ = try? await routeTask.value;self.routeTask=nil;isRouting=false}
        isClosed = true; selection = .none
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
    public func route(boardID: UUID, from start: EDAPoint, to end: EDAPoint, layer: String, width: Double) async throws {
        try requireOpen()
        guard !isRouting else { throw EDAError.invalid("routing is still running") }
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
        try await apply([.putTrack(board: boardID, track)], expectedRevision: snapshot.revision)
    }
    public func cancelRouting() { routeTask?.cancel() }
    public func requestFocus(_ request: EDAFocusRequest) {
        focusRequest = request; selection = .init(context: request.context, objectIDs: request.objectIDs)
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
        } else {
            message = chinese ? "未能完成操作，原件和待保存的修改仍保留。" : "The operation could not finish. The original and pending edits are retained."
        }
        lastError = .init(operation: operation, message: message, underlying: String(describing: error))
    }
}
