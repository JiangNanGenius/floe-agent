//
//  CADSelectionContext.swift
//  FloeCADKit
//
//  Trusted, revision-bound snapshot of what the user actually has selected in
//  the native workbench. This is the ONE value an assistant entry point should
//  receive: real live ids and geometry from the current document, plus the
//  document revision/change count that fences the read. It is not a second
//  selection authority and it never invents geometry: an id that no longer
//  exists is dropped, and a stale face/edge pick is reported as such by the
//  caller comparing `documentRevision`/`changeCount`.
//
//  SPDX-License-Identifier: MPL-2.0
//

import Foundation
import simd

/// A bounded snapshot of the live workbench selection.
public struct CADSelectionContext: Sendable, Equatable {

    public struct Body: Sendable, Equatable {
        public var id: String
        public var name: String
        public var volumeMM3: Double
        public var bounds: [[Double]]
        public var analyticBRep: Bool

        public init(id: String, name: String, volumeMM3: Double,
                    bounds: [[Double]], analyticBRep: Bool) {
            self.id = id
            self.name = name
            self.volumeMM3 = volumeMM3
            self.bounds = bounds
            self.analyticBRep = analyticBRep
        }
    }

    /// A face pick expressed as the selected mesh triangles plus the derived
    /// centroid/normal/area. The kernel face index is intentionally NOT
    /// guessed: callers that need one match the signature through
    /// `cad.document query kind=faces` with the same revision fence.
    public struct Face: Sendable, Equatable {
        public var bodyID: String
        public var triangleCount: Int
        public var normal: [Double]
        public var centroid: [Double]
        public var areaMM2: Double
        public var curved: Bool

        public init(bodyID: String, triangleCount: Int, normal: [Double],
                    centroid: [Double], areaMM2: Double, curved: Bool) {
            self.bodyID = bodyID
            self.triangleCount = triangleCount
            self.normal = normal
            self.centroid = centroid
            self.areaMM2 = areaMM2
            self.curved = curved
        }
    }

    /// An edge pick is the selected crease segment in WORLD coordinates. The
    /// kernel index is resolved by `query kind=edges` when an edit needs one.
    public struct Edge: Sendable, Equatable {
        public var bodyID: String
        public var start: [Double]
        public var end: [Double]
        public var midpoint: [Double]
        public var lengthMM: Double
        public var isConvex: Bool

        public init(bodyID: String, start: [Double], end: [Double],
                    midpoint: [Double], lengthMM: Double, isConvex: Bool) {
            self.bodyID = bodyID
            self.start = start
            self.end = end
            self.midpoint = midpoint
            self.lengthMM = lengthMM
            self.isConvex = isConvex
        }
    }

    public struct SketchSelection: Sendable, Equatable {
        public var id: String
        public var name: String
        public var entityIDs: [String]
        public var dimensionIDs: [String]
        public var constraintIDs: [String]

        public init(id: String, name: String, entityIDs: [String],
                    dimensionIDs: [String], constraintIDs: [String]) {
            self.id = id
            self.name = name
            self.entityIDs = entityIDs
            self.dimensionIDs = dimensionIDs
            self.constraintIDs = constraintIDs
        }
    }

    public struct Instance: Sendable, Equatable {
        public var id: String
        public var name: String
        public var bodyID: String
        public var position: [Double]
        public var hidden: Bool

        public init(id: String, name: String, bodyID: String,
                    position: [Double], hidden: Bool) {
            self.id = id
            self.name = name
            self.bodyID = bodyID
            self.position = position
            self.hidden = hidden
        }
    }

    public var documentRevision: Int64
    public var changeCount: Int
    public var bodies: [Body]
    public var faces: [Face]
    public var edges: [Edge]
    public var sketch: SketchSelection?
    public var instances: [Instance]
    /// True when any selection part exceeded the bounded row caps.
    public var truncated: Bool

    public init(documentRevision: Int64, changeCount: Int,
                bodies: [Body] = [], faces: [Face] = [], edges: [Edge] = [],
                sketch: SketchSelection? = nil, instances: [Instance] = [],
                truncated: Bool = false) {
        self.documentRevision = documentRevision
        self.changeCount = changeCount
        self.bodies = bodies
        self.faces = faces
        self.edges = edges
        self.sketch = sketch
        self.instances = instances
        self.truncated = truncated
    }

