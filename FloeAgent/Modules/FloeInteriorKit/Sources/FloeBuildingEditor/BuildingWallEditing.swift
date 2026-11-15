// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import FloeCAD
import FloeBuildingCAD
import FloeInteriorCore
import FloeBuildingRecords

/// A bounded view of the current native building walls plus the project-level
/// face finishes. Geometry is always the live CAD document; finishes are the
/// editor-state assignment keyed by the same wall IDs.
public struct BuildingWallSnapshot: Codable, Sendable, Equatable {
    public struct Storey: Codable, Sendable, Equatable, Identifiable {
        public let id: UUID
        public let name: String
        public let elevationMM: Double
        public let heightMM: Double
    }
    public struct Wall: Codable, Sendable, Equatable, Identifiable {
        public let id: UUID
        public let name: String
        public let storeyID: UUID
        public let a: [Double]
        public let b: [Double]
        public let thicknessMM: Double
        public let heightMM: Double
        public let baseOffsetMM: Double
        public let leftFinishID: String?
        public let rightFinishID: String?
        public let leftFinishName: String?
        public let rightFinishName: String?
        public let leftFinishColorHex: String?
        public let rightFinishColorHex: String?
    }
    public let recordsProjectID: ProjectID
    public let generationID: String?
    public let recordsRevision: Int
    public let changeCount: Int
    /// CAS token covering both geometry and face finishes. Finish-only edits
    /// advance this value even though the native building change count does
    /// not, so two concurrent finish edits cannot both pass the same fence.
    public let wallRevision: Int
    public let storeys: [Storey]
    public let walls: [Wall]
    public let finishCatalog: [InteriorWallFinish]
}

public struct BuildingWallEditResult: Sendable, Equatable {
    public let changeCount: Int
    public let wallRevision: Int
    public let wallID: UUID?
    public let generationID: String?
    public let recordsRevision: Int
}

public enum BuildingWallCommand: Sendable, Equatable {
    case addWall(storeyID: UUID?, a: [Double], b: [Double],
                 thicknessMM: Double?, heightMM: Double?, name: String?)
    case moveEndpoint(wallID: UUID, end: InteriorWallEndpoint, point: [Double])
    case updateWall(wallID: UUID, thicknessMM: Double?, heightMM: Double?, name: String?)
    case deleteWall(wallID: UUID)
    case setFinish(wallID: UUID, side: InteriorWallSide, finishID: String?)
    case swapFinishes(wallID: UUID)
}

/// One accepted wall command. The before/after finish arrays and change counts
/// let undo restore both the native geometry and the project-level faces. A
/// record is only applied while the live building change count still matches
/// `afterChangeCount`, so an interleaved CAD edit refuses the undo instead of
/// reverting the wrong wall.
struct BuildingWallHistoryEntry: Equatable {
    let beforeFinishes: [InteriorWallFinishAssignment]
    let afterFinishes: [InteriorWallFinishAssignment]
    let beforeChangeCount: Int
    let afterChangeCount: Int
    let geometryChanged: Bool
}

public extension BuildingEditorProjectSession {
    /// Current walls and finish catalog, used by the plan editor and by
    /// registered `studio.read` discovery.
    func wallSnapshot() throws -> BuildingWallSnapshot {
        guard !closed else { throw BuildingEditorProjectError.closed }
        let currentChange = cad.document.buildingChangeCount
        if let last = lastObservedWallChangeCount, last != currentChange {
            // Another CAD surface edited the building. The paired history no
            // longer describes the live model; refuse stale undo rather than
            // restoring a finish to a different wall.
            wallUndoRecords.removeAll()
            wallRedoRecords.removeAll()
        }
        lastObservedWallChangeCount = currentChange
        let building = try cad.building()
        let finishes = Dictionary(uniqueKeysWithValues: state.wallFinishes.map { ($0.wallID, $0) })
        let catalog = InteriorWallFinishCatalog.all
        let walls = (building?.elements ?? [])
            .filter { $0.kind == .wall }
            .map { element -> BuildingWallSnapshot.Wall in
                let assignment = finishes[element.id]
                let left = assignment?.left.flatMap(InteriorWallFinishCatalog.finish)
                let right = assignment?.right.flatMap(InteriorWallFinishCatalog.finish)
                return .init(
                    id: element.id,
                    name: element.name,
                    storeyID: element.storeyID,
                    a: element.a,
                    b: element.b,
                    thicknessMM: element.thicknessMM,
                    heightMM: element.heightMM,
                    baseOffsetMM: element.baseOffsetMM,
                    leftFinishID: left?.id,
                    rightFinishID: right?.id,
                    leftFinishName: left?.nameEN,
                    rightFinishName: right?.nameEN,
                    leftFinishColorHex: left?.colorHex,
                    rightFinishColorHex: right?.colorHex
                )
            }
        return BuildingWallSnapshot(
            recordsProjectID: projectID,
            generationID: published?.generationID,
            recordsRevision: recordsRevision,
            changeCount: currentChange,
            wallRevision: state.wallRevision,
            storeys: (building?.storeys ?? []).map {
                .init(id: $0.id, name: $0.name, elevationMM: $0.elevationMM, heightMM: $0.heightMM)
            },
            walls: walls,
            finishCatalog: catalog
        )
    }

