// SPDX-License-Identifier: MPL-2.0
// Body-owned UV authoring data. Geometry remains owned by Body/FeatureGraph.
import Foundation
import CryptoKit
import simd

nonisolated struct CADUVFailure: Error, LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

nonisolated struct CADUVEdge: Codable, Hashable, Sendable, Comparable {
    let a: UInt32
    let b: UInt32
    init(_ first: UInt32, _ second: UInt32) { a = min(first, second); b = max(first, second) }
    static func < (l: Self, r: Self) -> Bool { (l.a, l.b) < (r.a, r.b) }
    var key: String { "\(a):\(b)" }
}

nonisolated struct CADUVSet: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var name: String
    /// Packed little-endian float32 uv pairs, in original triangle-corner order.
    var cornerUVData: Data
    var faceCharts: [UInt32]
    var seamSHA256: String
    var atlasWidth: UInt32
    var atlasHeight: UInt32
    var algorithm: String
}

nonisolated struct CADUVRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumBytes = 64 * 1024 * 1024
    static let maximumTriangles = 50_000
    static let maximumVertices = 150_000
    static let maximumSets = 8
    var version: Int = Self.currentVersion
    /// Original mesh, including any imported authored UVs. Never mutated by
    /// island editing. Seams index this exact snapshot, never the live mesh.
    var sourceMesh: Data
    var sourceMeshSHA256: String
    /// Ordered triangle position+normal bits, independent of vertex splitting.
    /// A geometry rebuild must prove exact equality before using these UVs.
    var geometrySHA256: String
    var seams: [CADUVEdge] = []
    var sets: [CADUVSet] = []
    var activeSetID: UUID?

    var activeSet: CADUVSet? { sets.first { $0.id == activeSetID } }
    var seamSHA256: String {
        var data = Data()
        for edge in seams.sorted() {
            Self.append(edge.a, to: &data); Self.append(edge.b, to: &data)
        }
        return Self.sha(data)
    }

    static func make(source: RenderMesh) throws -> Self {
        try validate(source)
        let bytes = MeshBlob.encode(source)
        var value = Self(sourceMesh: bytes, sourceMeshSHA256: sha(bytes),
                         geometrySHA256: try geometryDigest(source))
        if let uv = source.texcoords {
            let corners = source.indices.map { uv[Int($0)] }
            if (try? validateUVs(corners, cornerCount: source.indices.count)) != nil {
                let charts = try inferredCharts(source: source, cornerUVs: corners)
                let original = CADUVSet(id: stableOriginalID(bytes), name: "UV 0", cornerUVData: pack(corners),
                    faceCharts: charts, seamSHA256: value.seamSHA256,
                    atlasWidth: 0, atlasHeight: 0, algorithm: "authored")
                value.sets = [original]; value.activeSetID = original.id
            }
        }
        return value
    }

    static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= maximumBytes else { throw failure("uv_budget", "The saved UV record exceeds the resource limit.") }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.version == currentVersion else { throw failure("unsupported_uv_version", "This UV record needs a newer app.") }
        let source = try MeshBlob.decode(value.sourceMesh)
        try validate(source)
        guard sha(value.sourceMesh) == value.sourceMeshSHA256,
              try geometryDigest(source) == value.geometrySHA256,
              value.sets.count <= maximumSets,
              Set(value.sets.map(\.id)).count == value.sets.count,
              value.activeSetID == nil || value.activeSet != nil else {
            throw failure("invalid_uv_record", "The saved UV source or active set is invalid.")
        }
        let edges = try edgeFaces(source)
        guard Set(value.seams).count == value.seams.count,
              value.seams.allSatisfy({ edges[$0] != nil }) else {
            throw failure("invalid_uv_seam", "The saved seam does not belong to its source mesh.")
        }
        for set in value.sets {
            guard !set.name.isEmpty, set.name.count <= 64,
                  set.faceCharts.count == source.triangleCount,
                  set.faceCharts.allSatisfy({ $0 < UInt32(source.triangleCount) }) else {
                throw failure("invalid_uv_set", "A saved UV set has invalid island coverage.")
            }
            try validateUVs(unpack(set.cornerUVData), cornerCount: source.indices.count)
        }
        return value
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw Self.failure("uv_budget", "The UV edit exceeds the resource limit.") }
        return data
    }

    func matches(_ render: RenderMesh) -> Bool {
        (try? Self.geometryDigest(render)) == geometrySHA256
    }

    func render(using set: CADUVSet) throws -> RenderMesh {
        let source = try MeshBlob.decode(sourceMesh)
        let uv = try Self.unpack(set.cornerUVData)
        try Self.validateUVs(uv, cornerCount: source.indices.count)
        // Fully split corners keep UV seams and original face order exactly.
        return RenderMesh(positions: source.indices.map { source.positions[Int($0)] },
                          normals: source.indices.map { source.normals[Int($0)] },
                          indices: (0..<source.indices.count).map(UInt32.init), texcoords: uv)
    }

    static func validate(_ mesh: RenderMesh) throws {
        guard !mesh.indices.isEmpty, mesh.indices.count % 3 == 0,
              mesh.triangleCount <= maximumTriangles,
              !mesh.positions.isEmpty, mesh.positions.count <= maximumVertices,
              mesh.positions.count == mesh.normals.count,
              mesh.indices.allSatisfy({ Int($0) < mesh.positions.count }),
              mesh.positions.allSatisfy(finite), mesh.normals.allSatisfy(finite),
              mesh.texcoords == nil || (mesh.texcoords?.count == mesh.positions.count
                && mesh.texcoords!.allSatisfy({ $0.x.isFinite && $0.y.isFinite })) else {
            throw failure("invalid_uv_mesh", "UV editing requires a finite triangle mesh within 50,000 triangles and 150,000 vertices.")
        }
        for f in 0..<mesh.triangleCount {
            let p = (0..<3).map { mesh.positions[Int(mesh.indices[f*3+$0])] }
            let area = simd_length(simd_cross(p[1]-p[0],p[2]-p[0]))
            guard area.isFinite, area > 1e-12 else { throw failure("invalid_uv_mesh", "The source has a degenerate triangle; repair it before unwrapping.") }
        }
    }

    static func geometryDigest(_ mesh: RenderMesh) throws -> String {
        guard mesh.indices.count % 3 == 0, mesh.positions.count == mesh.normals.count,
              mesh.indices.count <= maximumTriangles*3,
              mesh.indices.allSatisfy({ Int($0) < mesh.positions.count }) else {
            throw failure("invalid_uv_mesh", "The UV source triangle buffer is invalid.")
        }
        var hasher = SHA256()
        var data = Data(capacity: mesh.indices.count * 24 + 4)
        append(UInt32(mesh.indices.count), to: &data)
        for index in mesh.indices {
            let p = mesh.positions[Int(index)], n = mesh.normals[Int(index)]
            guard finite(p), finite(n) else { throw failure("invalid_uv_mesh", "The UV source contains non-finite geometry.") }
            for value in [p.x,p.y,p.z,n.x,n.y,n.z] { append(value.bitPattern, to: &data) }
        }
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Exact position welding lets a seam span duplicated hard-normal vertices.
    /// There is no nearest-position or old-index fallback after a source change.
    static func edgeFaces(_ mesh: RenderMesh) throws -> [CADUVEdge: [Int]] {
        try validate(mesh)
        var representatives: [SIMD3<Float>: UInt32] = [:]
        var vertices: [UInt32] = []; vertices.reserveCapacity(mesh.positions.count)
        for (i,p) in mesh.positions.enumerated() {
            let id = representatives[p] ?? UInt32(i)
            representatives[p] = id; vertices.append(id)
        }
        var edges: [CADUVEdge: [Int]] = [:]
        for f in 0..<mesh.triangleCount {
            for side in 0..<3 {
                let a = vertices[Int(mesh.indices[f*3+side])]
                let b = vertices[Int(mesh.indices[f*3+(side+1)%3])]
                edges[CADUVEdge(a,b), default: []].append(f)
            }
        }
        guard edges.values.allSatisfy({ $0.count <= 2 }) else {
            throw failure("nonmanifold_uv_mesh", "Repair non-manifold edges before unwrapping.")
        }
        return edges
    }

    /// xatlas's native hard chart groups guarantee every explicit seam's two
    /// sides are in different charts. Extra automatic cuts remain permissible,
    /// including for a non-separating slit on a closed surface.
    static func hardChartGroups(source: RenderMesh, seams: [CADUVEdge]) throws -> [UInt32] {
        let edges = try edgeFaces(source)
        var neighbors: [Int: Set<Int>] = [:]
        for seam in seams {
            guard let faces = edges[seam] else { throw failure("invalid_uv_seam", "A seam does not belong to this source mesh.") }
            if faces.count == 2 {
                neighbors[faces[0], default: []].insert(faces[1])
                neighbors[faces[1], default: []].insert(faces[0])
            }
        }
        var colors: [Int: UInt32] = [:]
        for face in neighbors.keys.sorted() {
            let used = Set(neighbors[face, default: []].compactMap { colors[$0] })
            var value: UInt32 = 0; while used.contains(value) { value += 1 }
            colors[face] = value
        }
        return (0..<source.triangleCount).map { colors[$0] ?? 0 }
    }

    /// Preserve authored UV islands by exact edge endpoint UV continuity.
    static func inferredCharts(source: RenderMesh, cornerUVs: [SIMD2<Float>]) throws -> [UInt32] {
        let edges = try edgeFaces(source)
        var parent = Array(0..<source.triangleCount)
        func root(_ v: Int) -> Int { var i=v; while parent[i] != i { i=parent[i] }; return i }
        func corner(_ face: Int, at position: SIMD3<Float>) -> SIMD2<Float>? {
            (0..<3).first(where: { source.positions[Int(source.indices[face*3+$0])] == position })
                .map { cornerUVs[face*3+$0] }
        }
        for (edge, faces) in edges where faces.count == 2 {
            let a=source.positions[Int(edge.a)], b=source.positions[Int(edge.b)]
            if corner(faces[0],at:a) == corner(faces[1],at:a), corner(faces[0],at:b) == corner(faces[1],at:b) {
                parent[root(faces[1])] = root(faces[0])
            }
        }
        var ids: [Int:UInt32]=[:]
        return (0..<source.triangleCount).map { face in
            let r=root(face); if ids[r] == nil { ids[r]=UInt32(ids.count) }; return ids[r]!
        }
    }

    static func transformed(_ set: CADUVSet, islands: Set<UInt32>, translate: SIMD2<Float>,
                            rotationDegrees: Float, scale: SIMD2<Float>) throws -> CADUVSet {
        guard !islands.isEmpty, islands.isSubset(of: Set(set.faceCharts)),
              translate.x.isFinite, translate.y.isFinite, rotationDegrees.isFinite,
              scale.x.isFinite, scale.y.isFinite, scale.x >= 0.001, scale.y >= 0.001,
              scale.x <= 1000, scale.y <= 1000 else { throw failure("invalid_uv_transform", "Choose existing islands and finite, positive UV scales.") }
        if translate == .zero, rotationDegrees == 0, scale == SIMD2<Float>(repeating: 1) { return set }
        var uv = try unpack(set.cornerUVData)
        let selected = set.faceCharts.indices.filter { islands.contains(set.faceCharts[$0]) }.flatMap { [$0*3,$0*3+1,$0*3+2] }
        guard !selected.isEmpty else { throw failure("unknown_uv_island", "The selected island is no longer present.") }
        var lo=SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for i in selected { lo=simd_min(lo,uv[i]); hi=simd_max(hi,uv[i]) }
        let pivot=(lo+hi)/2, angle=rotationDegrees * .pi/180, c=cos(angle), s=sin(angle)
        for i in selected {
            let p=(uv[i]-pivot)*scale
            uv[i] = SIMD2(c*p.x-s*p.y,s*p.x+c*p.y)+pivot+translate
        }
        try validateUVs(uv, cornerCount: set.faceCharts.count*3)
        var result=set; result.cornerUVData=pack(uv); return result
    }

    static func validateUVs(_ values: [SIMD2<Float>], cornerCount: Int) throws {
        guard values.count == cornerCount, cornerCount % 3 == 0,
              values.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1_000_000 && abs($0.y) <= 1_000_000 }) else {
            throw failure("invalid_uv_values", "The UV coordinate buffer is invalid.")
        }
        for f in 0..<cornerCount/3 {
            let a=values[f*3+1]-values[f*3], b=values[f*3+2]-values[f*3]
            guard abs(a.x*b.y-a.y*b.x) > 1e-14 else { throw failure("degenerate_uv", "The UV edit would collapse a triangle.") }
        }
    }

    static func pack(_ values: [SIMD2<Float>]) -> Data {
        var data=Data(capacity: values.count*8)
        for value in values { append(value.x.bitPattern,to:&data); append(value.y.bitPattern,to:&data) }
        return data
    }
    static func unpack(_ data: Data) throws -> [SIMD2<Float>] {
        guard data.count % 8 == 0, data.count <= maximumTriangles*3*8 else { throw failure("invalid_uv_values", "The saved UV coordinate buffer is invalid.") }
        return data.withUnsafeBytes { bytes in (0..<data.count/8).map { i in
            SIMD2(Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset:i*8,as:UInt32.self))),
                  Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset:i*8+4,as:UInt32.self))))
        } }
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private static func stableOriginalID(_ bytes: Data) -> UUID {
        let s=Array(sha(bytes).prefix(32))
        let text=String(s[0..<8])+"-"+String(s[8..<12])+"-"+String(s[12..<16])+"-"+String(s[16..<20])+"-"+String(s[20..<32])
        return UUID(uuidString:text)!
    }
    private static func append(_ value: UInt32, to data: inout Data) { withUnsafeBytes(of:value.littleEndian) { data.append(contentsOf:$0) } }
    private static func finite(_ p: SIMD3<Float>) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite }
    static func failure(_ code: String, _ message: String) -> CADUVFailure { CADUVFailure(code:code,message:message) }
}

