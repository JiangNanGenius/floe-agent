// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd
import OCCTShim

nonisolated enum CADFacetedSolidKernel {
    nonisolated struct Result:Sendable {
        let source:NativeBodySource
        let render:RenderMesh
        let faces:Int
        let representation:String
    }
    nonisolated struct Sheet:Sendable { let id:BodyID,data:Data,placement:Transform3D }
    static func convert(mesh:CADHybridMeshSource?,sheets:[Sheet],tolerance:Double,cancellation:CADMeshCancellation) throws -> Result {
        guard tolerance.isFinite,(1e-7...1e-3).contains(tolerance) else { throw CADHybridFailure.invalid("Use a sewing tolerance from 0.0000001 to 0.001 mm.") }
        if cancellation.isCancelled || Task.isCancelled { throw CADHybridFailure.cancelled }
        let status=OCCTOpStatus(),shape:OCCTShape?
        let ids:[BodyID],representation:String
        if let mesh {
            guard sheets.isEmpty,mesh.render.triangleCount<=8192 else { throw CADHybridFailure.unsupported("Faceted conversion accepts one closed mesh with at most 8,192 triangles. Simplify a copy first for larger scans.") }
            let validated=try CADHybridMeshKernel.validatedSource(mesh,cancellation:cancellation)
            let packed=validated.render.positions.flatMap { [$0.x,$0.y,$0.z] }
            let xyz=packed.withUnsafeBytes { Data($0) },indices=validated.render.indices.withUnsafeBytes { Data($0) }
            shape=OCCTBridge.solidFromFacets(xyz:xyz,indices:indices,tolerance:tolerance,status:status)
            ids=[mesh.sourceBodyID];representation="faceted"
        } else {
            guard !sheets.isEmpty,sheets.count<=64 else { throw CADHybridFailure.invalid("Select one or more exact surface bodies.") }
            let handles=try sheets.map { sheet -> OCCTShape in
                guard let fresh=OCCTKernel.deserialize(sheet.data),!fresh.containsSolid,
                      let world=OCCTKernel.transformed(fresh,by:sheet.placement) else { throw CADHybridFailure.invalid("An exact surface snapshot could not be restored.") }
                return world.shape
            }
            shape=OCCTBridge.solidFromSheets(handles,tolerance:tolerance,status:status)
            ids=sheets.map(\.id);representation="sewn-sheets"
        }
        if cancellation.isCancelled || Task.isCancelled { throw CADHybridFailure.cancelled }
        guard let shape else { throw CADHybridFailure.kernel(status.detail ?? "The boundary could not be converted to a closed solid.") }
        let handle=BRepHandle(shape)
        guard handle.containsSolid else { throw CADHybridFailure.kernel("The conversion did not produce a closed solid.") }
        var body=Body(id:BodyID(),name:"Converted solid",transform:.identity,primitive:nil,
            render:.init(positions:[],normals:[],indices:[]),revision:0)
        guard body.adoptBRep(handle) else { throw CADHybridFailure.kernel("The converted solid cannot be displayed.") }
        let provenance=CADSolidConversionProvenance(representation:representation,toleranceMM:tolerance,sourceBodyIDs:ids,meshSource:mesh)
        let source=try NativeBodySource(capturing:body,conversionProvenance:provenance)
        return .init(source:source,render:body.render,faces:OCCTKernel.faceInfo(handle).count,representation:representation)
    }
    nonisolated struct BoxRecognition:Sendable {
        let size:SIMD3<Double>,center:SIMD3<Double>,sourceVolume:Double
        var spec:PrimitiveSpec { .box(width:size.x,depth:size.z,height:size.y) }
        // Existing CAD primitives are Y-up with their base at y=0.
        var placement:Transform3D { .init(translation:SIMD3(center.x,center.y-size.y/2,center.z)) }
    }
    /// Narrow, deterministic recognition: verify six axis-aligned planar
    /// supports and volume; never fit a box to an arbitrary bounding envelope.
    /// Broader plane/cylinder/revolve fitting is delegated to the researched
    /// MeshToFeatures adapter and is not claimed by this native first slice.
    static func recognizeBox(_ source:CADHybridMeshSource,cancellation:CADMeshCancellation) throws -> BoxRecognition? {
        let validated=try CADHybridMeshKernel.validatedSource(source,cancellation:cancellation)
        let points=validated.render.positions.map { SIMD3<Double>($0) }
        guard let first=points.first else { return nil }
        var low=first,high=first
        for p in points { low=simd_min(low,p);high=simd_max(high,p) }
        let size=high-low,tolerance=max(1e-5,simd_length(size)*1e-6)
        guard min(size.x,min(size.y,size.z))>tolerance else { return nil }
        var supports=Set<Int>()
        let indices=validated.render.indices
        for i in stride(from:0,to:indices.count,by:3) {
            if cancellation.kernelIsCancelled() || Task.isCancelled { throw CADHybridFailure.cancelled }
            let triangle=(0..<3).map {points[Int(indices[i+$0])]}
            var support:Int?
            for axis in 0..<3 {
                if triangle.allSatisfy({abs($0[axis]-low[axis])<=tolerance}) { support=2*axis }
                if triangle.allSatisfy({abs($0[axis]-high[axis])<=tolerance}) { support=2*axis+1 }
            }
            guard let support else { return nil };supports.insert(support)
        }
        let volume=size.x*size.y*size.z
        guard supports.count==6,abs(validated.volume-volume)<=max(1e-7,volume*1e-5) else { return nil }
        return .init(size:size,center:(high+low)/2,sourceVolume:validated.volume)
    }
}