    /// Apply one typed wall command against the exact wall revision and
    /// building change count the caller read. Geometry uses the existing
    /// single native Building transaction; finish-only changes advance the
    /// project wall revision and write the same editor state.
    @discardableResult
    func applyWallCommand(_ command: BuildingWallCommand,
                          expectedChangeCount: Int,
                          expectedWallRevision: Int) async throws -> BuildingWallEditResult {
        guard !closed else { throw BuildingEditorProjectError.closed }
        guard !busy else { throw BuildingEditorProjectError.busy }
        busy = true
        defer { busy = false }
        let actual = cad.document.buildingChangeCount
        guard actual == expectedChangeCount else { throw BuildingEditorProjectError.staleBuilding }
        guard state.wallRevision == expectedWallRevision else { throw BuildingEditorProjectError.staleBuilding }

        var model = try cad.building() ?? CADBuildingDocument(name: cad.document.name)
        var finishes = state.wallFinishes
        let beforeFinishes = finishes
        var changedGeometry = false
        var resultWallID: UUID?
        var noChange = false

        switch command {
        case let .addWall(storeyID, a, b, thicknessMM, heightMM, name):
            guard Self.validPlanPoint(a), Self.validPlanPoint(b),
                  hypot(b[0] - a[0], b[1] - a[1]) >= 1 else {
                throw FloeBuildingCADError.invalidInput("Use two finite wall points at least 1 mm apart.")
            }
            let storey: CADBuildingStorey
            if let storeyID {
                guard let found = model.storeys.first(where: { $0.id == storeyID }) else {
                    throw FloeBuildingCADError.invalidInput("The selected floor is not in this building.")
                }
                storey = found
            } else {
                storey = model.storeys[0]
            }
            let thickness = thicknessMM ?? 200
            let height = heightMM ?? storey.heightMM
            guard Self.validDimension(thickness), Self.validDimension(height) else {
                throw FloeBuildingCADError.invalidInput("Use a wall thickness and height between 1 and 100000 mm.")
            }
            let element = CADBuildingElement(
                storeyID: storey.id,
                kind: .wall,
                name: Self.validName(name) ?? "Wall \(model.elements.count + 1)",
                a: a,
                b: b,
                thicknessMM: thickness,
                heightMM: height
            )
            model.elements.append(element)
            resultWallID = element.id
            changedGeometry = true

        case let .moveEndpoint(wallID, end, point):
            guard let index = model.elements.firstIndex(where: { $0.id == wallID && $0.kind == .wall }) else {
                throw FloeBuildingCADError.invalidInput("The wall no longer exists in this building.")
            }
            let element = model.elements[index]
            guard let moved = InteriorWallPlanGeometry.movedEndpoint(
                .init(a: element.a, b: element.b, thicknessMM: element.thicknessMM),
                end: end,
                to: point
            ) else {
                throw FloeBuildingCADError.invalidInput("Use a finite endpoint that keeps the wall at least 1 mm long.")
            }
            model.elements[index].a = moved.0
            model.elements[index].b = moved.1
            resultWallID = wallID
            changedGeometry = true

        case let .updateWall(wallID, thicknessMM, heightMM, name):
            guard let index = model.elements.firstIndex(where: { $0.id == wallID && $0.kind == .wall }) else {
                throw FloeBuildingCADError.invalidInput("The wall no longer exists in this building.")
            }
            if let thicknessMM {
                guard Self.validDimension(thicknessMM) else {
                    throw FloeBuildingCADError.invalidInput("Use a wall thickness between 1 and 100000 mm.")
                }
                model.elements[index].thicknessMM = thicknessMM
            }
            if let heightMM {
                guard Self.validDimension(heightMM) else {
                    throw FloeBuildingCADError.invalidInput("Use a wall height between 1 and 100000 mm.")
                }
                model.elements[index].heightMM = heightMM
                for openingIndex in model.elements.indices
                where model.elements[openingIndex].hostID == wallID {
                    guard model.elements[openingIndex].baseOffsetMM + model.elements[openingIndex].heightMM <= heightMM else {
                        throw FloeBuildingCADError.invalidInput(
                            "The new wall height is shorter than one of its hosted openings."
                        )
                    }
                }
            }
            if let name {
                guard let valid = Self.validName(name) else {
                    throw FloeBuildingCADError.invalidInput("Use a non-empty wall name.")
                }
                model.elements[index].name = valid
            }
            resultWallID = wallID
            changedGeometry = true

        case .deleteWall(let wallID):
            guard model.elements.contains(where: { $0.id == wallID && $0.kind == .wall }) else {
                throw FloeBuildingCADError.invalidInput("The wall no longer exists in this building.")
            }
            model.elements.removeAll { $0.id == wallID || $0.hostID == wallID }
            finishes.removeAll { $0.wallID == wallID }
            resultWallID = wallID
            changedGeometry = true

        case let .setFinish(wallID, side, finishID):
            guard model.elements.contains(where: { $0.id == wallID && $0.kind == .wall }) else {
                throw FloeBuildingCADError.invalidInput("The wall no longer exists in this building.")
            }
            if let finishID, InteriorWallFinishCatalog.finish(id: finishID) == nil {
                throw FloeBuildingCADError.invalidInput("Choose a finish from interiorWallFinishes.")
            }
            var assignment = finishes.first(where: { $0.wallID == wallID })
                ?? InteriorWallFinishAssignment(wallID: wallID)
            guard finishID != assignment.finishID(for: side) else {
                noChange = true
                break
            }
            assignment.set(finishID, for: side)
            finishes.removeAll { $0.wallID == wallID }
            if !assignment.isEmpty { finishes.append(try assignment.validated()) }
            resultWallID = wallID

        case .swapFinishes(let wallID):
            guard model.elements.contains(where: { $0.id == wallID && $0.kind == .wall }) else {
                throw FloeBuildingCADError.invalidInput("The wall no longer exists in this building.")
            }
            guard var assignment = finishes.first(where: { $0.wallID == wallID }) else {
                noChange = true
                break
            }
            assignment.swapSides()
            finishes.removeAll { $0.wallID == wallID }
            if !assignment.isEmpty { finishes.append(try assignment.validated()) }
            resultWallID = wallID
        }

        if noChange {
            return BuildingWallEditResult(changeCount: actual, wallRevision: state.wallRevision,
                wallID: resultWallID, generationID: published?.generationID,
                recordsRevision: recordsRevision)
        }

        if changedGeometry {
            try cad.document.setBuilding(model, expectedChangeCount: actual)
            try refreshBuildingReferences()
            model = try cad.building() ?? model
        }
        let validWalls = Set(model.elements.filter { $0.kind == .wall }.map(\.id))
        var seen: Set<UUID> = []
        var pruned: [InteriorWallFinishAssignment] = []
        for assignment in finishes {
            guard validWalls.contains(assignment.wallID), seen.insert(assignment.wallID).inserted else { continue }
            let validated = try assignment.validated()
            if !validated.isEmpty { pruned.append(validated) }
        }
        state.wallFinishes = pruned
        let afterChange = cad.document.buildingChangeCount
        if beforeFinishes != pruned || actual != afterChange {
            wallUndoRecords.append(BuildingWallHistoryEntry(
                beforeFinishes: beforeFinishes,
                afterFinishes: pruned,
                beforeChangeCount: actual,
                afterChangeCount: afterChange,
                geometryChanged: changedGeometry
            ))
            if wallUndoRecords.count > 256 { wallUndoRecords.removeFirst(wallUndoRecords.count - 256) }
            wallRedoRecords.removeAll()
        }
        state.wallRevision += 1
        lastObservedWallChangeCount = afterChange
        try retainNativeReferences()
        return BuildingWallEditResult(
            changeCount: afterChange,
            wallRevision: state.wallRevision,
            wallID: resultWallID,
            generationID: published?.generationID,
            recordsRevision: recordsRevision
        )
    }