nonisolated extension Body {
    /// Called only when copying appearance across a geometry replacement.
    /// Stale authoring data is retained for recovery; no old index is applied
    /// unless the CURRENT ordered triangle content is exactly the same.
    func keepingUVAuthoring(of live: Body) -> Body {
        var result=self
        result.uvData=live.uvData
        if let data=live.uvData, let record=try? CADUVRecord.decode(data),
           record.matches(render), let set=record.activeSet,
           let mapped=try? record.render(using:set) { result.render=mapped }
        return result
    }
}

struct SetBodyUVCommand: DocumentCommand {
    let title: String
    let bodyID: BodyID
    let beforeRender: RenderMesh
    let afterRender: RenderMesh
    let beforeData: Data?
    let afterData: Data?
    func apply(to document: inout DesignDocument) { put(afterRender,afterData,in:&document) }
    func revert(in document: inout DesignDocument) { put(beforeRender,beforeData,in:&document) }
    private func put(_ render: RenderMesh, _ data: Data?, in document: inout DesignDocument) {
        guard let i=document.bodyIndex(of:bodyID) else { return }
        document.bodies[i].render=render; document.bodies[i].uvData=data
        document.bodies[i].meshRevision=document.nextRevision()
        // Position/normal triangles, analytic handles, CSG, materials,
        // source features, selection and placement are deliberately untouched.
    }
}
