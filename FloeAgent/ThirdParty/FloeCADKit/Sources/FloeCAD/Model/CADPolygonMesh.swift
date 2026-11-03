import Foundation
import CryptoKit
import simd
import Euclid

/// Authored polygon topology. UUIDs belong to stored topology, never to a
/// render triangle ordinal. Removed elements retire their identities.
nonisolated struct CADPolygonCage: Codable, Equatable, Sendable {
    nonisolated struct Vertex: Codable, Equatable, Sendable, Identifiable {
        var id: UUID = UUID()
        var point: SIMD3<Double>
    }
    nonisolated struct Face: Codable, Equatable, Sendable, Identifiable {
        var id: UUID = UUID()
        var vertices: [UUID]
    }
    nonisolated struct Edge: Codable, Equatable, Sendable, Identifiable {
        var id: UUID = UUID()
        var a: UUID
        var b: UUID
        var key: Key { Key(a, b) }
    }
    nonisolated struct Key: Hashable, Sendable {
        var a: UUID
        var b: UUID
        init(_ a: UUID, _ b: UUID) {
            if a.uuidString < b.uuidString { self.a = a; self.b = b }
            else { self.a = b; self.b = a }
        }
        var text: String { a.uuidString + "/" + b.uuidString }
    }
    var vertices: [Vertex]
    var edges: [Edge]
    var faces: [Face]
    static let maxVertices = 4096
    static let maxFaces = 2048
    var points: [UUID: SIMD3<Double>] { Dictionary(uniqueKeysWithValues: vertices.map { ($0.id, $0.point) }) }
    func keys(_ face: Face) -> [Key] {
        face.vertices.indices.map { Key(face.vertices[$0], face.vertices[($0 + 1) % face.vertices.count]) }
    }
    var incidence: [Key: [Int]] {
        var result: [Key: [Int]] = [:]
        for (index, face) in faces.enumerated() { for key in keys(face) { result[key, default: []].append(index) } }
        return result
    }
    var isClosed: Bool { incidence.values.allSatisfy { $0.count == 2 } }
    mutating func synchronizeEdges(namespace: UUID? = nil) {
        let old = Dictionary(edges.map { ($0.key, $0.id) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<Key> = []
        edges = faces.flatMap { keys($0) }.compactMap { key in
            guard seen.insert(key).inserted else { return nil }
            return Edge(id: old[key] ?? namespace.map { Self.derived($0, "edge/" + key.text) } ?? UUID(), a: key.a, b: key.b)
        }
        let used = Set(faces.flatMap(\.vertices))
        vertices.removeAll { !used.contains($0.id) }
    }
    static func derived(_ namespace: UUID, _ value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data((namespace.uuidString + "/" + value).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 15) | 80; bytes[8] = (bytes[8] & 63) | 128
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    func normal(_ face: Face, using supplied: [UUID: SIMD3<Double>]? = nil) throws -> SIMD3<Double> {
        let map = supplied ?? points
        let p = try face.vertices.map { id -> SIMD3<Double> in
            guard let point = map[id] else { throw CADPolygonFailure.invalid("A face vertex is missing.") }; return point
        }
        guard p.count >= 3 else { throw CADPolygonFailure.invalid("A face needs at least three vertices.") }
        var value = SIMD3<Double>.zero
        for i in p.indices { value += simd_cross(p[i] - p[0], p[(i + 1) % p.count] - p[0]) }
        guard simd_length(value) > 1e-9 else { throw CADPolygonFailure.invalid("A polygon has no area.") }
        return simd_normalize(value)
    }
    func validate(limit: Int = maxFaces, planarConvex: Bool = true) throws {
        guard !vertices.isEmpty, vertices.count <= (limit == Self.maxFaces ? Self.maxVertices : limit * 4), !faces.isEmpty,
              faces.count <= limit, Set(vertices.map(\.id)).count == vertices.count,
              Set(edges.map(\.id)).count == edges.count, Set(faces.map(\.id)).count == faces.count,
              vertices.allSatisfy({ [$0.point.x,$0.point.y,$0.point.z].allSatisfy { $0.isFinite && abs($0) <= 1e7 } }) else {
            throw CADPolygonFailure.invalid("The polygon cage exceeds its bounds or has invalid identities or coordinates.")
        }
        let map = points
        var sides: [Key: [(face: Int, forward: Bool)]] = [:]
        for (index, face) in faces.enumerated() {
            guard (3...64).contains(face.vertices.count), Set(face.vertices).count == face.vertices.count,
                  face.vertices.allSatisfy({ map[$0] != nil }) else { throw CADPolygonFailure.invalid("A polygon has repeated or missing vertices.") }
            let n = try normal(face, using: map), p = face.vertices.map { map[$0]! }
            if planarConvex {
                guard p.allSatisfy({ abs(simd_dot($0 - p[0], n)) < 1e-6 }) else {
                    throw CADPolygonFailure.unsupported("Editing non-planar control faces is unavailable. Triangulate the source before capture.")
                }
                for i in p.indices {
                    let before = p[i] - p[(i + p.count - 1) % p.count], after = p[(i + 1) % p.count] - p[i]
                    guard simd_dot(simd_cross(before, after), n) > 1e-10 else {
                        throw CADPolygonFailure.unsupported("Concave or collinear control faces need explicit triangulation before editing.")
                    }
                }
            }
            for i in face.vertices.indices {
                let a = face.vertices[i], b = face.vertices[(i + 1) % face.vertices.count], key = Key(a,b)
                guard simd_distance(map[a]!, map[b]!) > 1e-7 else { throw CADPolygonFailure.invalid("A control edge collapsed.") }
                sides[key, default: []].append((index, a == key.a))
            }
        }
        guard Set(edges.map(\.key)).count == edges.count, Set(edges.map(\.key)) == Set(sides.keys),
              sides.values.allSatisfy({ $0.count == 1 || ($0.count == 2 && $0[0].forward != $0[1].forward) }) else {
            throw CADPolygonFailure.invalid("The cage has a missing, repeated, non-manifold or inconsistently oriented edge.")
        }
        // Edge manifoldness alone misses a bow-tie vertex after a weld.
        var atVertex: [UUID: [Key]] = [:]
        for key in sides.keys { atVertex[key.a, default: []].append(key); atVertex[key.b, default: []].append(key) }
        for vertex in vertices {
            let incident = Dictionary(uniqueKeysWithValues: (atVertex[vertex.id] ?? []).map { ($0,sides[$0]!) })
            let boundary = incident.values.filter { $0.count == 1 }.count
            guard boundary == 0 || boundary == 2 else { throw CADPolygonFailure.invalid("A vertex has an invalid boundary fan.") }
            let all = Set(incident.values.flatMap { $0.map(\.face) })
            var reached: Set<Int> = all.first.map { [$0] } ?? []
            while true {
                let prior = reached
                for pair in incident.values where pair.contains(where: { reached.contains($0.face) }) { reached.formUnion(pair.map(\.face)) }
                if prior == reached { break }
            }
            guard reached == all else { throw CADPolygonFailure.invalid("The weld would create a disconnected vertex fan.") }
        }
    }
    static func box(width: Double, height: Double, depth: Double) throws -> Self {
        guard [width,height,depth].allSatisfy({ $0.isFinite && $0 > 1e-6 && $0 <= 1e6 }) else { throw CADPolygonFailure.invalid("Use finite positive box dimensions.") }
        let points: [SIMD3<Double>] = [[0,0,0],[width,0,0],[width,height,0],[0,height,0],[0,0,depth],[width,0,depth],[width,height,depth],[0,height,depth]]
        let vertices = points.map { Vertex(point: $0) }
        let loops = [[0,3,2,1],[4,5,6,7],[0,1,5,4],[3,7,6,2],[0,4,7,3],[1,2,6,5]]
        var cage = Self(vertices: vertices, edges: [], faces: loops.map { Face(vertices: $0.map { vertices[$0].id }) })
        cage.synchronizeEdges(); try cage.validate(); return cage
    }
    /// Capture actual polygon boundaries. No render triangle is assigned a
    /// durable old face identity; new author IDs are minted and stored once.
    static func capture(_ mesh: Euclid.Mesh, namespace: UUID? = nil) throws -> Self {
        var vertices: [Vertex] = [], lookup: [SIMD3<Double>: UUID] = [:], faces: [Face] = []
        for polygon in mesh.polygons {
            var ids: [UUID] = []
            for v in polygon.vertices {
                let point = SIMD3(v.position.x, v.position.y, v.position.z)
                let id: UUID
                if let found = lookup[point] { id = found }
                else {
                    let key = "v/\(point.x.bitPattern)/\(point.y.bitPattern)/\(point.z.bitPattern)"
                    id = namespace.map { derived($0,key) } ?? UUID(); lookup[point] = id
                    vertices.append(.init(id: id, point: point))
                }
                ids.append(id)
            }
            let text = ids.map(\.uuidString).joined(separator: "/")
            faces.append(Face(id: namespace.map { derived($0,"face/" + text) } ?? UUID(), vertices: ids))
        }
        var result = Self(vertices: vertices, edges: [], faces: faces); result.synchronizeEdges(namespace: namespace)
        try result.validate(limit: namespace == nil ? maxFaces : 32_768, planarConvex: namespace == nil)
        return result
    }
}

nonisolated enum CADPolygonFailure: Error, LocalizedError, Sendable {
    case invalid(String), unsupported(String), cancelled, timedOut
    var errorDescription: String? {
        switch self {
        case .invalid(let value), .unsupported(let value): return value
        case .cancelled: return "The mesh operation was cancelled."
        case .timedOut: return "The mesh operation exceeded its computation limit. The model was kept."
        }
    }
    var code: String {
        switch self { case .invalid: return "invalid_topology"; case .unsupported: return "unsupported_topology"; case .cancelled: return "cancelled"; case .timedOut: return "timeout" }
    }
}

nonisolated struct CADPolygonMeshDefinition: Codable, Equatable, Sendable {
    static let supportedVersion = 1
    nonisolated struct Modifier: Codable, Equatable, Sendable, Identifiable {
        nonisolated enum Operation: Codable, Equatable, Sendable {
            case subdivision(levels: Int)
            case mirror(axis: Int, offset: Double)
            /// Exact mesh bevel scope: one convex straight right-angle edge,
            /// first in the enabled stack. Other cases refuse, never no-op.
            case bevel(edge: UUID, width: Double)
        }
        var id: UUID = UUID()
        var enabled: Bool = true
        var operation: Operation
    }
    var version: Int = supportedVersion
    var cage: CADPolygonCage
    var modifiers: [Modifier] = []
    private enum CodingKeys: String, CodingKey { case version, cage, modifiers }
    init(cage: CADPolygonCage, modifiers: [Modifier] = []) { self.cage = cage; self.modifiers = modifiers }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard version == Self.supportedVersion else { throw CADPolygonFailure.unsupported("Unsupported polygon cage definition version \(version).") }
        cage = try c.decode(CADPolygonCage.self, forKey: .cage)
        modifiers = try c.decode([Modifier].self, forKey: .modifiers)
        try validate()
    }
    func validate() throws {
        guard version == Self.supportedVersion, modifiers.count <= 8,
              Set(modifiers.map(\.id)).count == modifiers.count else { throw CADPolygonFailure.invalid("Invalid modifier stack.") }
        try cage.validate()
        for modifier in modifiers {
            switch modifier.operation {
            case .subdivision(let levels): guard (1...2).contains(levels) else { throw CADPolygonFailure.unsupported("Subdivision supports one or two levels per modifier.") }
            case let .mirror(axis, offset): guard (0...2).contains(axis), offset.isFinite else { throw CADPolygonFailure.invalid("Use a finite mirror plane.") }
            case let .bevel(edge, width): guard (!modifier.enabled || cage.edges.contains(where: { $0.id == edge })), width.isFinite, width > 1e-6 else { throw CADPolygonFailure.invalid("The bevel needs an existing cage edge and positive width.") }
            }
        }
    }
    static func validatePlacement(_ value: Transform3D) throws {
        let q = value.rotation.vector, p = value.translation
        guard value.scale.isFinite, value.scale > 1e-8,
              [q.x,q.y,q.z,q.w,p.x,p.y,p.z].allSatisfy(\.isFinite), abs(simd_length(q) - 1) < 1e-6 else {
            throw CADPolygonFailure.invalid("The cage placement is invalid.")
        }
    }
    var digest: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(self) else { return "invalid" }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
