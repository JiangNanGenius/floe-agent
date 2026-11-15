// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import simd

/// A transient entrance into the same document and undo stack. Each floor has
/// one reserved working sketch; its ID is independent of names and elevations.
/// Ordinary sketches, drawing pages and building geometry retain their owners.
@MainActor @Observable
final class CADBuildingDraftingSession {
    let document: FloeCADDocument
    private(set) var storeyID: UUID
    private(set) var isActive = true
    private(set) var issue: String?
    private(set) var canMoveToFloor = false
    private let initialBuilding: CADBuildingDocument?
    private let previousPermanentNavigation: Bool
    private let previousCamera: TurntableCamera?
    private let previousCameraBeforeSketchNavigation: TurntableCamera?
    private let previousOrthographic: Bool
    private let previousSketch: SketchID?
    private var reviewedChangeCount: Int?
    @ObservationIgnored private var checkedGeneration: Int?
    @ObservationIgnored private var checkedFloor: UUID?
    @ObservationIgnored private var checkedAllowed = false
    private var checkpointID: UUID?

    var initialBuildingForNavigation: CADBuildingDocument? { initialBuilding }
    var sketchID: SketchID { Self.sketchID(for: storeyID) }
    static func sketchID(for floor: UUID) -> SketchID {
        SketchID(raw: CADBuildingIdentity.uuid(floor, "drafting-primary-v1"))
    }
    private func text(_ zh: String, _ en: String) -> String { CAD2DDraftingText.text(zh, en) }
    private static func requireWritable(_ document: FloeCADDocument) throws {
        guard !document.isClosed, !document.isReadOnly, document.session.writeBlock == nil,
              document.session.document.features.rollbackIndex == nil,
              document.pendingOwnedCommand == nil else {
            throw CADBuildingError.invalid(CAD2DDraftingText.text(
                "当前文档无法编辑，请先结束正在进行的操作。", "Finish the current operation before editing this document."))
        }
    }

    init(document: FloeCADDocument, storeyID: UUID, initialBuilding: CADBuildingDocument? = nil) throws {
        try Self.requireWritable(document)
        let model = document.viewModel()
        switch model.mode {
        case .idle, .sketching, .selected, .faceSelected, .editingPrimitive: break
        default:
            throw CADBuildingError.invalid(CAD2DDraftingText.text(
                "请先完成或取消当前 CAD 操作。", "Finish or cancel the current CAD operation first."))
        }
        guard model.buildingDraftingOwner == nil,
              model.sculptEditingBody == nil, model.polygonCageEditingBody == nil,
              !model.faceMoveActive, !model.faceScaleActive, !model.faceRotateActive else {
            throw CADBuildingError.invalid(CAD2DDraftingText.text(
                "请先结束当前模型编辑。", "Finish the current model edit first."))
        }
        guard !model.hasUnfinishedBuildingDraftingInput || model.activeSketch?.id == Self.sketchID(for: storeyID) else {
            throw CADBuildingError.invalid(CAD2DDraftingText.text(
                "请先完成或取消当前 CAD 输入。", "Finish or cancel the current CAD input first."))
        }
        self.document = document; self.storeyID = storeyID; self.initialBuilding = initialBuilding
        let wasPermanent = model.permanentDraftingNavigationOnly
        previousPermanentNavigation = wasPermanent
        previousSketch = wasPermanent ? model.activeSketch?.id : nil
        previousOrthographic = model.orthographicEnabled
        previousCameraBeforeSketchNavigation = model.cameraBeforeSketchNavigation
        previousCamera = model.cameraBeforeSketchNavigation
            ?? (model.cameraControl as? ViewportCoordinator)?.renderer?.camera
        // Preflight before ending another sketch or committing any new input.
        _ = try target(for: storeyID)
        try ensureActiveSketch()
        model.buildingDraftingOwner = self
    }

    /// The common active-sketch read also fences keyboard, pointer and Pencil
    /// paths. Cache by the real document generation, not by a view refresh.
    func permitsEditing(_ id: SketchID) -> Bool {
        guard isActive, checkpointID == nil, !document.isClosed, id == sketchID else { return false }
        let generation = document.buildingChangeCount
        if checkedGeneration != generation || checkedFloor != storeyID {
            checkedGeneration = generation; checkedFloor = storeyID; checkedAllowed = false
            if let building = try? document.building(),
               let floor = building.storeys.first(where: { $0.id == storeyID }),
               let sketch = document.session.document.sketches.first(where: { $0.id == id }) {
                checkedAllowed = sketch.plane == .offsetGround(y: floor.elevationMM) && sketch.support == nil
            }
        }
        return checkedAllowed
    }