    public var isEmpty: Bool {
        bodies.isEmpty && faces.isEmpty && edges.isEmpty && sketch == nil && instances.isEmpty
    }

    /// Stable key for SwiftUI change observation. It includes every live
    /// selection input, so the workbench notifies its host only on a real
    /// selection change, not on every render tick.
    public var observationKey: String {
        [
            String(documentRevision),
            String(changeCount),
            bodies.map(\.id).joined(separator: ","),
            faces.map { "\($0.bodyID):\($0.triangleCount):\($0.centroid)" }.joined(separator: "|"),
            edges.map { "\($0.bodyID):\($0.midpoint)" }.joined(separator: "|"),
            sketch.map { "\($0.id):\($0.entityIDs.joined(separator: ","))" } ?? "-",
            instances.map(\.id).joined(separator: ","),
        ].joined(separator: "#")
    }

    /// JSON-safe representation for a tool/assistant context envelope.
    public func jsonObject() -> [String: Any] {
        var object: [String: Any] = [
            "document_revision": documentRevision,
            "change_count": changeCount,
            "selection_count": bodies.count + faces.count + edges.count
                + (sketch?.entityIDs.count ?? 0) + instances.count,
            "truncated": truncated,
            "bodies": bodies.map { body in
                ["id": body.id, "name": body.name, "volume_mm3": body.volumeMM3,
                 "bounds": body.bounds, "analytic_brep": body.analyticBRep]
            },
            "faces": faces.map { face in
                ["body_id": face.bodyID, "triangle_count": face.triangleCount,
                 "normal": face.normal, "centroid": face.centroid,
                 "area_mm2": face.areaMM2, "curved": face.curved]
            },
            "edges": edges.map { edge in
                ["body_id": edge.bodyID, "start": edge.start, "end": edge.end,
                 "midpoint": edge.midpoint, "length_mm": edge.lengthMM,
                 "convex": edge.isConvex]
            },
            "assembly_instances": instances.map { instance in
                ["id": instance.id, "name": instance.name, "body_id": instance.bodyID,
                 "position": instance.position, "hidden": instance.hidden]
            },
            "revision_source": "live FloeCADDocument",
        ]
        if let sketch {
            object["sketch"] = [
                "id": sketch.id,
                "name": sketch.name,
                "entity_ids": sketch.entityIDs,
                "dimension_ids": sketch.dimensionIDs,
                "constraint_ids": sketch.constraintIDs,
            ]
        } else {
            object["sketch"] = NSNull()
        }
        return object
    }

    /// Compact human/model-readable sentence. It names the revision fence so
    /// an assistant knows the ids are only valid for that generation.
    public func promptText() -> String {
        guard !isEmpty else {
            return "Selected CAD context: nothing is selected (document revision "
                + "\(documentRevision), change \(changeCount))."
        }
        var parts: [String] = [
            "Selected CAD context (trusted document revision \(documentRevision), change \(changeCount)):"
        ]
        if !bodies.isEmpty {
            let labels = bodies.prefix(8).map { "\($0.name) [\($0.id)]" }
            parts.append("\(bodies.count) bod\(bodies.count == 1 ? "y" : "ies"): "
                + labels.joined(separator: ", "))
        }
        if !faces.isEmpty {
            let labels = faces.prefix(6).map {
                "\($0.curved ? "curved" : "planar") face on \($0.bodyID) "
                    + "(\($0.triangleCount) triangles, \(String(format: "%.2f", $0.areaMM2)) mm²)"
            }
            parts.append("\(faces.count) face(s): " + labels.joined(separator: ", "))
        }
        if !edges.isEmpty {
            let labels = edges.prefix(6).map {
                "edge on \($0.bodyID) at \($0.midpoint) (\(String(format: "%.2f", $0.lengthMM)) mm)"
            }
            parts.append("\(edges.count) edge(s): " + labels.joined(separator: ", "))
        }
        if let sketch {
            parts.append("sketch '\(sketch.name)' [\(sketch.id)] entities: "
                + (sketch.entityIDs.isEmpty ? "none selected" : sketch.entityIDs.prefix(12).joined(separator: ", ")))
        }
        if !instances.isEmpty {
            let labels = instances.prefix(6).map { "\($0.name) [\($0.id)] body \($0.bodyID)" }
            parts.append("\(instances.count) assembly instance(s): " + labels.joined(separator: ", "))
        }
        if truncated { parts.append("(selection list truncated to the bounded caps)") }
        return parts.joined(separator: " ")
    }

