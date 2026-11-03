import Foundation
import simd
import Euclid

nonisolated enum CADPolygonMeshKernel {
    nonisolated struct Evaluation: Sendable {
        var mesh: Euclid.Mesh
        var render: RenderMesh
        var edges: FeatureEdgeSet
        var controlRender: RenderMesh
        var controlFaceIDs: [UUID]
        var controlEdges: FeatureEdgeSet
    }
    private nonisolated final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Evaluation] = [:]
        var order: [String] = []
        func clear() { lock.lock(); defer { lock.unlock() }; values = [:]; order = [] }
        func get(_ key: String) -> Evaluation? { lock.lock(); defer { lock.unlock() }; return values[key] }
        func put(_ key: String, _ value: Evaluation) {
            lock.lock(); defer { lock.unlock() }
            values[key] = value; order.removeAll { $0 == key }; order.append(key)
            while order.count > 2 { values.removeValue(forKey: order.removeFirst()) }
        }
    }
    private static let cache = Cache()
    /// Focused cold-replay tests must exercise the real evaluator, not an old cache hit.
    static func clearCachedEvaluationsForTesting() { cache.clear() }
    private static let finalFaceLimit = 32_768
    static func evaluate(_ definition: CADPolygonMeshDefinition, cancelled: @escaping @Sendable () -> Bool = { false }) throws -> Evaluation {
        if cancelled() { throw CADPolygonFailure.cancelled }
        let key = definition.digest
        if let result = cache.get(key) { return result }
        try definition.validate()
        if let sculpt=definition.sculpt {
            let resolved=try CADSculptKernel.resolve(sculpt,cancelled:cancelled)
            let final=try render(resolved.cage,smooth:true)
            guard final.render.triangleCount<=65_536,!final.mesh.isEmpty else { throw CADPolygonFailure.invalid("The sculpt mesh exceeds its display limit.") }
            if sculpt.base.isClosed,(!final.mesh.isWatertight || !final.mesh.signedVolume.isFinite || final.mesh.signedVolume<=1e-8) { throw CADPolygonFailure.invalid("The sculpt mesh is no longer a valid closed mesh.") }
            let points=resolved.cage.points
            let lines=resolved.cage.edges.flatMap { [SIMD3<Float>(points[$0.a]!),SIMD3<Float>(points[$0.b]!)] }
            let result=Evaluation(mesh:final.mesh,render:final.render,edges:FeatureEdgeExtractor.edges(from:final.render),
                controlRender:final.render,controlFaceIDs:final.channel,controlEdges:.init(segments:lines))
            cache.put(key,result);return result
        }
        let control = try render(definition.cage, smooth: false)
        var cage = definition.cage, smooth = false, enabledCount = 0
        for modifier in definition.modifiers where modifier.enabled {
            if cancelled() { throw CADPolygonFailure.cancelled }
            switch modifier.operation {
            case .subdivision(let levels):
                for level in 0..<levels { cage = try subdivide(cage, namespace: CADPolygonCage.derived(modifier.id,"level/\(level)"), cancelled: cancelled) }
                smooth = true
            case let .mirror(axis, offset): cage = try mirror(cage, axis: axis, offset: offset, namespace: modifier.id)
            case let .bevel(edge, width):
                guard enabledCount == 0 else { throw CADPolygonFailure.unsupported("Move the bevel before other enabled modifiers; its edge belongs to the control cage.") }
                cage = try bevel(cage, edge: edge, width: width, namespace: modifier.id, cancelled: cancelled)
            }
            enabledCount += 1
            guard cage.faces.count <= finalFaceLimit else { throw CADPolygonFailure.unsupported("The modifier stack exceeds the final mesh limit.") }
        }
        if cancelled() { throw CADPolygonFailure.cancelled }
        try cage.validate(limit: finalFaceLimit, planarConvex: false)
        let final = try render(cage, smooth: smooth)
        guard final.render.triangleCount <= 131_072, !final.mesh.isEmpty else { throw CADPolygonFailure.invalid("The modifiers produced no bounded mesh.") }
        if definition.cage.isClosed, (!final.mesh.isWatertight || !final.mesh.signedVolume.isFinite || final.mesh.signedVolume <= 1e-8) { throw CADPolygonFailure.invalid("The modifiers did not retain a closed mesh.") }
        let points = definition.cage.points
        let lines = definition.cage.edges.flatMap { [SIMD3<Float>(points[$0.a]!),SIMD3<Float>(points[$0.b]!)] }
        let result = Evaluation(mesh: final.mesh, render: final.render, edges: FeatureEdgeExtractor.edges(from: final.render),
            controlRender: control.render, controlFaceIDs: control.channel, controlEdges: .init(segments: lines))
        cache.put(key,result); return result
    }
    /// Euclid quantizes vertex positions at construction. Hit provenance must
    /// compare against those exact delivered positions, not the unquantized
    /// double cage, especially after multi-resolution sculpt deformation.
    static func renderedControlPoint(_ point: SIMD3<Double>) -> SIMD3<Float> {
        let vertex = Euclid.Vertex(Vector(point.x, point.y, point.z), Vector(0, 0, 1))
        return SIMD3(Float(vertex.position.x), Float(vertex.position.y), Float(vertex.position.z))
    }
    static func render(_ cage: CADPolygonCage, smooth: Bool) throws -> (mesh: Euclid.Mesh, render: RenderMesh, channel: [UUID]) {
        let points = cage.points
        var sums: [UUID: SIMD3<Double>] = [:]
        if smooth { for face in cage.faces { let n = try cage.normal(face,using: points); for id in face.vertices { sums[id, default: .zero] += n } } }
        var polygons: [Euclid.Polygon] = [], positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = [], channel: [UUID] = []
        for face in cage.faces {
            let n = try cage.normal(face,using: points)
            let vertices = face.vertices.map { id -> Euclid.Vertex in
                let p = points[id]!, sum = sums[id] ?? n, normal = simd_length(sum) > 1e-10 ? simd_normalize(sum) : n
                return Euclid.Vertex(Vector(p.x,p.y,p.z),Vector(normal.x,normal.y,normal.z))
            }
            let parts: [Euclid.Polygon]
            if let polygon = Euclid.Polygon(vertices) { parts = polygon.triangulate() }
            else {
                // Derived Catmull-Clark quads can be non-planar; authoring
                // polygons remain planar. Only final patches use this split.
                guard vertices.count == 4 else { throw CADPolygonFailure.invalid("A derived patch cannot be triangulated.") }
                // Select the same geometric diagonal after winding reversal.
                // Always splitting indices 0/2 changes a non-planar patch's
                // surface (and volume) when Mirror reverses its loop.
                let p = vertices.map { SIMD3($0.position.x,$0.position.y,$0.position.z) }
                let triangles = simd_length_squared(p[0] - p[2]) <= simd_length_squared(p[1] - p[3])
                    ? [[0,1,2],[0,2,3]] : [[0,1,3],[1,2,3]]
                guard let a = Euclid.Polygon(triangles[0].map { vertices[$0] }),
                      let b = Euclid.Polygon(triangles[1].map { vertices[$0] }) else { throw CADPolygonFailure.invalid("A derived patch cannot be triangulated.") }
                parts = [a,b]
            }
            guard !parts.isEmpty else { throw CADPolygonFailure.invalid("A polygon could not be displayed.") }
            polygons += parts
            for triangle in parts {
                guard triangle.vertices.count == 3 else { throw CADPolygonFailure.invalid("Triangulation did not produce triangles.") }
                for v in triangle.vertices {
                    indices.append(UInt32(positions.count)); positions.append(SIMD3(Float(v.position.x),Float(v.position.y),Float(v.position.z)))
                    normals.append(SIMD3(Float(v.normal.x),Float(v.normal.y),Float(v.normal.z)))
                }
                channel.append(face.id)
            }
        }
        return (Euclid.Mesh(polygons),RenderMesh(positions: positions,normals: normals,indices: indices),channel)
    }
    static func extrude(_ source: CADPolygonCage, face id: UUID, distance: Double, cancelled: @escaping @Sendable () -> Bool = { false }) throws -> CADPolygonCage {
        try source.validate()
        guard source.isClosed, distance.isFinite, distance > 1e-6, let index = source.faces.firstIndex(where: { $0.id == id }) else { throw CADPolygonFailure.unsupported("Select a closed cage face and a positive outward distance.") }
        let face = source.faces[index], n = try source.normal(source.faces[index]), points = source.points
        var result = source, cap: [UUID] = [], sides: [CADPolygonCage.Face] = []
        for old in face.vertices { let v = CADPolygonCage.Vertex(point: points[old]! + n * distance); result.vertices.append(v); cap.append(v.id) }
        result.faces[index].vertices = cap // explicitly moved cap keeps its own ID
        for i in cap.indices { let j = (i + 1) % cap.count; sides.append(.init(vertices: [face.vertices[i],face.vertices[j],cap[j],cap[i]])) }
        result.faces += sides; result.synchronizeEdges(); try result.validate()
        var prism = CADPolygonCage(vertices: result.vertices,edges: [],faces: [.init(vertices: Array(face.vertices.reversed())),.init(vertices: cap)] + sides)
        prism.synchronizeEdges(); try prism.validate()
        let before = try render(source,smooth: false).mesh, tool = try render(prism,smooth: false).mesh
        if cancelled() { throw CADPolygonFailure.cancelled }
        let overlap = before.intersection(tool,isCancelled: cancelled)
        if cancelled() { throw CADPolygonFailure.cancelled }
        guard abs(overlap.signedVolume) < max(1e-7,abs(tool.signedVolume) * 1e-7) else { throw CADPolygonFailure.unsupported("This extrusion intersects the cage. Use a smaller outward distance.") }
        return result
    }
    static func inset(_ source: CADPolygonCage, face id: UUID, distance: Double) throws -> CADPolygonCage {
        try source.validate()
        guard distance.isFinite, distance > 1e-6, let index = source.faces.firstIndex(where: { $0.id == id }) else { throw CADPolygonFailure.invalid("Select a face and positive inset distance.") }
        let face = source.faces[index], map = source.points, points = face.vertices.map { map[$0]! }
        let n = try source.normal(face), x = simd_normalize(points[1] - points[0]), y = simd_cross(n,x)
        let loop = points.map { SIMD2(simd_dot($0 - points[0],x),simd_dot($0 - points[0],y)) }
        guard let inset = ProfileOffset.offsetLoop(loop,by: -distance), inset.count == loop.count else { throw CADPolygonFailure.invalid("This inset collapses the face.") }
        for i in loop.indices { let j = (i + 1) % loop.count, edge = loop[j] - loop[i], left = SIMD2(-edge.y,edge.x) / simd_length(edge)
            guard simd_dot(inset[j] - inset[i],edge) > 1e-10, abs(simd_dot(inset[i] - loop[i],left) - distance) < 1e-6,
                  abs(simd_dot(inset[j] - loop[i],left) - distance) < 1e-6 else { throw CADPolygonFailure.invalid("This inset consumes an edge; the face was kept.") }
        }
        var result = source, inner: [UUID] = []
        for p in inset { let v = CADPolygonCage.Vertex(point: points[0] + x * p.x + y * p.y); result.vertices.append(v); inner.append(v.id) }
        result.faces[index].vertices = inner
        for i in inner.indices { let j = (i + 1) % inner.count; result.faces.append(.init(vertices: [face.vertices[i],face.vertices[j],inner[j],inner[i]])) }
        result.synchronizeEdges(); try result.validate(); return result
    }
    /// Cross opposite edges of every incident quad. A pole, triangle or a
    /// twisted strip refuses the complete edit instead of leaving T-junctions.
    static func loopCut(_ source: CADPolygonCage, edge id: UUID, fraction: Double) throws -> CADPolygonCage {
        try source.validate()
        guard fraction.isFinite, fraction > 1e-4, fraction < 1 - 1e-4, let seed = source.edges.first(where: { $0.id == id }) else { throw CADPolygonFailure.invalid("Select an edge and a fraction between zero and one.") }
        let incidence = source.incidence
        var fractions: [CADPolygonCage.Key: Double] = [seed.key: fraction], pending = [seed.key], cursor = 0, crossings: [Int: Int] = [:]
        while cursor < pending.count {
            let key = pending[cursor]; cursor += 1
            guard pending.count <= source.edges.count else { throw CADPolygonFailure.invalid("The edge ring is inconsistent.") }
            for index in incidence[key] ?? [] {
                let face = source.faces[index], keys = source.keys(face)
                if let crossed = crossings[index] {
                    guard key == keys[crossed] || key == keys[(crossed + 2) % 4] else {
                        throw CADPolygonFailure.unsupported("The quad strip crosses the same face twice. The cage was kept.")
                    }
                    continue
                }
                guard face.vertices.count == 4, let i = keys.firstIndex(of: key), let t = fractions[key] else { throw CADPolygonFailure.unsupported("Loop cut needs a continuous quad strip. Triangles and poles were kept.") }
                let j = (i + 2) % 4, other = keys[j], local = face.vertices[i] == key.a ? t : 1 - t
                let next = face.vertices[j] == other.a ? 1 - local : local
                if let old = fractions[other], abs(old - next) > 1e-8 { throw CADPolygonFailure.unsupported("The quad strip reverses its cut direction.") }
                if fractions[other] == nil { fractions[other] = next; pending.append(other) }; crossings[index] = i
            }
        }
        var result = source, inserted: [CADPolygonCage.Key: UUID] = [:]; let points = source.points
        for key in pending { let t = fractions[key]!, v = CADPolygonCage.Vertex(point: points[key.a]! * (1 - t) + points[key.b]! * t); result.vertices.append(v); inserted[key] = v.id }
        var faces: [CADPolygonCage.Face] = []
        for (index,face) in source.faces.enumerated() {
            guard let start = crossings[index] else { faces.append(face); continue }
            let v = (0..<4).map { face.vertices[(start + $0) % 4] }, p = inserted[.init(face.vertices[start],face.vertices[(start + 1) % 4])]!
            let q = inserted[.init(v[2],v[3])]!
            // Split children get new IDs; the old face is retired.
            faces += [.init(vertices: [v[0],p,q,v[3]]),.init(vertices: [p,v[1],v[2],q])]
        }
        result.faces = faces; result.synchronizeEdges(); try result.validate()
        if source.isClosed, !result.isClosed { throw CADPolygonFailure.invalid("The cut would open the cage.") }
        return result
    }
    static func weld(_ source: CADPolygonCage, vertices selected: [UUID], tolerance: Double) throws -> CADPolygonCage {
        try source.validate()
        guard (2...8).contains(selected.count), Set(selected).count == selected.count, tolerance.isFinite, tolerance > 0,
              let target = selected.first, let point = source.points[target],
              selected.allSatisfy({ source.points[$0].map { simd_distance($0,point) <= tolerance } == true }) else { throw CADPolygonFailure.invalid("Choose two to eight nearby vertices and a weld tolerance.") }
        let removed = Set(selected.dropFirst()), normals = try Dictionary(uniqueKeysWithValues: source.faces.map { ($0.id,try source.normal($0)) })
        var result = source
        result.faces = source.faces.compactMap { face in
            var ids: [UUID] = []; for id in face.vertices { let value = removed.contains(id) ? target : id; if ids.last != value { ids.append(value) } }
            if ids.first == ids.last { ids.removeLast() }; guard ids.count >= 3 else { return nil }; return .init(id: face.id,vertices: ids)
        }
        result.synchronizeEdges(); try result.validate()
        for face in result.faces where simd_dot(try result.normal(face),normals[face.id]!) <= 0 { throw CADPolygonFailure.invalid("This weld would reverse a face.") }
        if source.isClosed, !result.isClosed { throw CADPolygonFailure.invalid("This weld would open the cage.") }; return result
    }
    static func subdivide(_ source: CADPolygonCage, namespace: UUID, cancelled: @escaping @Sendable () -> Bool) throws -> CADPolygonCage {
        guard source.faces.reduce(0,{ $0 + $1.vertices.count }) <= finalFaceLimit else { throw CADPolygonFailure.unsupported("Subdivision exceeds the final mesh limit.") }
        try source.validate(limit: finalFaceLimit,planarConvex: false)
        let points = source.points, incidence = source.incidence
        let centers = source.faces.map { $0.vertices.reduce(SIMD3<Double>.zero) { $0 + points[$1]! } / Double($0.vertices.count) }
        var edgePoints: [CADPolygonCage.Key: CADPolygonCage.Vertex] = [:], facePoints: [Int: CADPolygonCage.Vertex] = [:]
        var vertexFaces: [UUID: [Int]] = [:], vertexEdges: [UUID: [CADPolygonCage.Edge]] = [:]
        for (i,face) in source.faces.enumerated() { facePoints[i] = .init(id: CADPolygonCage.derived(namespace,"fp/" + face.id.uuidString),point: centers[i]); for v in face.vertices { vertexFaces[v,default: []].append(i) } }
        for edge in source.edges {
            let adjacent = incidence[edge.key]!, mid = (points[edge.a]! + points[edge.b]!) / 2
            let p = adjacent.count == 2 ? (mid * 2 + centers[adjacent[0]] + centers[adjacent[1]]) / 4 : mid
            edgePoints[edge.key] = .init(id: CADPolygonCage.derived(namespace,"ep/" + edge.id.uuidString),point: p)
            vertexEdges[edge.a,default: []].append(edge); vertexEdges[edge.b,default: []].append(edge)
        }
        var vertices: [CADPolygonCage.Vertex] = []
        for vertex in source.vertices {
            if cancelled() { throw CADPolygonFailure.cancelled }
            let edges = vertexEdges[vertex.id] ?? [], faces = vertexFaces[vertex.id] ?? [], boundary = edges.filter { incidence[$0.key]?.count == 1 }
            let point: SIMD3<Double>
            if boundary.count == 2 { let other = boundary.map { points[$0.a == vertex.id ? $0.b : $0.a]! }; point = (vertex.point * 6 + other[0] + other[1]) / 8 }
            else {
                guard boundary.isEmpty, edges.count == faces.count, !faces.isEmpty else { throw CADPolygonFailure.invalid("Subdivision needs a manifold vertex fan.") }
                let n = Double(faces.count), f = faces.reduce(SIMD3<Double>.zero) { $0 + centers[$1] } / n
                let r = edges.reduce(SIMD3<Double>.zero) { $0 + (points[$1.a]! + points[$1.b]!) / 2 } / n
                point = (f + r * 2 + vertex.point * (n - 3)) / n
            }
            vertices.append(.init(id: vertex.id,point: point))
        }
        vertices += source.edges.map { edgePoints[$0.key]! }; vertices += source.faces.indices.map { facePoints[$0]! }
        var faces: [CADPolygonCage.Face] = []
        for (index,face) in source.faces.enumerated() { for i in face.vertices.indices {
            let v = face.vertices[i], next = face.vertices[(i + 1) % face.vertices.count], prior = face.vertices[(i + face.vertices.count - 1) % face.vertices.count]
            faces.append(.init(id: CADPolygonCage.derived(namespace,"f/" + face.id.uuidString + "/" + v.uuidString),vertices: [v,edgePoints[.init(v,next)]!.id,facePoints[index]!.id,edgePoints[.init(prior,v)]!.id]))
        } }
        var result = CADPolygonCage(vertices: vertices,edges: [],faces: faces); result.synchronizeEdges(namespace: namespace); return result
    }
    private static func mirror(_ source: CADPolygonCage, axis: Int, offset: Double, namespace: UUID) throws -> CADPolygonCage {
        let signed = source.vertices.map { $0.point[axis] - offset }
        guard !(signed.contains { $0 < -1e-7 } && signed.contains { $0 > 1e-7 }) else { throw CADPolygonFailure.unsupported("The mirror plane cuts through the cage. Place it on a boundary or outside it.") }
        var result = source, mapping: [UUID: UUID] = [:]
        for vertex in source.vertices {
            if abs(vertex.point[axis] - offset) < 1e-7 { mapping[vertex.id] = vertex.id }
            else { var p = vertex.point; p[axis] = 2 * offset - p[axis]; let id = CADPolygonCage.derived(namespace,"v/" + vertex.id.uuidString); result.vertices.append(.init(id: id,point: p)); mapping[vertex.id] = id }
        }
        let seam = Set(source.vertices.filter { abs($0.point[axis] - offset) < 1e-7 }.map(\.id))
        result.faces = source.faces.filter { !Set($0.vertices).isSubset(of: seam) }
        let mirrored = result.faces.map { CADPolygonCage.Face(id: CADPolygonCage.derived(namespace,"f/" + $0.id.uuidString),vertices: $0.vertices.reversed().map { mapping[$0]! }) }
        result.faces += mirrored; result.synchronizeEdges(namespace: namespace); return result
    }
    private static func bevel(_ cage: CADPolygonCage, edge id: UUID, width: Double, namespace: UUID, cancelled: @escaping @Sendable () -> Bool) throws -> CADPolygonCage {
        guard cage.faces.count <= 128, cage.isClosed, let edge = cage.edges.first(where: { $0.id == id }), let adjacent = cage.incidence[edge.key], adjacent.count == 2 else { throw CADPolygonFailure.unsupported("Bevel needs one edge of a closed cage.") }
        let n0 = try cage.normal(cage.faces[adjacent[0]]), n1 = try cage.normal(cage.faces[adjacent[1]]), points = cage.points
        let a = points[edge.a]!, b = points[edge.b]!, nearby = cage.edges.filter { $0.a == edge.a || $0.b == edge.a || $0.a == edge.b || $0.b == edge.b }
        let shortest = nearby.map { simd_distance(points[$0.a]!,points[$0.b]!) }.min() ?? 0
        guard abs(simd_dot(n0,n1)) < 1e-8, width < shortest / 4,
              cage.faces[adjacent[1]].vertices.allSatisfy({ simd_dot(points[$0]! - a,n0) <= 1e-7 }),
              cage.faces[adjacent[0]].vertices.allSatisfy({ simd_dot(points[$0]! - a,n1) <= 1e-7 }) else { throw CADPolygonFailure.unsupported("Bevel supports a small single convex right-angle edge. This selection was kept.") }
        let before = try render(cage,smooth: false).mesh
        let after = KernelOps.chamferEdge(mesh: before,p0: a,p1: b,normalA: n0,normalB: n1,setback: width,isCancelled: cancelled)
        if cancelled() { throw CADPolygonFailure.cancelled }
        let expected = simd_distance(a,b) * width * width / 2
        guard after.isWatertight, after.signedVolume > 0, abs((before.signedVolume - after.signedVolume) - expected) < max(1e-5,expected * 1e-5) else { throw CADPolygonFailure.unsupported("The bevel did not retain its measured wedge and closed mesh. The cage was kept.") }
        return try CADPolygonCage.capture(after,namespace: namespace)
    }
}