    private func target(for id: UUID) throws -> (CADBuildingDocument, CADBuildingStorey, Sketch?) {
        guard !document.isClosed else { throw CADBuildingError.invalid(text("工程已关闭。", "The project is closed.")) }
        let existing = try document.building()
        guard let building = existing ?? initialBuilding,
              existing != nil || (building.elements.isEmpty && building.sources.isEmpty) else {
            throw CADBuildingError.invalid(text("请先设置建筑楼层。", "Set up a building floor first."))
        }
        try building.validate()
        guard let floor = building.storeys.first(where: { $0.id == id }) else {
            throw CADBuildingError.invalid(text("所选楼层已不存在，请重新选择。", "The selected floor is missing. Choose another floor."))
        }
        let sketch = document.session.document.sketches.first { $0.id == Self.sketchID(for: id) }
        return (building, floor, sketch)
    }

    /// Called by both drafting tool surfaces before arming a tool. Undoing
    /// sketch creation stays undone until the user explicitly draws again.
    func ensureActiveSketch() throws {
        guard isActive else { throw CADBuildingError.invalid(text("二维编辑已结束。", "The drafting session ended.")) }
        guard checkpointID == nil else { throw CADBuildingError.invalid(text("工程正在保存。", "The project is being saved.")) }
        try Self.requireWritable(document)
        let (building, floor, existing) = try target(for: storeyID)
        let plane = SketchPlane.offsetGround(y: floor.elevationMM)
        if let existing {
            guard existing.plane == plane, existing.support == nil else {
                refresh(); throw CADBuildingError.invalid(issue ?? text("请检查线稿平面。", "Review the drawing plane."))
            }
        } else {
            var commands: [DocumentCommand] = []
            if try document.building() == nil {
                commands.append(SetBuildingDataCommand(before: nil, after: try building.encoded()))
            }
            commands.append(AddSketchCommand(sketch: Sketch(id: sketchID,
                name: floor.name + " · " + text("二维线稿", "2D drawing"), plane: plane),
                title: text("楼层线稿", "Floor drawing")))
            guard document.session.performAssociativeTransaction(commands,
                title: text("创建楼层线稿", "Create floor drawing"), strictValidation: true),
                  document.session.document.sketches.contains(where: { $0.id == sketchID }) else {
                throw CADBuildingError.invalid(text("未能创建楼层线稿，原工程已保留。", "The floor drawing could not be created. The project was retained."))
            }
        }
        let model = document.viewModel()
        let changedSketch = model.activeSketch?.id != sketchID
        model.openItemSketch(sketchID)
        model.planarNavigationOnly = true
        if changedSketch { model.requestDraftingCamera(for: plane) }
        issue = nil; canMoveToFloor = false; reviewedChangeCount = nil
    }

    func selectStorey(_ id: UUID) throws {
        guard isActive else { throw CADBuildingError.invalid(text("二维编辑已结束。", "The drafting session ended.")) }
        guard checkpointID == nil else { throw CADBuildingError.invalid(text("工程正在保存。", "The project is being saved.")) }
        if id == storeyID { return }
        guard !document.viewModel().hasUnfinishedBuildingDraftingInput else {
            throw CADBuildingError.invalid(text("请先完成或取消当前二维输入，再切换楼层。", "Finish or cancel the current drafting input before changing floors."))
        }
        let (_, floor, sketch) = try target(for: id)
        guard sketch == nil || (sketch?.plane == .offsetGround(y: floor.elevationMM) && sketch?.support == nil) else {
            throw CADBuildingError.invalid(text("该楼层线稿的平面已改变，请先核对。", "Review this floor drawing's changed plane first."))
        }
        let previous = storeyID
        // Settle the old floor while it still owns the active-sketch read.
        if document.viewModel().mode.isSketching { document.viewModel().finishSketch() }
        storeyID = id
        do { try ensureActiveSketch() }
        catch { storeyID = previous; refresh(); throw error }
    }

    /// Read-only reconciliation after native commands, undo or floor changes.
    /// Never re-creates a sketch or clears redo merely because a view updates.
    func refresh() {
        canMoveToFloor = false
        guard isActive, !document.isClosed else { return }
        do {
            let (_, floor, sketch) = try target(for: storeyID)
            guard let sketch else { issue = nil; reviewedChangeCount = nil; return }
            guard sketch.plane == .offsetGround(y: floor.elevationMM), sketch.support == nil else {
                issue = text("线稿平面与楼层标高不一致。请核对后移动线稿，或切换楼层。", "The drawing plane differs from this floor's elevation. Review it before moving the drawing or changing floors.")
                if reviewedChangeCount == nil { reviewedChangeCount = document.buildingChangeCount }
                canMoveToFloor = sketch.support == nil && (sketch.externalReferences?.isEmpty ?? true)
                    && reviewedChangeCount == document.buildingChangeCount
                return
            }
            issue = nil; reviewedChangeCount = nil
        } catch { issue = error.localizedDescription }
    }

    func reviewPlane() { reviewedChangeCount = nil; refresh() }