    /// Unified undo for wall geometry and face finishes. It refuses when the
    /// live change count or wall revision moved, so an interleaved edit cannot
    /// be mistaken for the previous wall step.
    @discardableResult
    func undoWallChange(expectedChangeCount: Int, expectedWallRevision: Int) throws -> BuildingWallEditResult {
        guard !closed else { throw BuildingEditorProjectError.closed }
        guard !busy else { throw BuildingEditorProjectError.busy }
        let actual = cad.document.buildingChangeCount
        guard actual == expectedChangeCount, state.wallRevision == expectedWallRevision else {
            clearWallHistory()
            throw BuildingEditorProjectError.staleBuilding
        }
        guard let record = wallUndoRecords.last, record.afterChangeCount == actual else {
            clearWallHistory()
            throw FloeBuildingCADError.invalidInput("This wall history is stale; no earlier wall change was undone.")
        }
        if record.geometryChanged {
            guard cad.document.canUndo else {
                throw FloeBuildingCADError.invalidInput("There is no native change to undo.")
            }
            cad.document.undo()
            guard cad.document.buildingChangeCount == record.beforeChangeCount else {
                clearWallHistory()
                throw BuildingEditorProjectError.staleBuilding
            }
            try refreshBuildingReferences()
        }
        state.wallFinishes = record.beforeFinishes
        state.wallRevision += 1
        lastObservedWallChangeCount = cad.document.buildingChangeCount
        try retainNativeReferences()
        wallUndoRecords.removeLast()
        wallRedoRecords.append(record)
        return BuildingWallEditResult(
            changeCount: cad.document.buildingChangeCount,
            wallRevision: state.wallRevision,
            wallID: nil,
            generationID: published?.generationID,
            recordsRevision: recordsRevision
        )
    }

