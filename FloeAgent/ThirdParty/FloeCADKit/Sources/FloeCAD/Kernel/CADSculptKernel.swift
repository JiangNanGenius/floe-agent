// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd
import Euclid

nonisolated enum CADSculptKernel {
    nonisolated struct Resolved:Sendable {
        var cage:CADPolygonCage
        var mask:[UUID:Double]
    }
    static func resolve(_ state:CADSculptDefinition,level requested:Int?=nil,cancelled:@escaping @Sendable ()->Bool={false}) throws -> Resolved {
        try state.validate()
        let target=requested ?? state.activeLevel
        guard state.levels.indices.contains(target) else { throw CADPolygonFailure.invalid("The sculpt level is unavailable.") }
        var cage=state.base,mask:[UUID:Double]=[:]
        for index in 0...target {
            if cancelled() { throw CADPolygonFailure.cancelled }
            let layer=state.levels[index]
            if index>0 {
                let old=cage
                cage=try CADPolygonMeshKernel.subdivide(old,namespace:layer.id,cancelled:cancelled)
                // Conservative mask inheritance: old vertices keep their
                // weight; new edge/face points inherit their maximum parent
                // weight. Explicit per-level unmask still overrides it.
                var inherited=mask
                for edge in old.edges { inherited[CADPolygonCage.derived(layer.id,"ep/"+edge.id.uuidString)]=max(mask[edge.a] ?? 0,mask[edge.b] ?? 0) }
                for face in old.faces { inherited[CADPolygonCage.derived(layer.id,"fp/"+face.id.uuidString)]=face.vertices.map { mask[$0] ?? 0 }.max() ?? 0 }
                mask=inherited
            }
            guard cage.faces.count<=CADSculptDefinition.maxFaces,cage.vertices.count<=CADSculptDefinition.maxVertices else { throw CADPolygonFailure.unsupported("This subdivision exceeds the sculpt mesh limit. The current levels were kept.") }
            let indices=Dictionary(uniqueKeysWithValues:cage.vertices.enumerated().map { ($0.element.id,$0.offset) })
            for offset in layer.offsets {
                guard let index=indices[offset.vertex] else { throw CADPolygonFailure.invalid("Sculpt detail names a retired vertex.") }
                cage.vertices[index].point += offset.vector
            }
            for value in layer.mask {
                guard indices[value.vertex] != nil else { throw CADPolygonFailure.invalid("The sculpt mask names a retired vertex.") };mask[value.vertex]=value.value
            }
            try cage.validate(limit:CADSculptDefinition.maxFaces,planarConvex:false)
        }
        return .init(cage:cage,mask:mask)
    }
    static func apply(_ edit:CADSculptEdit,to original:CADPolygonMeshDefinition,cancelled:@escaping @Sendable ()->Bool) throws -> CADPolygonMeshDefinition {
        if cancelled() { throw CADPolygonFailure.cancelled }
        var definition=original
        if case .begin=edit {
            guard definition.sculpt==nil else { throw CADPolygonFailure.invalid("This mesh already has sculpt levels.") }
            let evaluated=try CADPolygonMeshKernel.evaluate(definition,cancelled:cancelled)
            guard evaluated.mesh.polygons.reduce(0,{ $0+$1.triangulate().count })<=2048 else { throw CADPolygonFailure.unsupported("Start sculpting on at most 2048 triangles. Keep the original mesh until it is simplified explicitly.") }
            let base=try CADPolygonCage.capture(Euclid.Mesh(evaluated.mesh.polygons.flatMap { $0.triangulate() }),namespace:UUID())
            definition.sculpt=CADSculptDefinition(sourceDigest:definition.digest,base:base)
        } else {
            guard var state=definition.sculpt else { throw CADPolygonFailure.invalid("Start sculpting this editable polygon mesh first.") }
            switch edit {
            case .begin:break
            case .subdivide:
                guard state.levels.count<CADSculptDefinition.maxLevels,state.activeLevel==state.levels.count-1 else { throw CADPolygonFailure.unsupported("Add a level from the highest existing level, up to four levels.") }
                state.levels.append(.init());state.activeLevel+=1
            case let .level(index):
                guard state.levels.indices.contains(index) else { throw CADPolygonFailure.invalid("Choose an existing sculpt level.") };state.activeLevel=index
            case .clearMask:
                let resolved=try resolve(state,cancelled:cancelled)
                state.levels[state.activeLevel].mask=resolved.cage.vertices.map { .init(vertex:$0.id,value:0) }
            case let .stroke(stroke):state=try self.stroke(stroke,state:state,cancelled:cancelled)
            }
            definition.sculpt=state
        }
        try definition.validate()
        // Validate retained higher detail after a lower-level edit; never
        // persist a hidden broken upper level merely because it is inactive.
        if let state=definition.sculpt {
            for level in state.levels.indices {
                let geometry=try resolve(state,level:level,cancelled:cancelled)
                let displayed=try CADPolygonMeshKernel.render(geometry.cage,smooth:true)
                guard let health=CADMeshIntegrity.inspect(displayed.render,shouldStop:cancelled) else {
                    if cancelled() { throw CADPolygonFailure.cancelled };throw CADPolygonFailure.invalid("The sculpt mesh could not be inspected.")
                }
                guard health.degenerateTriangles==0,health.selfIntersectionPairs==0,health.nonManifoldEdges==0,!health.inconsistentWinding else { throw CADPolygonFailure.invalid("The stroke would create intersecting, collapsed or non-manifold mesh geometry. The model was kept.") }
                if state.base.isClosed,(!displayed.mesh.isWatertight || displayed.mesh.signedVolume<=1e-8 || !displayed.mesh.signedVolume.isFinite) { throw CADPolygonFailure.invalid("The stroke would break the closed sculpt mesh. The model was kept.") }
            }
        }
        if cancelled() { throw CADPolygonFailure.cancelled };return definition
    }
    static func pickSamples(_ definition:CADPolygonMeshDefinition,placement:Transform3D) -> [[String:Any]] {
        guard definition.sculpt != nil,let evaluated=try? CADPolygonMeshKernel.evaluate(definition),evaluated.render.triangleCount>0 else { return [] }
        guard let state=definition.sculpt,let resolved=try? resolve(state) else { return [] }
        let points=resolved.cage.points,faces=Dictionary(uniqueKeysWithValues:resolved.cage.faces.map { ($0.id,$0) })
        let render=evaluated.render,total=render.triangleCount,count=min(32,total)
        return (0..<count).map { index in
            let triangle=index*total/count
            let vertices=(0..<3).map { render.positions[Int(render.indices[triangle*3+$0])] }
            let local=(vertices[0]+vertices[1]+vertices[2])/3,world=placement.matrixFloat*SIMD4(local,1)
            let face=faces[evaluated.controlFaceIDs[triangle]]
            let weights=vertices.map { point -> Double in
                guard let id=face?.vertices.first(where:{ CADPolygonMeshKernel.renderedControlPoint(points[$0]!)==point }) else { return 0 }
                return resolved.mask[id] ?? 0
            }
            return ["triangle":triangle,"barycentric":[1.0/3,1.0/3,1.0/3],"world_center":[Double(world.x),Double(world.y),Double(world.z)],"mask_average":weights.reduce(0,+)/3]
        }
    }
    private static func stroke(_ stroke:CADSculptStroke,state original:CADSculptDefinition,cancelled:@escaping @Sendable ()->Bool) throws -> CADSculptDefinition {
        try stroke.validate()
        var state=original,resolved=try resolve(state,cancelled:cancelled),cage=resolved.cage
        let source=try CADPolygonMeshKernel.render(cage,smooth:true)
        let faceMap=Dictionary(uniqueKeysWithValues:cage.faces.map { ($0.id,$0) }),sourcePoints=cage.points
        // Hits always address the immutable stroke-start render. Deformation
        // does not retarget a later triangle to an unrelated surface.
        let centers=try stroke.samples.map { sample -> (SIMD3<Double>,[UUID],Double) in
            guard sample.triangle<source.render.triangleCount,source.channel.indices.contains(sample.triangle),let face=faceMap[source.channel[sample.triangle]] else { throw CADPolygonFailure.invalid("The stroke triangle is stale.") }
            let points=(0..<3).map { source.render.positions[Int(source.render.indices[sample.triangle*3+$0])] }
            let weights=sample.barycentric
            let point=SIMD3<Double>(points[0])*weights.x+SIMD3<Double>(points[1])*weights.y+SIMD3<Double>(points[2])*weights.z
            let seeds=points.compactMap { point in face.vertices.first { CADPolygonMeshKernel.renderedControlPoint(sourcePoints[$0]!)==point } }
            guard seeds.count==3,Set(seeds).count==3 else { throw CADPolygonFailure.invalid("The sculpt hit no longer identifies an actual triangle's vertices.") }
            return (point,seeds,sample.pressure)
        }
        let indices=Dictionary(uniqueKeysWithValues:cage.vertices.enumerated().map { ($0.element.id,$0.offset) })
        var adjacent:[UUID:[UUID]]=[:]
        for edge in cage.edges { adjacent[edge.a,default:[]].append(edge.b);adjacent[edge.b,default:[]].append(edge.a) }
        var mask=resolved.mask
        for (center,seeds,pressure) in centers {
            if cancelled() { throw CADPolygonFailure.cancelled };if pressure==0 || stroke.brush.strength==0 { continue }
            let points=cage.points
            let changesGeometry=stroke.brush.mode == .inflate || stroke.brush.mode == .smooth
            let beforeNormals:[UUID:SIMD3<Double>]
            if changesGeometry { beforeNormals=try Dictionary(uniqueKeysWithValues:cage.faces.map { ($0.id,try cage.normal($0,using:points)) }) }
            else { beforeNormals=[:] }
            let distances=try geodesic(center:center,seeds:seeds,points:points,adjacent:adjacent,radius:stroke.brush.radius,cancelled:cancelled)
            var normals:[UUID:SIMD3<Double>]=[:]
            if stroke.brush.mode == .inflate {
                for face in cage.faces { let n=try cage.normal(face,using:points);for id in face.vertices { normals[id,default:.zero]+=n } }
            }
            for (id,distance) in distances {
                guard let index=indices[id] else { continue }
                let q=max(0,1-distance/stroke.brush.radius),falloff=q*q*(3-2*q)
                let amount=stroke.brush.strength*pressure*falloff
                if stroke.brush.mode == .mask || stroke.brush.mode == .unmask {
                    let prior=mask[id] ?? 0
                    mask[id]=min(1,max(0,prior+(stroke.brush.mode == .mask ? amount:-amount)))
                } else {
                    let weight=amount*(1-(mask[id] ?? 0));guard weight>0 else { continue }
                    let delta:SIMD3<Double>
                    if stroke.brush.mode == .smooth {
                        let neighbors=adjacent[id] ?? [];guard !neighbors.isEmpty else { continue }
                        let average=neighbors.reduce(SIMD3<Double>.zero) { $0+points[$1]! }/Double(neighbors.count)
                        // Jacobi: every displacement reads the same stamp's
                        // frozen positions, never previously updated neighbors.
                        delta=(average-points[id]!)*(0.25*weight)
                    } else {
                        let n=normals[id] ?? .zero;guard simd_length(n)>1e-10 else { continue }
                        delta=simd_normalize(n)*(stroke.brush.radius*0.1*weight*(stroke.brush.inverted ? -1:1))
                    }
                    cage.vertices[index].point += delta
                }
            }
            try cage.validate(limit:CADSculptDefinition.maxFaces,planarConvex:false)
            if changesGeometry {
                for face in cage.faces where simd_dot(try cage.normal(face),beforeNormals[face.id]!)<=0 {
                    throw CADPolygonFailure.invalid("The stroke would reverse a mesh face. Use a smaller brush strength.")
                }
            }
        }
        var offsets=Dictionary(uniqueKeysWithValues:state.levels[state.activeLevel].offsets.map { ($0.vertex,$0.vector) })
        let before=resolved.cage.points
        for vertex in cage.vertices { offsets[vertex.id,default:.zero] += vertex.point-before[vertex.id]! }
        state.levels[state.activeLevel].offsets=offsets.filter { simd_length_squared($0.value)>0 }.sorted { $0.key.uuidString<$1.key.uuidString }.map { .init(vertex:$0.key,vector:$0.value) }
        if stroke.brush.mode == .mask || stroke.brush.mode == .unmask {
            var values=Dictionary(uniqueKeysWithValues:state.levels[state.activeLevel].mask.map { ($0.vertex,$0.value) })
            for (id,value) in mask where value != (resolved.mask[id] ?? 0) { values[id]=value }
            state.levels[state.activeLevel].mask=values.sorted { $0.key.uuidString<$1.key.uuidString }.map { .init(vertex:$0.key,value:$0.value) }
        }
        try state.validate();return state
    }
    /// Dijkstra over the actual connected edge neighborhood. A brush cannot
    /// tunnel to the back wall or to a disconnected coincident component.
    private static func geodesic(center:SIMD3<Double>,seeds:[UUID],points:[UUID:SIMD3<Double>],adjacent:[UUID:[UUID]],radius:Double,cancelled:@escaping @Sendable ()->Bool) throws -> [UUID:Double] {
        struct Item {var id:UUID;var distance:Double}
        var heap:[Item]=[],distances:[UUID:Double]=[:]
        func push(_ item:Item) { heap.append(item);var i=heap.count-1;while i>0 {let p=(i-1)/2;if heap[p].distance<=heap[i].distance {break};heap.swapAt(i,p);i=p} }
        func pop() -> Item? { guard !heap.isEmpty else {return nil};if heap.count==1 {return heap.removeLast()};let first=heap[0];heap[0]=heap.removeLast();var i=0;while i*2+1<heap.count {var c=i*2+1;if c+1<heap.count && heap[c+1].distance<heap[c].distance {c+=1};if heap[i].distance<=heap[c].distance {break};heap.swapAt(i,c);i=c};return first }
        for id in seeds { if let point=points[id] {let d=simd_distance(center,point);if d<radius {distances[id]=d;push(.init(id:id,distance:d))}} }
        var visited=0
        while let item=pop() {
            visited+=1;if visited%64==0 && cancelled() {throw CADPolygonFailure.cancelled}
            if item.distance != distances[item.id] {continue}
            for next in adjacent[item.id] ?? [] {
                let d=item.distance+simd_distance(points[item.id]!,points[next]!)
                if d<radius && d<(distances[next] ?? .infinity) {distances[next]=d;push(.init(id:next,distance:d))}
            }
        }
        return distances
    }
}
