// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import FloeCAD
import FloeInteriorCore

// MARK: - Basic building authoring

public extension FloeBuildingCADSession {
    func building() throws -> CADBuildingDocument? {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        return try document.building()
    }

    /// Create a basic building with rectangular rooms, four explicit walls per
    /// room, hosted doors/windows and multiple storeys. Geometry and semantics
    /// are one native `setBuilding` transaction; no synthetic duplicate room
    /// body is created by this bridge.
    func createBuilding(_ spec: FloeBuildingCADSpec) async throws -> FloeBuildingCADBuildingBinding {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        guard !document.isReadOnly else { throw FloeBuildingCADError.readOnly }
        guard try document.building() == nil else {
            throw FloeBuildingCADError.invalidInput("This document already has a building; edit it with applyBuilding instead.")
        }
        let built = try FloeBuildingCADBuildingAuthoring.model(from: spec)
        let model = built.model
        return try await withMutationRollback { lease in
            _ = try withOwnedWrite(lease) {
                try document.setBuilding(model, expectedChangeCount: document.buildingChangeCount)
            }
            try lease.verifyOwnership()
            let identity = try await saveUnlocked()
            try lease.verifyOwnership()
            let binding = FloeBuildingCADBuildingAuthoring.binding(
                rooms: built.rooms, model: model, identity: identity)
            putBuilding(binding)
            return binding
        }
    }

    /// Apply an edited native building model through the existing single
    /// Building transaction. Element/storey ids stay authoritative; a failed
    /// rebuild or save restores the native generation this bridge started from.
    func applyBuilding(_ model: CADBuildingDocument,
                       expectedChangeCount: Int? = nil) async throws -> FloeBuildingCADBuildingBinding {
        guard !document.isClosed else { throw FloeBuildingCADError.documentClosed }
        guard !document.isReadOnly else { throw FloeBuildingCADError.readOnly }
        try model.validate()
        let fence = expectedChangeCount ?? document.buildingChangeCount
        return try await withMutationRollback { lease in
            _ = try withOwnedWrite(lease) {
                try document.setBuilding(model, expectedChangeCount: fence)
            }
            try lease.verifyOwnership()
            let identity = try await saveUnlocked()
            try lease.verifyOwnership()
            let elementIDs = Set(model.elements.map(\.id))
            let previousRooms = Dictionary(uniqueKeysWithValues:
                (manifest.building?.rooms ?? []).map { ($0.roomID, $0) })
            // Always project the CURRENT space elements. Never use an old
            // room list as the source of rooms: that would drop a newly added
            // space and keep stale names/storeys. Stable wall/opening ids are
            // retained only while the referenced element still exists.
            let rooms = model.elements
                .filter { $0.kind == .space }
                .map { element -> FloeBuildingCADRoomBinding in
                    let old = previousRooms[element.id]
                    return FloeBuildingCADRoomBinding(
                        roomID: element.id,
                        name: element.name,
                        storeyID: element.storeyID,
                        wallIDs: (old?.wallIDs ?? []).filter { elementIDs.contains($0) },
                        openingIDs: (old?.openingIDs ?? []).filter { elementIDs.contains($0) })
                }
            let binding = FloeBuildingCADBuildingBinding(
                buildingID: model.id, name: model.name,
                storeyIDs: model.storeys.map(\.id),
                elementIDs: model.elements.map(\.id),
                rooms: rooms, nativeIdentity: identity)
            putBuilding(binding)
            return binding
        }
    }
}

// MARK: - Synchronous authoring value