    @discardableResult
    func redoWallChange(expectedChangeCount: Int, expectedWallRevision: Int) throws -> BuildingWallEditResult {
        guard !closed else { throw BuildingEditorProjectError.closed }
        guard !busy else { throw BuildingEditorProjectError.busy }
        let actual = cad.document.buildingChangeCount
        guard actual == expectedChangeCount, state.wallRevision == expectedWallRevision else {
            clearWallHistory()
            throw BuildingEditorProjectError.staleBuilding
        }
        guard let record = wallRedoRecords.last, record.beforeChangeCount == actual else {
            clearWallHistory()
            throw FloeBuildingCADError.invalidInput("This wall history is stale; no later wall change was redone.")
        }
        if record.geometryChanged {
            guard cad.document.canRedo else {
                throw FloeBuildingCADError.invalidInput("There is no native change to redo.")
            }
            cad.document.redo()
            guard cad.document.buildingChangeCount == record.afterChangeCount else {
                clearWallHistory()
                throw BuildingEditorProjectError.staleBuilding
            }
            try refreshBuildingReferences()
        }
        state.wallFinishes = record.afterFinishes
        state.wallRevision += 1
        lastObservedWallChangeCount = cad.document.buildingChangeCount
        try retainNativeReferences()
        wallRedoRecords.removeLast()
        wallUndoRecords.append(record)
        return BuildingWallEditResult(
            changeCount: cad.document.buildingChangeCount,
            wallRevision: state.wallRevision,
            wallID: nil,
            generationID: published?.generationID,
            recordsRevision: recordsRevision
        )
    }

    private static func validPlanPoint(_ point: [Double]) -> Bool {
        point.count == 2 && point.allSatisfy { $0.isFinite && abs($0) <= 10_000_000 }
    }

    private static func validDimension(_ value: Double) -> Bool {
        value.isFinite && (1...100_000).contains(value)
    }

    private static func validName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.utf8.count > 1024 ? nil : trimmed
    }
}
#endif
