// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd

public nonisolated struct CADSimulationFace: Codable, Sendable {
    public var id: String
    public var nativeIndex: Int?
    public var triangles: [Int]
}

public nonisolated struct CADSimulationBody: Codable, Sendable {
    public var id: UUID
    public var name: String
    /// World coordinates in the CAD model's millimetres, without playback/explode offsets.
    public var positionsMM: [[Double]]
    public var indices: [UInt32]
    public var faces: [CADSimulationFace]
    /// Only present when this body's identity placement preserves native face indexing.
    public var brep: Data?
}

public nonisolated struct CADSimulationGeometry: Codable, Sendable {
    public var bodies: [CADSimulationBody]
    public var contentSHA256: String
    public var savedRevision: Int
    public var changeCount: Int
}

private nonisolated struct CADSimulationBRepIdentity: Encodable {
    var bodyID: UUID
    var brep: Data
}

private nonisolated struct CADSimulationSurfaceIdentity: Encodable {
    var bodyID: UUID
    var positionsMM: [[Double]]
    var indices: [UInt32]
}

@MainActor enum CADSimulationLifecycle {
    enum Event: Equatable { case changed, closed }
    static var observers: [ObjectIdentifier: [UUID: @MainActor (Event) -> Void]] = [:]
    static func changed(_ session: DocumentSession) {
        for callback in observers[ObjectIdentifier(session)]?.values ?? [:].values { callback(.changed) }
    }
    static func closed(_ session: DocumentSession) {
        let callbacks = observers.removeValue(forKey: ObjectIdentifier(session)) ?? [:]
        for callback in callbacks.values { callback(.closed) }
    }
}

@MainActor public extension FloeCADDocument {
    /// The host owns the token and removes it when its simulation session ends.
    func observeSimulationSource(_ callback: @escaping @MainActor (_ closed: Bool) -> Void) -> UUID {
        let token = UUID()
        if isClosed { callback(true); return token }
        CADSimulationLifecycle.observers[ObjectIdentifier(session), default: [:]][token] = { event in
            callback(event == .closed)
        }
        return token
    }
    func removeSimulationSourceObserver(_ token: UUID) {
        CADSimulationLifecycle.observers[ObjectIdentifier(session)]?.removeValue(forKey: token)
    }

    /// Read the authoritative body meshes and placements; never the preview pose,
    /// the selected objects alone, or an imported analysis/demo substitute.
    func simulationGeometry() throws -> CADSimulationGeometry {
        guard !isClosed, !isReadOnly else { throw CADDocumentError(code: "source_unavailable", message: "Open an editable CAD model first.") }
        let scene = sceneSnapshot(includeExplodedPreview: false, includeAnimationPreview: false)
        let visible = scene.bodies.filter { !$0.isHidden }
        guard !visible.isEmpty, visible.count <= 256,
              visible.reduce(0, { $0 + $1.mesh.positions.count }) <= 900_000,
              visible.reduce(0, { $0 + $1.mesh.indices.count / 3 }) <= 300_000 else {
            throw CADDocumentError(code: "simulation_size", message: "Use a nonempty model with at most 300,000 surface triangles.")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var result: [CADSimulationBody] = []
        for placed in visible {
            guard let body = session.document.bodies.first(where: { $0.id.raw == (placed.sourceBodyID ?? placed.id) }),
                  placed.transform.count == 16, placed.mesh.indices.count.isMultiple(of: 3),
                  placed.mesh.indices.allSatisfy({ Int($0) < placed.mesh.positions.count }) else {
                throw CADDocumentError(code: "simulation_geometry", message: "A CAD part has incomplete geometry.")
            }
            let m = placed.transform
            let matrix = simd_double4x4(SIMD4(m[0],m[1],m[2],m[3]), SIMD4(m[4],m[5],m[6],m[7]),
                SIMD4(m[8],m[9],m[10],m[11]), SIMD4(m[12],m[13],m[14],m[15]))
            let determinant = simd_determinant(matrix)
            guard determinant.isFinite, abs(determinant) > 1e-15 else {
                throw CADDocumentError(code: "simulation_transform", message: "A CAD placement is invalid.")
            }
            let positions = placed.mesh.positions.map { p -> [Double] in
                let world = matrix * SIMD4(Double(p.x),Double(p.y),Double(p.z),1)
                return [world.x, world.y, world.z]
            }
            guard positions.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
                throw CADDocumentError(code: "simulation_geometry", message: "A CAD coordinate is invalid.")
            }
            var indices = placed.mesh.indices
            if determinant < 0 { for i in stride(from: 0, to: indices.count, by: 3) { indices.swapAt(i+1,i+2) } }
            let prefix = placed.id.uuidString.lowercased()
            let exact = visible.count == 1 && body.transform == .identity && placed.sourceBodyID == nil
                && body.brep != nil ? session.serializedBrep(for: body) : nil
            // Surface snapshots name groups from the actual persisted render,
            // independently of the optional live feature/material naming cache.
            let table = exact == nil ? SignatureNaming.currentFaceTable(for:body) : session.faceRangeTable(for: body)
            let scope = CADMaterialTexture.digest(try exact ?? encoder.encode(positions))
            var faces: [CADSimulationFace] = []
            if let table, let channel = table.nativeFaceChannel, channel.count == indices.count / 3,
               table.nativeMeshRevision == body.meshRevision {
                var groups: [Int: [Int]] = [:]
                for (triangle, native) in channel.enumerated() { groups[Int(native), default: []].append(triangle) }
                for native in groups.keys.sorted() where native > 0 {
                    faces.append(.init(id:"\(prefix)/snapshot/\(scope)/face/\(native)",nativeIndex:native,triangles:groups[native]!))
                }
            } else if let table {
                for (i, entry) in table.entries.enumerated() {
                    // Exact B-rep tags below enumerate authoritative native
                    // faces; a display-only patch cannot stand in for one.
                    guard exact == nil else { continue }
                    faces.append(.init(id:"\(prefix)/snapshot/\(scope)/patch/\(i)",nativeIndex:nil,triangles:entry.triangles))
                }
            }
            if let exact, let handle = body.brep {
                let count = OCCTKernel.faceTypeCounts(handle)
                for native in 1...max(1, count.planar + count.cylindrical + count.other) where !faces.contains(where: { $0.nativeIndex == native }) {
                    faces.append(.init(id: "\(prefix)/snapshot/\(CADMaterialTexture.digest(exact))/face/\(native)", nativeIndex: native, triangles: []))
                }
            }
            result.append(.init(id: placed.id, name: placed.name, positionsMM: positions, indices: indices, faces: faces, brep: exact))
        }
        let identity: Data
        if result.count == 1, let body = result.first, let brep = body.brep {
            // Native shape identity excludes derived display tessellation and
            // face-table caches, which can legitimately be rebuilt on load.
            identity = try encoder.encode(CADSimulationBRepIdentity(bodyID:body.id,brep:brep))
        } else {
            // Labels and transient face caches are not geometry. Persisted
            // surface buffers include world placement and retain their order.
            identity = try encoder.encode(result.sorted { $0.id.uuidString < $1.id.uuidString }.map {
                CADSimulationSurfaceIdentity(bodyID:$0.id,positionsMM:$0.positionsMM,indices:$0.indices)
            })
        }
        return .init(bodies: result, contentSHA256: CADMaterialTexture.digest(identity), savedRevision: revision, changeCount: exchangeChangeCount)
    }
}
