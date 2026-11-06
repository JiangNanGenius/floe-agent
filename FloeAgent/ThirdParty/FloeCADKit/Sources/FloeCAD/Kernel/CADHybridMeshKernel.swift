// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd
import Euclid
import ManifoldShim

/// No live document, BRep, undo closure or renderer enters the worker.
/// Manifold owns solid topology and Booleans. Floe supplies bounds, immutable
/// history, explicit mesh exactness and cancellation/commit fences.
nonisolated enum CADHybridMeshKernel {
    nonisolated struct Evaluation:Sendable {
        let render:RenderMesh
        let volume:Double
        let sourceVolume:Double
        var payload:[String:Any] { ["exactness":"mesh","algorithm":CADHybridFeatureDefinition.algorithmV1,
            "triangleCount":render.triangleCount,"volumeMM3":volume,"sourceVolumeMM3":sourceVolume,
            "sourceRetained":true,"watertight":true,"outputUVTransferred":false] }
    }
    private nonisolated final class Context:@unchecked Sendable {
        let raw:OpaquePointer
        private let timer:DispatchSourceTimer
        private let lock=NSLock()
        private var expired=false
        init(seconds:Double) throws {
            guard let raw=floe_manifold_context_create() else { throw CADHybridFailure.kernel("The mesh kernel could not allocate a context.") }
            self.raw=raw
            timer=DispatchSource.makeTimerSource(queue:.global(qos:.userInitiated))
            timer.schedule(deadline:.now()+seconds)
            timer.setEventHandler { [weak self] in self?.expire() }
            timer.resume()
        }
        func cancel() { floe_manifold_context_cancel(raw) }
        private func expire() { lock.lock();expired=true;lock.unlock();cancel() }
        var isExpired:Bool { lock.lock();defer { lock.unlock() };return expired }
        deinit { timer.cancel();floe_manifold_context_destroy(raw) }
    }
    /// Digest-keyed immutable results avoid repeating worker CSG when the
    /// feature graph publishes the exact same validated definition.
    private nonisolated final class Cache:@unchecked Sendable {
        let lock=NSLock();var values:[String:Evaluation]=[:];var order:[String]=[]
        func get(_ key:String)->Evaluation? { lock.lock();defer {lock.unlock()};return values[key] }
        func put(_ value:Evaluation,_ key:String) {
            lock.lock();defer {lock.unlock()}
            if values[key] == nil { order.append(key) };values[key]=value
            while order.count>4 { values[order.removeFirst()]=nil }
        }
    }
    private static let cache=Cache()
    static func evaluate(_ definition:CADHybridFeatureDefinition,cancellation:CADMeshCancellation?=nil) throws -> Evaluation {
        let key=definition.digest
        if cancellation?.isCancelled == true || Task.isCancelled { throw CADHybridFailure.cancelled }
        if let cached=cache.get(key) { return cached }
        try definition.validate { cancellation?.kernelIsCancelled() == true || Task.isCancelled }
        let context=try Context(seconds:30)
        let handler=cancellation?.onCancel { context.cancel() }
        defer { if let handler { cancellation?.removeCancellationHandler(handler) } }
        func check() throws {
            if context.isExpired { throw CADHybridFailure.timedOut }
            if cancellation?.kernelIsCancelled() == true || Task.isCancelled { throw CADHybridFailure.cancelled }
        }
        let source=worldRender(definition.source)
        var value=try run(context,source,nil,operation:0)
        let sourceVolume=value.volume
        for operation in definition.operations {
            try check()
            let tool:RenderMesh
            switch operation.tool {
            case let .body(snapshot):tool=worldRender(snapshot)
            case let .box(size,center):
                tool=EuclidBridge.renderMesh(from:.cube(center:Vector(center.x,center.y,center.z),size:Vector(size.x,size.y,size.z)))
            case let .cylinder(radius,height,center,axis,segments):
                let rotation=Rotation(simd_quatd(from:SIMD3<Double>(0,1,0),to:simd_normalize(axis)))
                let mesh=Euclid.Mesh.cylinder(radius:radius,height:height,slices:segments)
                    .transformed(by:Euclid.Transform(rotation:rotation,translation:Vector(center.x,center.y,center.z)))
                tool=EuclidBridge.renderMesh(from:mesh)
            }
            let previousVolume=value.volume
            value=try run(context,value.render,tool,operation:operation.booleanCode)
            let volumeTolerance=max(1e-9,previousVolume*1e-9)
            if operation.booleanCode==1,previousVolume-value.volume<=volumeTolerance {
                throw CADHybridFailure.invalid("The cutting tool removes no measurable material. Move or enlarge it before applying.")
            }
            if operation.kind == .boss,value.volume-previousVolume<=volumeTolerance {
                throw CADHybridFailure.invalid("The boss adds no measurable material. Move or resize it before applying.")
            }
        }
        try check()
        let result=Evaluation(render:value.render,volume:value.volume,sourceVolume:sourceVolume)
        cache.put(result,key);return result
    }
    /// Real Manifold ingestion is also used by conversion/recognition so a
    /// boundary report is never substituted for solid validity.
    static func validatedSource(_ source:CADHybridMeshSource,cancellation:CADMeshCancellation?=nil) throws -> Evaluation {
        try source.validate { cancellation?.isCancelled == true || Task.isCancelled }
        let context=try Context(seconds:30), handler=cancellation?.onCancel { context.cancel() }
        defer { if let handler { cancellation?.removeCancellationHandler(handler) } }
        let value=try run(context,worldRender(source),nil,operation:0)
        if context.isExpired { throw CADHybridFailure.timedOut }
        if cancellation?.isCancelled == true || Task.isCancelled { throw CADHybridFailure.cancelled }
        return .init(render:value.render,volume:value.volume,sourceVolume:value.volume)
    }
    private static func worldRender(_ source:CADHybridMeshSource)->RenderMesh {
        let positions=source.positions.map { SIMD3<Float>(source.placement.applying(to:SIMD3<Double>($0))) }
        let normals=source.normals.map { SIMD3<Float>(source.placement.rotation.act(SIMD3<Double>($0))) }
        return .init(positions:positions,normals:normals,indices:source.indices)
    }
    private static func run(_ context:Context,_ source:RenderMesh,_ tool:RenderMesh?,operation:Int) throws -> (render:RenderMesh,volume:Double) {
        // SIMD3 has a 16-byte stride: never expose it as packed XYZ to C.
        let packed=source.positions.flatMap { [$0.x,$0.y,$0.z] }
        let other=tool?.positions.flatMap { [$0.x,$0.y,$0.z] } ?? []
        let toolIndices=tool?.indices ?? []
        let pointer=packed.withUnsafeBufferPointer { p in source.indices.withUnsafeBufferPointer { i in
            other.withUnsafeBufferPointer { q in toolIndices.withUnsafeBufferPointer { j in
                floe_manifold_boolean(context.raw,p.baseAddress,source.positions.count,i.baseAddress,i.count,
                    tool == nil ? nil : q.baseAddress,tool?.positions.count ?? 0,j.baseAddress,j.count,Int32(operation))
            } }
        } }
        guard let pointer else { throw CADHybridFailure.kernel("The mesh kernel could not allocate a result.") }
        defer { floe_manifold_result_destroy(pointer) }
        let status=floe_manifold_result_status(pointer)
        if context.isExpired { throw CADHybridFailure.timedOut }
        if status==3 { throw CADHybridFailure.cancelled }
        guard status==0 else { throw CADHybridFailure.kernel(String(cString:floe_manifold_result_message(pointer))) }
        let vertexCount=Int(floe_manifold_result_vertex_count(pointer)), indexCount=Int(floe_manifold_result_index_count(pointer))
        guard vertexCount>0,indexCount>0,indexCount%3==0,vertexCount<=3_000_000,indexCount<=3_000_000,
              let xyz=floe_manifold_result_xyz(pointer),let triangles=floe_manifold_result_indices(pointer) else {
            throw CADHybridFailure.kernel("The mesh kernel produced invalid buffers.")
        }
        let positions=(0..<vertexCount).map { SIMD3<Float>(xyz[3*$0],xyz[3*$0+1],xyz[3*$0+2]) }
        let indices=Array(UnsafeBufferPointer(start:triangles,count:indexCount))
        // Split vertices by triangle to preserve sharp facet normals and never
        // invent smoothing across a newly cut edge.
        var flat:[SIMD3<Float>]=[],normals:[SIMD3<Float>]=[],sequential:[UInt32]=[]
        flat.reserveCapacity(indexCount);normals.reserveCapacity(indexCount);sequential.reserveCapacity(indexCount)
        for i in stride(from:0,to:indexCount,by:3) {
            let a=positions[Int(indices[i])],b=positions[Int(indices[i+1])],c=positions[Int(indices[i+2])]
            let cross=simd_cross(b-a,c-a), length=simd_length(cross)
            guard length.isFinite,length>0 else { throw CADHybridFailure.kernel("The mesh kernel produced a degenerate face.") }
            let normal=cross/length
            for point in [a,b,c] { sequential.append(UInt32(flat.count));flat.append(point);normals.append(normal) }
        }
        let volume=floe_manifold_result_volume(pointer)
        guard volume.isFinite,volume>0 else { throw CADHybridFailure.kernel("The mesh does not enclose a positive volume.") }
        return (.init(positions:flat,normals:normals,indices:sequential),volume)
    }
}