    // MARK: - Live capture

    /// Input for one face pick: the body plus the mesh triangles the picker
    /// highlighted. `curved` distinguishes a smooth/curved region from a
    /// planar patch.
    public struct FaceTrianglePick: Sendable, Equatable {
        public var bodyID: UUID
        public var triangles: [Int]
        public var curved: Bool
        public init(bodyID: UUID, triangles: [Int], curved: Bool) {
            self.bodyID = bodyID
            self.triangles = triangles
            self.curved = curved
        }
    }

    /// Input for one edge pick: the body plus the selected crease segment in
    /// BODY-LOCAL coordinates (the renderer's edge buffer).
    public struct EdgeSegmentPick: Sendable, Equatable {
        public var bodyID: UUID
        public var start: SIMD3<Double>
        public var end: SIMD3<Double>
        public var isConvex: Bool
        public init(bodyID: UUID, start: SIMD3<Double>, end: SIMD3<Double>, isConvex: Bool) {
            self.bodyID = bodyID
            self.start = start
            self.end = end
            self.isConvex = isConvex
        }
    }

    public static let maximumBodies = 64
    public static let maximumFacePicks = 32
    public static let maximumEdgePicks = 32
    public static let maximumSketchEntities = 128
    public static let maximumInstances = 64

    /// Build a context from the LIVE document. Every id is resolved against
    /// the current graph; missing ids are dropped, not echoed. Face/edge
    /// geometry is measured from the actual render mesh / selected segment.
    @MainActor
    static func capture(
        document: FloeCADDocument,
        bodyIDs: Set<BodyID> = [],
        facePicks: [FaceTrianglePick] = [],
        edgePicks: [EdgeSegmentPick] = [],
        sketchID: SketchID? = nil,
        sketchEntityIDs: Set<UUID> = [],
        instanceIDs: Set<UUID> = []
    ) -> CADSelectionContext {
        let design = document.session.document
        var truncated = false

        let liveBodies = bodyIDs.compactMap { design.body(with: $0) }
        if liveBodies.count > maximumBodies { truncated = true }
        let rows = liveBodies.prefix(maximumBodies).map { body -> Body in
            let bounds = MeasureKit.boundingBox(bodies: [body]).map {
                [[$0.min.x, $0.min.y, $0.min.z], [$0.max.x, $0.max.y, $0.max.z]]
            } ?? []
            return Body(id: body.id.raw.uuidString,
                        name: body.name,
                        volumeMM3: MeasureKit.volume(of: body),
                        bounds: bounds,
                        analyticBRep: body.brep != nil)
        }

        if facePicks.count > maximumFacePicks { truncated = true }
        let faceRows = facePicks.prefix(maximumFacePicks).compactMap { pick -> Face? in
            guard let body = design.body(with: BodyID(raw: pick.bodyID)),
                  !pick.triangles.isEmpty else { return nil }
            let triangles = pick.triangles.filter {
                $0 >= 0 && $0 < body.render.triangleCount
            }
            guard !triangles.isEmpty else { return nil }
            let scale = body.transform.scale
            let area = MeasureKit.faceArea(body.render, triangles: triangles, scale: scale)
            var normal = SIMD3<Double>.zero
            var centroid = SIMD3<Double>.zero
            let positions = body.render.positions
            let indices = body.render.indices
            for triangle in triangles {
                let i0 = Int(indices[triangle * 3])
                let i1 = Int(indices[triangle * 3 + 1])
                let i2 = Int(indices[triangle * 3 + 2])
                guard i0 < positions.count, i1 < positions.count, i2 < positions.count else { continue }
                let a = SIMD3<Double>(positions[i0])
                let b = SIMD3<Double>(positions[i1])
                let c = SIMD3<Double>(positions[i2])
                let triNormal = simd_cross(b - a, c - a)
                normal += triNormal
                centroid += (a + b + c) / 3
            }
            let count = max(1, triangles.count)
            centroid /= Double(count)
            let localNormal = simd_length(normal) > 1e-12 ? simd_normalize(normal) : SIMD3<Double>(0, 0, 1)
            let worldNormal = body.transform.rotation.act(localNormal)
            let worldCentroid = body.transform.applying(to: centroid)
            return Face(bodyID: body.id.raw.uuidString,
                        triangleCount: triangles.count,
                        normal: [worldNormal.x, worldNormal.y, worldNormal.z],
                        centroid: [worldCentroid.x, worldCentroid.y, worldCentroid.z],
                        areaMM2: area,
                        curved: pick.curved)
        }

        if edgePicks.count > maximumEdgePicks { truncated = true }
        let edgeRows = edgePicks.prefix(maximumEdgePicks).compactMap { pick -> Edge? in
            guard let body = design.body(with: BodyID(raw: pick.bodyID)) else { return nil }
            let worldStart = body.transform.applying(to: pick.start)
            let worldEnd = body.transform.applying(to: pick.end)
            let length = simd_length(worldEnd - worldStart) * body.transform.scale
            guard length.isFinite, length > 1e-9 else { return nil }
            let mid = (worldStart + worldEnd) / 2
            return Edge(bodyID: body.id.raw.uuidString,
                        start: [worldStart.x, worldStart.y, worldStart.z],
                        end: [worldEnd.x, worldEnd.y, worldEnd.z],
                        midpoint: [mid.x, mid.y, mid.z],
                        lengthMM: length,
                        isConvex: pick.isConvex)
        }

        var sketchRow: SketchSelection?
        if let sketchID, let sketch = design.sketches.first(where: { $0.id == sketchID }) {
            let liveIDs = Set(sketch.entities.map(\.id))
            let selected = sketchEntityIDs.filter { liveIDs.contains($0) }
            if selected.count > maximumSketchEntities { truncated = true }
            let ids = selected.sorted { $0.uuidString < $1.uuidString }
                .prefix(maximumSketchEntities)
                .map(\.uuidString)
            let allEntities = Set(sketch.entities.map(\.id))
            sketchRow = SketchSelection(
                id: sketch.id.raw.uuidString,
                name: sketch.name,
                entityIDs: Array(ids),
                dimensionIDs: sketch.dimensions.filter {
                    $0.refs.contains(where: { allEntities.contains($0.entityID) })
                }.prefix(64).map { $0.id.uuidString },
                constraintIDs: sketch.constraints.filter {
                    $0.refs.contains(where: { allEntities.contains($0.entityID) })
                }.prefix(64).map { $0.id.uuidString })
            if sketch.dimensions.count > 64 || sketch.constraints.count > 64 { truncated = true }
        }

        var instanceRows: [Instance] = []
        if !instanceIDs.isEmpty {
            let assembly = (try? CADAssembly.decode(from: design.assemblyData)) ?? CADAssembly()
            let live = assembly.instances.filter { instanceIDs.contains($0.id) }
            if live.count > maximumInstances { truncated = true }
            instanceRows = live.prefix(maximumInstances).map { instance in
                Instance(id: instance.id.uuidString,
                         name: instance.name,
                         bodyID: instance.bodyID.uuidString,
                         position: [instance.transform.position.x,
                                    instance.transform.position.y,
                                    instance.transform.position.z],
                         hidden: instance.isHidden)
            }
        }

        return CADSelectionContext(
            documentRevision: Int64(document.revision),
            changeCount: document.session.changeCount,
            bodies: rows,
            faces: faceRows,
            edges: edgeRows,
            sketch: sketchRow,
            instances: instanceRows,
            truncated: truncated)
    }
}

// Read from the same live editor model at the tool boundary. No secondary
// selection cache can outlive a rebuild or leak another document's selection.
public extension FloeCADDocument {
    @MainActor
    func assistantSelectionContext() -> CADSelectionContext {
        let inputs = viewModel().assistantSelectionInputs
        return CADSelectionContext.capture(
            document: self,
            bodyIDs: inputs.bodyIDs,
            facePicks: inputs.facePicks,
            edgePicks: inputs.edgePicks,
            sketchID: inputs.sketchID,
            sketchEntityIDs: inputs.sketchEntityIDs,
            instanceIDs: inputs.instanceIDs
        )
    }
}