nonisolated enum FloeBuildingCADBuildingAuthoring {
    struct BuildResult {
        var model: CADBuildingDocument
        var rooms: [FloeBuildingCADRoomBinding]
    }

    private struct WallCandidate {
        var roomID: UUID
        var roomName: String
        var storeyID: UUID
        var index: Int
        var name: String
        var a: [Double]
        var b: [Double]
        var thicknessMM: Double
        var heightMM: Double
        var baseOffsetMM: Double
        var candidateID: UUID
    }

    private struct WallGroup {
        var members: [WallCandidate]
        var id: UUID
        var a: [Double]
        var b: [Double]
    }

    private struct RoomWallReference {
        var groupID: UUID
        var canonicalA: [Double]
        var canonicalB: [Double]
        var reversed: Bool
    }

    static func model(from spec: FloeBuildingCADSpec) throws -> BuildResult {
        try validate(spec)
        var model = CADBuildingDocument(name: spec.name)
        model.id = spec.id
        model.storeys = spec.storeys.map { storey in
            var value = CADBuildingStorey(name: storey.name,
                                          elevationMM: storey.elevationMM,
                                          heightMM: storey.heightMM)
            value.id = storey.id
            return value
        }

        // Build every room's four wall candidates first; exact coincident
        // same-storey/same-thickness/same-height walls are one native wall.
        var candidates: [WallCandidate] = []
        for storey in spec.storeys {
            for room in storey.rooms {
                let h = room.wallThicknessMM / 2
                let u0 = room.minimum[0] - h, u1 = room.maximum[0] + h
                let v0 = room.minimum[1] - h, v1 = room.maximum[1] + h
                let lines: [([Double], [Double])] = [
                    ([u0, v0], [u1, v0]),
                    ([u1, v0], [u1, v1]),
                    ([u1, v1], [u0, v1]),
                    ([u0, v1], [u0, v0]),
                ]
                for (index, line) in lines.enumerated() {
                    candidates.append(WallCandidate(
                        roomID: room.id, roomName: room.name,
                        storeyID: storey.id, index: index,
                        name: "\(room.name) · Wall \(index + 1)",
                        a: line.0, b: line.1,
                        thicknessMM: room.wallThicknessMM,
                        heightMM: room.heightMM, baseOffsetMM: 0,
                        candidateID: FloeBuildingCADGeometry.stableUUID(
                            "\(room.id.uuidString)|wall|\(index)")))
                }
            }
        }
        try rejectPartialOrConflictingOverlaps(candidates)
        var groups: [WallGroup] = []
        for candidate in candidates {
            if let index = groups.firstIndex(where: { group in
                exactSameWall(group.members[0], candidate)
            }) {
                groups[index].members.append(candidate)
                if candidate.candidateID.uuidString < groups[index].id.uuidString {
                    groups[index].id = candidate.candidateID
                }
            } else {
                let ordered = orderedEndpoints(candidate.a, candidate.b)
                groups.append(WallGroup(members: [candidate], id: candidate.candidateID,
                                        a: ordered.0, b: ordered.1))
            }
        }
        var groupByCandidate: [UUID: UUID] = [:]
        for group in groups {
            for member in group.members { groupByCandidate[member.candidateID] = group.id }
            var wall = CADBuildingElement(
                storeyID: group.members[0].storeyID, kind: .wall,
                name: group.members[0].name, a: group.a, b: group.b,
                thicknessMM: group.members[0].thicknessMM,
                heightMM: group.members[0].heightMM,
                baseOffsetMM: group.members[0].baseOffsetMM)
            wall.id = group.id
            model.elements.append(wall)
        }

        // Room spaces and their per-room wall references; openings use the
        // canonical host direction so a reversed shared wall keeps the exact
        // authored opening location.
        var roomBindings: [FloeBuildingCADRoomBinding] = []
        for storey in spec.storeys {
            for room in storey.rooms {
                var space = CADBuildingElement(
                    storeyID: storey.id, kind: .space, name: room.name,
                    a: room.minimum, b: room.maximum,
                    thicknessMM: room.wallThicknessMM, heightMM: room.heightMM,
                    baseOffsetMM: 0)
                space.id = room.id
                model.elements.append(space)
                var refs: [RoomWallReference] = []
                for index in 0..<4 {
                    let candidateID = FloeBuildingCADGeometry.stableUUID(
                        "\(room.id.uuidString)|wall|\(index)")
                    guard let groupID = groupByCandidate[candidateID],
                          let group = groups.first(where: { $0.id == groupID }) else {
                        throw FloeBuildingCADError.invalidInput("A room wall has no canonical group.")
                    }
                    let candidate = group.members.first {
                        $0.roomID == room.id && $0.index == index
                    } ?? group.members[0]
                    let dot = (candidate.b[0] - candidate.a[0]) * (group.b[0] - group.a[0])
                        + (candidate.b[1] - candidate.a[1]) * (group.b[1] - group.a[1])
                    refs.append(RoomWallReference(
                        groupID: group.id, canonicalA: group.a, canonicalB: group.b,
                        reversed: dot < 0))
                }
                for opening in room.openings {
                    let ref = refs[opening.wallIndex]
                    let dx = ref.canonicalB[0] - ref.canonicalA[0]
                    let dy = ref.canonicalB[1] - ref.canonicalA[1]
                    let length = hypot(dx, dy)
                    guard length > 0.1 else {
                        throw FloeBuildingCADError.invalidInput(
                            "Room \(room.name) has a degenerate shared wall.")
                    }
                    let canonicalOffset = ref.reversed
                        ? length - (opening.offsetMM + opening.widthMM)
                        : opening.offsetMM
                    guard canonicalOffset >= -1e-6,
                          canonicalOffset + opening.widthMM <= length + 1e-6 else {
                        throw FloeBuildingCADError.invalidInput(
                            "Opening \(opening.name) does not fit the canonical shared wall.")
                    }
                    let ux = dx / length, uy = dy / length
                    let start = [ref.canonicalA[0] + ux * canonicalOffset,
                                 ref.canonicalA[1] + uy * canonicalOffset]
                    let end = [ref.canonicalA[0] + ux * (canonicalOffset + opening.widthMM),
                               ref.canonicalA[1] + uy * (canonicalOffset + opening.widthMM)]
                    var element = CADBuildingElement(
                        storeyID: storey.id,
                        kind: opening.kind == .door ? .door : .window,
                        name: opening.name,
                        a: start, b: end,
                        thicknessMM: opening.kind == .door ? 40 : 20,
                        heightMM: opening.heightMM,
                        baseOffsetMM: opening.baseOffsetMM,
                        hostID: ref.groupID,
                        offsetMM: canonicalOffset,
                        widthMM: opening.widthMM)
                    element.id = opening.id
                    model.elements.append(element)
                }
                roomBindings.append(FloeBuildingCADRoomBinding(
                    roomID: room.id, name: room.name, storeyID: storey.id,
                    wallIDs: refs.map(\.groupID),
                    openingIDs: room.openings.map(\.id)))
            }
        }
        try model.validate()
        return BuildResult(model: model, rooms: roomBindings)
    }

    static func binding(rooms: [FloeBuildingCADRoomBinding],
                        model: CADBuildingDocument,
                        identity: FloeBuildingCADNativeIdentity) -> FloeBuildingCADBuildingBinding {
        FloeBuildingCADBuildingBinding(
            buildingID: model.id, name: model.name,
            storeyIDs: model.storeys.map(\.id),
            elementIDs: model.elements.map(\.id),
            rooms: rooms, nativeIdentity: identity)
    }

    private static func orderedEndpoints(_ a: [Double], _ b: [Double])
        -> ([Double], [Double]) {
        let tolerance = 1e-8
        if abs(a[0] - b[0]) <= tolerance {
            return a[1] <= b[1] ? (a, b) : (b, a)
        }
        return a[0] < b[0] ? (a, b) : (b, a)
    }

    private static func exactSameWall(_ left: WallCandidate,
                                      _ right: WallCandidate) -> Bool {
        guard left.storeyID == right.storeyID,
              abs(left.thicknessMM - right.thicknessMM) <= 1e-8,
              abs(left.heightMM - right.heightMM) <= 1e-8,
              abs(left.baseOffsetMM - right.baseOffsetMM) <= 1e-8 else { return false }
        return (samePoint(left.a, right.a) && samePoint(left.b, right.b))
            || (samePoint(left.a, right.b) && samePoint(left.b, right.a))
    }

    private static func samePoint(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == 2 && b.count == 2
            && abs(a[0] - b[0]) <= 1e-6 && abs(a[1] - b[1]) <= 1e-6
    }

    /// Exact shared segments are merged. A partial collinear overlap or a
    /// coincident segment with conflicting thickness/height/base is refused
    /// instead of stacking two walls that would look like complete topology.
    private static func rejectPartialOrConflictingOverlaps(_ walls: [WallCandidate]) throws {
        for i in 0..<walls.count {
            for j in (i + 1)..<walls.count {
                let a = walls[i], b = walls[j]
                guard a.storeyID == b.storeyID else { continue }
                if !collinearAndOverlapping(a, b), parallelVolumesOverlap(a, b) {
                    throw FloeBuildingCADError.invalidInput(
                        "Parallel room walls \(a.name) and \(b.name) occupy overlapping wall volume. "
                        + "Use exact shared wall segments or a clear gap; this topology is not evaluated.")
                }
                guard collinearAndOverlapping(a, b) else { continue }
                if exactSameWall(a, b) {
                    guard abs(a.thicknessMM - b.thicknessMM) <= 1e-8,
                          abs(a.heightMM - b.heightMM) <= 1e-8,
                          abs(a.baseOffsetMM - b.baseOffsetMM) <= 1e-8 else {
                        throw FloeBuildingCADError.invalidInput(
                            "Coincident room walls \(a.name) and \(b.name) have different thickness, height or base offset.")
                    }
                    continue
                }
                throw FloeBuildingCADError.invalidInput(
                    "Partial or conflicting collinear wall overlap between \(a.name) and \(b.name) is not evaluated. "
                    + "Use exact shared wall segments for the basic authoring bridge; arc/stepped room topology remains a later gap.")
            }
        }
    }

    /// Parallel centre lines whose thickened wall volumes overlap are a
    /// conflict (for example a different thickness at the same room boundary,
    /// or a gap smaller than the two half-thicknesses). They are refused
    /// instead of being stacked as two independent walls.
    private static func parallelVolumesOverlap(_ a: WallCandidate,
                                               _ b: WallCandidate) -> Bool {
        let ax = a.b[0] - a.a[0], ay = a.b[1] - a.a[1]
        let bx = b.b[0] - b.a[0], by = b.b[1] - b.a[1]
        let la = hypot(ax, ay), lb = hypot(bx, by)
        guard la > 1e-9, lb > 1e-9 else { return false }
        let cross = abs(ax * by - ay * bx) / (la * lb)
        guard cross <= 1e-9 else { return false }
        let distance = abs(ax * (b.a[1] - a.a[1]) - ay * (b.a[0] - a.a[0])) / la
        guard distance > 1e-6,
              distance < (a.thicknessMM + b.thicknessMM) / 2 - 1e-6 else { return false }
        func projection(_ p: [Double]) -> Double {
            ((p[0] - a.a[0]) * ax + (p[1] - a.a[1]) * ay) / la
        }
        let b0 = min(projection(b.a), projection(b.b))
        let b1 = max(projection(b.a), projection(b.b))
        return min(la, b1) - max(0, b0) > 1e-6
    }

    private static func collinearAndOverlapping(_ a: WallCandidate,
                                                _ b: WallCandidate) -> Bool {
        let ax = a.b[0] - a.a[0], ay = a.b[1] - a.a[1]
        let bx = b.b[0] - b.a[0], by = b.b[1] - b.a[1]
        let la = hypot(ax, ay), lb = hypot(bx, by)
        guard la > 1e-9, lb > 1e-9 else { return false }
        let cross = abs(ax * by - ay * bx) / (la * lb)
        guard cross <= 1e-9 else { return false }
        func distanceToLine(_ p: [Double]) -> Double {
            abs(ax * (p[1] - a.a[1]) - ay * (p[0] - a.a[0])) / la
        }
        guard distanceToLine(b.a) <= 1e-6, distanceToLine(b.b) <= 1e-6 else { return false }
        func projection(_ p: [Double]) -> Double {
            ((p[0] - a.a[0]) * ax + (p[1] - a.a[1]) * ay) / la
        }
        let b0 = min(projection(b.a), projection(b.b))
        let b1 = max(projection(b.a), projection(b.b))
        let overlap = min(la, b1) - max(0, b0)
        return overlap > 1e-6
    }

    static func validate(_ spec: FloeBuildingCADSpec) throws {
        guard !spec.name.isEmpty, spec.name.utf8.count <= 1024 else {
            throw FloeBuildingCADError.invalidInput("Building name must be nonempty and at most 1024 UTF-8 bytes.")
        }
        guard !spec.storeys.isEmpty, spec.storeys.count <= 128 else {
            throw FloeBuildingCADError.invalidInput("Use 1...128 storeys.")
        }
        guard Set(spec.storeys.map(\.id)).count == spec.storeys.count else {
            throw FloeBuildingCADError.invalidInput("Storey ids must be unique.")
        }
        var roomIDs = Set<UUID>()
        var openingIDs = Set<UUID>()
        for storey in spec.storeys {
            guard !storey.name.isEmpty, storey.name.utf8.count <= 1024,
                  storey.elevationMM.isFinite, abs(storey.elevationMM) <= 10_000_000,
                  storey.heightMM.isFinite, (100...100_000).contains(storey.heightMM) else {
                throw FloeBuildingCADError.invalidInput("Use finite storey elevations and a height of 100...100000 mm.")
            }
            var clearRects: [(room: FloeBuildingCADRoomSpec, min: [Double], max: [Double])] = []
            for room in storey.rooms {
                guard !room.name.isEmpty, room.name.utf8.count <= 1024,
                      room.minimum.count == 2, room.maximum.count == 2,
                      (room.minimum + room.maximum).allSatisfy({ $0.isFinite && abs($0) <= 10_000_000 }),
                      room.maximum[0] > room.minimum[0] + 0.1,
                      room.maximum[1] > room.minimum[1] + 0.1,
                      room.heightMM.isFinite, (100...100_000).contains(room.heightMM),
                      room.heightMM <= storey.heightMM + 0.1,
                      room.wallThicknessMM.isFinite, (1...100_000).contains(room.wallThicknessMM),
                      room.maximum[0] - room.minimum[0] > 2 * room.wallThicknessMM,
                      room.maximum[1] - room.minimum[1] > 2 * room.wallThicknessMM else {
                    throw FloeBuildingCADError.invalidInput("Room \(room.name) has invalid clear dimensions or wall thickness.")
                }
                guard roomIDs.insert(room.id).inserted else {
                    throw FloeBuildingCADError.invalidInput("Room ids must be unique.")
                }
                for other in clearRects {
                    let overlapX = min(room.maximum[0], other.max[0]) - max(room.minimum[0], other.min[0])
                    let overlapY = min(room.maximum[1], other.max[1]) - max(room.minimum[1], other.min[1])
                    if overlapX > 1e-6, overlapY > 1e-6 {
                        throw FloeBuildingCADError.invalidInput(
                            "Rooms \(room.name) and \(other.room.name) overlap on the same storey; "
                            + "overlapping clear rooms are not evaluated.")
                    }
                }
                clearRects.append((room, room.minimum, room.maximum))
                let h = room.wallThicknessMM / 2
                let lengths = [
                    room.maximum[0] - room.minimum[0] + 2 * h,
                    room.maximum[1] - room.minimum[1] + 2 * h,
                    room.maximum[0] - room.minimum[0] + 2 * h,
                    room.maximum[1] - room.minimum[1] + 2 * h,
                ]
                for opening in room.openings {
                    guard (0..<4).contains(opening.wallIndex) else {
                        throw FloeBuildingCADError.invalidInput("Opening \(opening.name) needs wallIndex 0...3.")
                    }
                    guard !opening.name.isEmpty, opening.name.utf8.count <= 1024,
                          opening.offsetMM.isFinite, opening.offsetMM >= 0,
                          opening.widthMM.isFinite, opening.widthMM > 1,
                          opening.heightMM.isFinite, opening.heightMM > 0,
                          opening.baseOffsetMM.isFinite, opening.baseOffsetMM >= 0,
                          opening.offsetMM + opening.widthMM <= lengths[opening.wallIndex],
                          opening.baseOffsetMM + opening.heightMM <= room.heightMM + 0.1 else {
                        throw FloeBuildingCADError.invalidInput("Opening \(opening.name) does not fit its host wall or room height.")
                    }
                    guard openingIDs.insert(opening.id).inserted else {
                        throw FloeBuildingCADError.invalidInput("Opening ids must be unique.")
                    }
                }
            }
        }
    }
}
#endif
