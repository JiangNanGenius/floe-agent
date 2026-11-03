// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd

/// Conservative voxelization reuses the existing triangle BVH and exact
/// point-to-triangle primitive. A cell is a surface barrier when its centre
/// is within half its diagonal of the scan. Every intersected cell is included
/// (additional cells may be included). Six-neighbour exterior flood then fills
/// bounded interior regions. The output is the exposed cubical boundary, not
/// a smoothed, projected, analytic, quad-flow or feature-preserving surface.
nonisolated enum CADVoxelRemeshKernel {
    static let maxCells = 262_144
    static let maxAxisCells = 96
    static let maxQuads = 32_768
    static let maxDeviationQueries = 200_000
    /// Test observation after a real cell-centre BVH query, never input validation.
    nonisolated(unsafe) static var testCellQueryProbe: (@Sendable (Int) -> Void)?
    nonisolated struct Evaluation: Sendable {
        let render: RenderMesh
        let edges: FeatureEdgeSet
        let cage: CADPolygonCage
        let gridDimensions: [Int]
        let barrierCells, interiorCells, solidCells: Int
        let inputIntegrity, outputIntegrity: CADMeshIntegrity.Report
        let sampledDistanceMM, distanceUpperBoundMM: Double
        let distanceQueries: Int
        let volumeMM3: Double
        var payload: [String: Any] {
            ["representation":"voxel_surface_mesh", "exactness":"mesh", "analyticSurface":false,
             "surfaceType":"body_local_axis_aligned_cubical_boundary", "gridFrame":"body_local", "gridDimensions":gridDimensions,
             "gridCellCount":gridDimensions.reduce(1,*), "barrierCells":barrierCells,
             "interiorCells":interiorCells,"solidCells":solidCells,"quadCount":cage.faces.count,
             "triangleCount":render.triangleCount,"inputIntegrity":inputIntegrity.payload,
             "outputIntegrity":outputIntegrity.payload,"surfaceSampledMaxDistanceMM":sampledDistanceMM,
             "surfaceDistanceUpperBoundMM":distanceUpperBoundMM,"distanceIsExactHausdorff":false,
             "distanceMethod":"bidirectional_BVH_nearest_triangle_adaptive_centroid_cover",
             "upperBoundMethod":"distance_to_surface_is_1_Lipschitz_complete_triangle_cover",
             "distanceQueryCount":distanceQueries+gridDimensions.reduce(1,*),
             "deviationQueryCount":distanceQueries,"voxelQueryCount":gridDimensions.reduce(1,*),
             "signedMeshVolumeMM3":volumeMM3,
             "volumeIsValidatedBRepSolid":false,"sourceRetained":true,"sourceSnapshotRetained":true,"uvTransferred":false]
        }
    }
    private nonisolated final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var key: String?, value: Evaluation?
        func get(_ key: String) -> Evaluation? { lock.lock(); defer { lock.unlock() }; return self.key == key ? value : nil }
        func put(_ key: String, _ value: Evaluation) { lock.lock(); defer { lock.unlock() }; self.key = key; self.value = value }
        func clear() { lock.lock(); defer { lock.unlock() }; key = nil; value = nil }
    }
    private static let cache = Cache()
    static func clearCachedEvaluationsForTesting() { cache.clear() }
    static func evaluate(_ definition: CADVoxelRemeshDefinition, scale: Double,
                         cancelled: @escaping @Sendable () -> Bool = { false }) throws -> Evaluation {
        let clock = EvaluationDeadlineClock(seconds: 60)
        let stop: @Sendable () -> Bool = { cancelled() || clock.isExpired() }
        func check() throws {
            if cancelled() { throw CADVoxelFailure.cancelled }
            if clock.isExpired() { throw CADVoxelFailure.timedOut }
        }
        do {
            try check(); try definition.validate(stop)
            guard scale.isFinite, scale > 1e-8, scale < 1e8 else { throw CADVoxelFailure.invalid("The scan placement scale is invalid.") }
            let key = definition.digest + "/" + String(scale.bitPattern)
            try check()
            if let result = cache.get(key) { return result }
            let scan = definition.source.render
            // Degenerates have no surface. Leave them in the immutable scan,
            // but omit them from the distance geometry. All nonzero triangles,
            // including reversed and repeated ones, take part in voxelization.
            var indices: [UInt32] = [], used: Set<UInt32> = []
            for t in 0..<scan.triangleCount {
                try check()
                let ids = Array(scan.indices[(t*3)..<(t*3+3)])
                let p = ids.map { SIMD3<Double>(scan.positions[Int($0)]) }
                if simd_length_squared(simd_cross(p[1]-p[0],p[2]-p[0])) == 0 { continue }
                indices.append(contentsOf:ids); used.formUnion(ids)
            }
            guard !indices.isEmpty else { throw CADVoxelFailure.unsupported("The scan has no non-degenerate surface triangles.") }
            let ordered = used.sorted(), remap = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element,UInt32($0.offset)) })
            let positions = ordered.map { scan.positions[Int($0)] }
            indices = indices.map { remap[$0]! }
            let source = CADInterferenceMeshGeometry.build(positions:positions,indices:indices,shouldStop:stop)
            try check()
            guard source.isValid else { throw CADVoxelFailure.invalid("The scan distance geometry could not be inspected.") }
            let h = definition.voxelSizeMM / scale, extent = source.bounds.max - source.bounds.min
            guard h.isFinite, h > 0, min(extent.x,min(extent.y,extent.z)) >= h * 4 else {
                throw CADVoxelFailure.unsupported("Use at least four voxels across every scan dimension. Thin sheets and open surfaces are unavailable.")
            }
            // Float output must resolve adjacent grid planes. This is a
            // representation guard, not a hidden weld or geometric tolerance.
            let coordinate = max(1,max(simd_length(source.bounds.min),simd_length(source.bounds.max)))
            guard h > coordinate * Double(Float.ulpOfOne) * 8 else { throw CADVoxelFailure.budget("This voxel size is below the mesh coordinate precision. Move the scan near the origin or use larger voxels.") }
            let counts = [extent.x,extent.y,extent.z].map { ceil($0/h) + 4 }
            guard counts.allSatisfy({ $0.isFinite && $0 >= 8 && $0 <= Double(maxAxisCells) }) else {
                throw CADVoxelFailure.budget("The grid exceeds 96 cells on an axis. Use larger voxels.")
            }
            let dims = counts.map(Int.init), nx = dims[0], ny = dims[1], nz = dims[2], total = nx*ny*nz
            guard total <= maxCells else { throw CADVoxelFailure.budget("The grid exceeds 262,144 cells. Use larger voxels.") }
            let origin = source.bounds.min - SIMD3<Double>(repeating:2*h)
            func index(_ x: Int,_ y: Int,_ z: Int) -> Int { (z*ny+y)*nx+x }
            func coordinates(_ i: Int) -> SIMD3<Int> { SIMD3(i%nx,(i/nx)%ny,i/(nx*ny)) }
            let steps: [SIMD3<Int>] = [[-1,0,0],[1,0,0],[0,-1,0],[0,1,0],[0,0,-1],[0,0,1]]
            func add(_ p: SIMD3<Int>,_ q: SIMD3<Int>) -> SIMD3<Int> { SIMD3(p.x+q.x,p.y+q.y,p.z+q.z) }
            func valid(_ p: SIMD3<Int>) -> Bool { p.x >= 0 && p.y >= 0 && p.z >= 0 && p.x < nx && p.y < ny && p.z < nz }
            var cells = [UInt8](repeating:0,count:total), barriers = 0
            let radius = sqrt(3) * h / 2
            for i in cells.indices {
                try check()
                let xyz = coordinates(i), center = origin + (SIMD3<Double>(Double(xyz.x),Double(xyz.y),Double(xyz.z)) + SIMD3<Double>(repeating:0.5))*h
                guard let d = CADMeshSimplificationQuality.nearest(center,source,stop) else { try check(); throw CADVoxelFailure.invalid("The scan distance query failed.") }
                testCellQueryProbe?(i)
                if d <= radius + h*1e-12 { cells[i] = 1; barriers += 1 }
            }
            // The padded border must stay free; never treat a clipped scan as
            // a closed exterior. Padding is part of the versioned algorithm.
            for i in cells.indices {
                try check(); let p = coordinates(i)
                if p.x == 0 || p.y == 0 || p.z == 0 || p.x == nx-1 || p.y == ny-1 || p.z == nz-1 {
                    guard cells[i] == 0 else { throw CADVoxelFailure.unsupported("The surface band touches the grid border.") }
                }
            }
            var queue = [0], cursor = 0; cells[0] = 2
            while cursor < queue.count {
                try check(); let p = coordinates(queue[cursor]); cursor += 1
                for step in steps {
                    let q = add(p,step)
                    if valid(q) { let j = index(q.x,q.y,q.z); if cells[j] == 0 { cells[j] = 2; queue.append(j) } }
                }
            }
            let interior = cells.reduce(0) { $0 + ($1 == 0 ? 1 : 0) }, solid = total - queue.count
            guard interior >= 8 else { throw CADVoxelFailure.unsupported("The scan does not enclose at least eight interior voxels at this resolution. Large holes, open sheets and thin features need a different input or voxel size.") }
            var vertices: [CADPolygonCage.Vertex] = [], faces: [CADPolygonCage.Face] = [], lookup: [SIMD3<Int>: UUID] = [:]
            let corners: [[SIMD3<Int>]] = [
                [[0,0,0],[0,0,1],[0,1,1],[0,1,0]], [[1,0,0],[1,1,0],[1,1,1],[1,0,1]],
                [[0,0,0],[1,0,0],[1,0,1],[0,0,1]], [[0,1,0],[0,1,1],[1,1,1],[1,1,0]],
                [[0,0,0],[0,1,0],[1,1,0],[1,0,0]], [[0,0,1],[1,0,1],[1,1,1],[0,1,1]]]
            for i in cells.indices where cells[i] != 2 {
                try check(); let p = coordinates(i)
                for side in steps.indices {
                    let q = add(p,steps[side])
                    if valid(q), cells[index(q.x,q.y,q.z)] != 2 { continue }
                    guard faces.count < maxQuads else { throw CADVoxelFailure.budget("The reconstructed boundary exceeds 32,768 quads. Use larger voxels.") }
                    var ids: [UUID] = []
                    for offset in corners[side] {
                        let v = add(p,offset)
                        if let id = lookup[v] { ids.append(id) }
                        else {
                            let id = CADPolygonCage.derived(definition.id,"grid-v/\(h.bitPattern)/\(v.x)/\(v.y)/\(v.z)")
                            lookup[v] = id; ids.append(id)
                            vertices.append(.init(id:id,point:origin+SIMD3<Double>(Double(v.x),Double(v.y),Double(v.z))*h))
                        }
                    }
                    let id = CADPolygonCage.derived(definition.id,"grid-f/\(h.bitPattern)/\(p.x)/\(p.y)/\(p.z)/\(side)")
                    faces.append(.init(id:id,vertices:ids))
                }
            }
            var cage = CADPolygonCage(vertices:vertices,edges:[],faces:faces); cage.synchronizeEdges(namespace:definition.id)
            try check()
            // Explicit edge and connected vertex-fan validation rejects
            // diagonal voxel contacts. Never duplicate vertices to hide them.
            do { try cage.validate(limit:maxQuads) }
            catch { throw CADVoxelFailure.unsupported("This resolution produces a non-manifold voxel boundary. Use a different voxel size; the scan was kept.") }
            try check()
            let map = cage.points
            var outPositions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], outIndices: [UInt32] = []
            for face in cage.faces {
                try check(); let points = face.vertices.map { map[$0]! }, base = UInt32(outPositions.count)
                let normal = SIMD3<Float>(simd_normalize(simd_cross(points[1]-points[0],points[2]-points[0])))
                outPositions.append(contentsOf:points.map { SIMD3<Float>($0) }); normals.append(contentsOf:[normal,normal,normal,normal])
                outIndices.append(contentsOf:[base,base+1,base+2,base,base+2,base+3])
            }
            let render = RenderMesh(positions:outPositions,normals:normals,indices:outIndices)
            let output = CADInterferenceMeshGeometry.build(positions:render.positions,indices:render.indices,shouldStop:stop)
            try check()
            guard output.isValid, output.topology.isWatertight, output.topology.componentCount == 1,
                  output.topology.inwardComponentCount == 0 else { throw CADVoxelFailure.unsupported("The reconstruction is not one closed outward manifold surface.") }
            guard let before = CADMeshIntegrity.inspect(scan,shouldStop:stop), let after = CADMeshIntegrity.inspect(render,shouldStop:stop) else { try check(); throw CADVoxelFailure.invalid("The mesh integrity inspection did not finish.") }
            guard !after.unresolved else { throw CADVoxelFailure.unsupported("The reconstructed surface failed mesh integrity checks.") }
            let quality = try deviation(source,output,limit:definition.maxDeviationMM/scale,stop:stop)
            var volume = 0.0
            for t in 0..<output.triangleCount {
                try check(); let p = output.triangle(t), o = output.bounds.min
                volume += simd_dot(p.0-o,simd_cross(p.1-o,p.2-o))/6
            }
            guard volume > 0, abs(volume-Double(solid)*h*h*h) <= max(1e-6,volume*1e-5) else { throw CADVoxelFailure.invalid("The emitted mesh volume differs from its occupied cells.") }
            let lines = cage.edges.flatMap { [SIMD3<Float>(map[$0.a]!),SIMD3<Float>(map[$0.b]!)] }
            let result = Evaluation(render:render,edges:.init(segments:lines),cage:cage,gridDimensions:dims,
                barrierCells:barriers,interiorCells:interior,solidCells:solid,inputIntegrity:before,outputIntegrity:after,
                sampledDistanceMM:quality.sample*scale,distanceUpperBoundMM:quality.bound*scale,distanceQueries:quality.queries,
                volumeMM3:volume*scale*scale*scale)
            try check(); cache.put(key,result); return result
        } catch {
            try check(); throw error
        }
    }
    /// An independent post-reconstruction surface certificate. Every source
    /// and result triangle is covered. An exact nearest-triangle distance at
    /// each accepted subtriangle centroid + its farthest-vertex radius bounds
    /// all its points. Subdivision is only for measurement, never construction.
    private static func deviation(_ a: CADInterferenceMeshGeometry,_ b: CADInterferenceMeshGeometry,
                                  limit: Double,stop: @escaping () -> Bool) throws -> (sample:Double,bound:Double,queries:Int) {
        var sample = 0.0, bound = 0.0, queries = 0
        for (source,target) in [(a,b),(b,a)] {
            for t in 0..<source.triangleCount {
                let tri = source.triangle(t)
                var stack: [(SIMD3<Double>,SIMD3<Double>,SIMD3<Double>,Int)] = [(tri.0,tri.1,tri.2,0)]
                while let (p,q,r,depth) = stack.popLast() {
                    if stop() { throw CADVoxelFailure.cancelled }
                    guard queries < maxDeviationQueries else { throw CADVoxelFailure.budget("The complete deviation certificate exceeds 200,000 queries. Increase the deviation limit or voxel size.") }
                    queries += 1; let center = (p+q+r)/3
                    guard let d = CADMeshSimplificationQuality.nearest(center,target,stop) else { throw CADVoxelFailure.cancelled }
                    sample = max(sample,d)
                    guard d <= limit else { throw CADVoxelFailure.deviation("The reconstructed surface exceeds the requested deviation limit. The scan was kept.") }
                    let radius = max(simd_distance(center,p),max(simd_distance(center,q),simd_distance(center,r)))
                    // Positive floating-point allowance is included in the
                    // reported bound, never subtracted from the requested cap.
                    let upper = d + radius + max(1e-10,simd_length(center)*1e-14)
                    if upper <= limit { bound = max(bound,upper); continue }
                    guard depth < 28 else { throw CADVoxelFailure.budget("The complete deviation bound could not resolve within its subdivision budget.") }
                    let pq = simd_length_squared(q-p), qr = simd_length_squared(r-q), rp = simd_length_squared(p-r)
                    if pq >= qr && pq >= rp { let m = (p+q)/2; stack.append((p,m,r,depth+1)); stack.append((m,q,r,depth+1)) }
                    else if qr >= rp { let m = (q+r)/2; stack.append((p,q,m,depth+1)); stack.append((p,m,r,depth+1)) }
                    else { let m = (r+p)/2; stack.append((p,q,m,depth+1)); stack.append((m,q,r,depth+1)) }
                }
            }
        }
        return (sample,bound,queries)
    }
}