    /// Explicit, generation-fenced rehost. Local geometry and dimensions keep
    /// their IDs; the existing associative transaction validates dependencies.
    func moveDrawingToCurrentFloor() throws {
        try Self.requireWritable(document)
        guard isActive, checkpointID == nil, canMoveToFloor, reviewedChangeCount == document.buildingChangeCount else {
            throw CADBuildingError.invalid(text("工程已改变，请重新核对线稿平面。", "The project changed. Review the drawing plane again."))
        }
        let (_, floor, existing) = try target(for: storeyID)
        guard let existing, existing.support == nil, existing.externalReferences?.isEmpty ?? true else {
            throw CADBuildingError.invalid(text("请先处理线稿的外部关联。", "Resolve the drawing's external references first."))
        }
        let plane = SketchPlane.offsetGround(y: floor.elevationMM)
        guard document.session.performAssociativeTransaction([ChangeSketchPlaneCommand(sketch: existing, after: plane)],
            title: text("移动楼层线稿", "Move floor drawing"), strictValidation: true) else {
            throw CADBuildingError.invalid(text("线稿未能移动，原工程已保留。", "The drawing could not be moved. The project was retained."))
        }
        try ensureActiveSketch()
        document.viewModel().requestDraftingCamera(for: plane)
    }

    /// A departed floor view cannot later re-arm tools on another mount.
    func end() {
        guard isActive else { return }; isActive = false
        guard checkpointID == nil else { return }
        restoreAfterDeparture()
    }

    private func restoreAfterDeparture() {
        guard !document.isClosed else { return }
        let model = document.viewModel()
        guard model.buildingDraftingOwner === self else { return }
        model.buildingDraftingOwner = nil
        model.draftingPlaneOnViewportBind = nil
        let unfinished = model.hasUnfinishedBuildingDraftingInput
        if !unfinished, model.mode.isSketching { model.finishSketch() }
        model.cameraBeforeSketchNavigation = previousPermanentNavigation ? previousCameraBeforeSketchNavigation : previousCamera
        if !unfinished { model.orthographicEnabled = previousOrthographic }
        model.planarNavigationOnly = previousPermanentNavigation
        if !unfinished, previousPermanentNavigation, let previousSketch,
           document.session.document.sketches.contains(where: { $0.id == previousSketch }) {
            model.openItemSketch(previousSketch)
        }
        model.cameraControl?.setNavigationLock(draftingOnly: previousPermanentNavigation, sketchPlane: model.activeSketch?.plane)
        if !unfinished, previousPermanentNavigation, let previousCamera,
           let viewport = model.cameraControl as? ViewportCoordinator {
            viewport.renderer?.camera = previousCamera
        }
    }

    func beginCheckpoint() throws -> CADBuildingDraftingCheckpoint {
        guard isActive, checkpointID == nil, !document.isClosed else {
            throw CADBuildingError.invalid(text("当前二维编辑尚未结束保存。", "The current drafting session is still finishing a save."))
        }
        guard !document.viewModel().hasUnfinishedBuildingDraftingInput else {
            throw CADBuildingError.invalid(text("请先完成或取消当前二维输入，再保存工程。", "Finish or cancel the current drafting input before saving the project."))
        }
        let identifier = UUID(); checkpointID = identifier
        return CADBuildingDraftingCheckpoint(owner: self, identifier: identifier)
    }

    fileprivate func finishCheckpoint(_ identifier: UUID) {
        guard checkpointID == identifier else { return }
        checkpointID = nil
        if !isActive { restoreAfterDeparture() }
    }
}

/// Keeps the departing view's drafting owner alive until the project snapshot
/// finishes. The project owner releases this in defer on success and failure.
@MainActor
public final class CADBuildingDraftingCheckpoint {
    private var owner: CADBuildingDraftingSession?
    private let identifier: UUID
    fileprivate init(owner: CADBuildingDraftingSession, identifier: UUID) {
        self.owner = owner; self.identifier = identifier
    }
    public func finish() {
        guard let owner else { return }; self.owner = nil
        owner.finishCheckpoint(identifier)
    }
}

@MainActor
public extension FloeCADDocument {
    /// No-op outside the building's drafting entrance. Never publishes a
    /// generation or creates a separate persistence/permission service.
    func beginBuildingDraftingCheckpoint() throws -> CADBuildingDraftingCheckpoint? {
        guard !isClosed else { throw CADBuildingError.invalid(CAD2DDraftingText.text("工程已关闭。", "The project is closed.")) }
        guard !hasUnfinishedBuildingDraftingInput else {
            throw CADBuildingError.invalid(CAD2DDraftingText.text(
                "请在平面与模型中完成或取消当前 CAD 输入，再保存工程。", "Finish or cancel the current CAD input in Plan & model before saving the project."))
        }
        return try currentBuildingDraftingOwner?.beginCheckpoint()
    }
}
#endif
