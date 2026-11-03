// SPDX-License-Identifier: MPL-2.0
// Body-owned raster edits. UV/geometry remain the existing authorities.
import Foundation
import simd

nonisolated struct CADTexturePaintFailure:Error,LocalizedError,Sendable {
    let code:String
    let message:String
    var errorDescription:String? { message }
}
nonisolated struct CADTexturePaintHit:Codable,Sendable {
    let triangle:Int
    let barycentric:SIMD3<Double>
}
nonisolated struct CADTexturePaintGeometry:Sendable {
    let mesh:RenderMesh
    let transform:Transform3D
}
nonisolated struct CADTexturePaintSource:Sendable {
    let mesh:RenderMesh
    let transform:Transform3D
    let material:BodyMaterialSpec
    let uvData:Data?
    let occluders:[CADTexturePaintGeometry]
}
nonisolated struct CADTexturePaintRequest:Sendable {
    enum Kind:Sendable,Equatable { case read,stroke,ao }
    let kind:Kind
    var resolution:Int=128
    var hits:[CADTexturePaintHit]=[]
    var radius:Double=12
    var color:SIMD4<Double>=SIMD4(1,0,0,1)
    var opacity:Double=1
    var samples:Int=16
    var maxDistance:Double=50
}
nonisolated struct CADTexturePaintComputed:Sendable {
    let png:Data
    let material:BodyMaterialSpec
    let sourceSHA256:String
    let width:Int
    let height:Int
    let changedPixels:Int
    let coveredPixels:Int
    let rays:Int
    let occludedRays:Int
}
nonisolated final class CADTexturePaintBudget:@unchecked Sendable {
    let cancellation:CADMeshCancellation
    private let deadline:TimeInterval
    private var work=0
    init(cancellation:CADMeshCancellation,seconds:Double=20) {
        self.cancellation=cancellation;deadline=ProcessInfo.processInfo.systemUptime+seconds
    }
    var shouldStop:Bool { cancellation.isCancelled || Task.isCancelled || work>20_000_000 || ProcessInfo.processInfo.systemUptime>=deadline }
    func check(_ charge:Int=1) throws {
        work += charge
        guard !cancellation.isCancelled,!Task.isCancelled else { throw CADTexturePaintFailure(code:"cancelled",message:"Texture editing was cancelled.") }
        guard work <= 20_000_000,ProcessInfo.processInfo.systemUptime < deadline else {
            throw CADTexturePaintFailure(code:"paint_budget",message:"This texture operation exceeds its calculation budget. Use a smaller image or fewer samples.")
        }
    }
}

nonisolated enum CADTexturePaintKernel {
    struct Atlas {
        let uv:[SIMD2<Double>]
        let charts:[UInt32]
        let owners:[Int32]
        let width:Int
        let height:Int
    }
    static func fail(_ code:String,_ message:String)->CADTexturePaintFailure { .init(code:code,message:message) }
    static func barycentric(_ p:SIMD2<Double>,_ a:SIMD2<Double>,_ b:SIMD2<Double>,_ c:SIMD2<Double>)->SIMD3<Double>? {
        let v0=b-a,v1=c-a,v2=p-a,det=v0.x*v1.y-v0.y*v1.x
        guard abs(det)>1e-14 else { return nil }
        let u=(v2.x*v1.y-v2.y*v1.x)/det,v=(v0.x*v2.y-v0.y*v2.x)/det
        return SIMD3(1-u-v,u,v)
    }
    static func overlapArea(_ a:[SIMD2<Double>],_ b:[SIMD2<Double>])->Double {
        var polygon=a
        let winding=(b[1].x-b[0].x)*(b[2].y-b[0].y)-(b[1].y-b[0].y)*(b[2].x-b[0].x)
        let sign=winding>0 ? 1.0 : -1.0
        for i in 0..<3 {
            let start=b[i],end=b[(i+1)%3],edge=end-start
            func side(_ x:SIMD2<Double>)->Double { sign*(edge.x*(x.y-start.y)-edge.y*(x.x-start.x)) }
            let input=polygon;polygon=[]
            guard var prior=input.last else { return 0 }
            for point in input {
                let d0=side(prior),d1=side(point)
                if (d0>=0) != (d1>=0),abs(d0-d1)>1e-20 { polygon.append(prior+(point-prior)*(d0/(d0-d1))) }
                if d1>=0 { polygon.append(point) };prior=point
            }
        }
        guard polygon.count>=3 else { return 0 }
        return abs(polygon.indices.reduce(0.0) { total,i in let a=polygon[i],b=polygon[(i+1)%polygon.count];return total+a.x*b.y-a.y*b.x })/2
    }
    static func atlas(_ source:CADTexturePaintSource,width:Int,height:Int,budget:CADTexturePaintBudget)throws->Atlas {
        let mesh=source.mesh
        try CADUVRecord.validate(mesh)
        guard !source.material.usesProjectedUVs,let uv=mesh.texcoords,uv.count==mesh.positions.count else {
            throw fail("paint_needs_uv","Unwrap the body and use its mesh UVs before painting or baking.")
        }
        if let data=source.uvData {
            let record=try CADUVRecord.decode(data)
            guard record.matches(mesh),let active=record.activeSet,active.seamSHA256==record.seamSHA256 else { throw fail("paint_stale_uv","Geometry or seams changed. Unwrap the current mesh before painting.") }
            let activeCorners=try CADUVRecord.unpack(active.cornerUVData)
            guard activeCorners==mesh.indices.map({uv[Int($0)]}) else { throw fail("paint_stale_uv","The live UVs no longer match the active saved set. Refresh UVs before painting.") }
        }
        let corners=mesh.indices.map { SIMD2<Double>(Double(uv[Int($0)].x),Double(uv[Int($0)].y)) }
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x>=0 && $0.x<=1 && $0.y>=0 && $0.y<=1 }) else {
            throw fail("paint_tiled_uv","Painting requires a non-overlapping UV atlas inside 0…1. Pack the UV islands first.")
        }
        try CADUVRecord.validateUVs(corners.map { SIMD2<Float>(Float($0.x),Float($0.y)) },cornerCount:corners.count)
        let charts=try CADUVRecord.inferredCharts(source:mesh,cornerUVs:corners.map { SIMD2<Float>(Float($0.x),Float($0.y)) })
        // Exact triangle clipping after a grid broadphase; shared boundaries
        // have zero area. A duplicate/mirrored UV island is refused, not painted
        // onto an unrelated surface through shared texels.
        var bins=[[Int]](repeating:[],count:32*32)
        for f in 0..<mesh.triangleCount {
            if f&63==0 { try budget.check(64) }
            let triangle=Array(corners[f*3..<f*3+3])
            let lo=triangle.reduce(SIMD2<Double>(repeating:1)) { simd_min($0,$1) },hi=triangle.reduce(SIMD2<Double>.zero) { simd_max($0,$1) }
            let x0=max(0,min(31,Int(lo.x*32))),x1=max(0,min(31,Int(hi.x*32)))
            let y0=max(0,min(31,Int(lo.y*32))),y1=max(0,min(31,Int(hi.y*32)))
            var candidates:Set<Int>=[]
            for y in y0...y1 { for x in x0...x1 { try budget.check(max(1,bins[y*32+x].count));candidates.formUnion(bins[y*32+x]) } }
            for other in candidates {
                try budget.check()
                if overlapArea(triangle,Array(corners[other*3..<other*3+3])) > 1e-12 {
                    throw fail("paint_overlapping_uv","UV islands overlap. Repack them before local painting or baking.")
                }
            }
            for y in y0...y1 { for x in x0...x1 { bins[y*32+x].append(f) } }
        }
        var owners=[Int32](repeating:-1,count:width*height)
        for f in 0..<mesh.triangleCount {
            let a=corners[f*3],b=corners[f*3+1],c=corners[f*3+2]
            let lo=simd_min(a,simd_min(b,c)),hi=simd_max(a,simd_max(b,c))
            let x0=max(0,min(width-1,Int(floor(lo.x*Double(width))))),x1=max(0,min(width-1,Int(ceil(hi.x*Double(width)))))
            let y0=max(0,min(height-1,Int(floor(lo.y*Double(height))))),y1=max(0,min(height-1,Int(ceil(hi.y*Double(height)))))
            for y in y0...y1 { for x in x0...x1 {
                if x&63==0 { try budget.check(64) }
                let p=SIMD2((Double(x)+0.5)/Double(width),(Double(y)+0.5)/Double(height))
                if let w=barycentric(p,a,b,c),min(w.x,min(w.y,w.z))>=(-1e-10),owners[y*width+x] == -1 { owners[y*width+x]=Int32(f) }
            } }
        }
        guard owners.contains(where:{$0>=0}) else { throw fail("paint_empty_atlas","The atlas has no covered pixels at this resolution.") }
        return Atlas(uv:corners,charts:charts,owners:owners,width:width,height:height)
    }
    static func canvas(_ source:CADTexturePaintSource,resolution:Int,maximumDimension:Int,budget:CADTexturePaintBudget)throws->CADExportImage.Pixels {
        var pixels:CADExportImage.Pixels
        if let bytes=source.material.baseColorTexture {
            let descriptor=try CADTextureImport.inspect(bytes)
            guard descriptor.width<=maximumDimension,descriptor.height<=maximumDimension else {
                throw fail(maximumDimension==256 ? "bake_image_budget" : "paint_image_budget",maximumDimension==256 ? "AO accepts images up to 256×256. The original image was kept." : "Painting accepts images up to 1024×1024. The original image was kept.")
            }
            try budget.check()
            guard case let .success(decoded)=CADExportImage.decode(bytes),decoded.width<=maximumDimension,decoded.height<=maximumDimension,
                  let image=CADExportImage.pixels(decoded,orientation:source.material.textureOrientation(for:.baseColor)) else {
                throw fail("paint_image_budget","Painting accepts a single PNG/JPEG up to 1024×1024. The original image was kept.")
            }
            pixels=image
        } else { pixels = .init(width:resolution,height:resolution,rgba:[UInt8](repeating:255,count:resolution*resolution*4)) }
        // Flatten the existing LINEAR base factor into normalized sRGB pixels,
        // then set that factor to one on commit. Painting red must not be
        // multiplied by a previously blue material factor. Other maps stay put.
        let linear=source.material.textureColorSpace(for:.baseColor) == .linear && source.material.baseColorTexture != nil
        for pixel in 0..<pixels.pixelCount { if pixel&63==0 { try budget.check(64) };for c in 0..<3 {
            let value=Double(pixels.rgba[pixel*4+c])/255
            let input=linear ? value : CADExportImage.srgbToLinear(value)
            pixels.rgba[pixel*4+c]=UInt8((CADExportImage.linearToSRGB(input*source.material.baseColor[c])*255).rounded())
        } }
        return pixels
    }
    static func compute(_ source:CADTexturePaintSource,request:CADTexturePaintRequest,budget:CADTexturePaintBudget)throws->CADTexturePaintComputed {
        try budget.check()
        guard [64,128,256,512,1024].contains(request.resolution),
              [source.material.baseColor.x,source.material.baseColor.y,source.material.baseColor.z,source.material.baseColor.w].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
            throw fail("invalid_paint_source","The canvas resolution or base material color is invalid.")
        }
        if request.kind == .stroke {
            guard (1...128).contains(request.hits.count),request.radius.isFinite,(1...64).contains(request.radius),request.opacity.isFinite,(0...1).contains(request.opacity),
                  [request.color.x,request.color.y,request.color.z,request.color.w].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw fail("invalid_brush","The brush inputs exceed the supported range.")
            }
        }
        var image=try canvas(source,resolution:request.resolution,maximumDimension:request.kind == .ao ? 256 : 1024,budget:budget)
        guard request.kind != .ao || (image.width<=256 && image.height<=256) else {
            throw fail("bake_image_budget","This AO bake accepts images up to 256×256. The original texture was kept.")
        }
        let atlas=try atlas(source,width:image.width,height:image.height,budget:budget),before=image.rgba
        var rays=0,occluded=0
        switch request.kind {
        case .read:break
        case .stroke:
            for hit in request.hits {
                guard hit.triangle>=0,hit.triangle<source.mesh.triangleCount,hit.barycentric.x.isFinite,hit.barycentric.y.isFinite,hit.barycentric.z.isFinite,
                      min(hit.barycentric.x,min(hit.barycentric.y,hit.barycentric.z)) >= -1e-8,abs(hit.barycentric.x+hit.barycentric.y+hit.barycentric.z-1)<1e-6 else { throw fail("invalid_paint_hit","A brush hit must belong to the current triangle and have normalized barycentric weights.") }
                let f=hit.triangle,w=hit.barycentric,p=atlas.uv[f*3]*w.x+atlas.uv[f*3+1]*w.y+atlas.uv[f*3+2]*w.z
                let center=SIMD2(p.x*Double(image.width)-0.5,p.y*Double(image.height)-0.5),radius=request.radius
                let x0=max(0,Int(floor(center.x-radius))),x1=min(image.width-1,Int(ceil(center.x+radius)))
                let y0=max(0,Int(floor(center.y-radius))),y1=min(image.height-1,Int(ceil(center.y+radius)))
                if x0>x1 || y0>y1 { continue }
                for y in y0...y1 { for x in x0...x1 {
                    try budget.check()
                    let i=y*image.width+x,owner=Int(atlas.owners[i])
                    guard owner>=0,atlas.charts[owner]==atlas.charts[f] else { continue }
                    let distance=simd_length(SIMD2(Double(x),Double(y))-center)/radius
                    guard distance<1 else { continue }
                    let falloff=min(1,(1-distance)/0.3),alpha=request.color.w*request.opacity*falloff
                    blend(&image.rgba,index:i,color:request.color,alpha:alpha)
                } }
            }
        case .ao:
            let result=try ambientOcclusion(source,atlas:atlas,samples:request.samples,maxDistance:request.maxDistance,budget:budget)
            rays=result.rays;occluded=result.occluded
            for pixel in stride(from:0,to:image.rgba.count,by:4) {
                let i=pixel/4;guard atlas.owners[i]>=0 else { continue }
                for channel in 0..<3 {
                    let linear=CADExportImage.srgbToLinear(Double(image.rgba[pixel+channel])/255)*result.values[i]
                    image.rgba[pixel+channel]=UInt8((CADExportImage.linearToSRGB(linear)*255).rounded())
                }
            }
        }
        try budget.check()
        guard let png=CADExportImage.encodePNG(image),png.count<=CADMaterialLimits.maximumTextureBytes else { throw fail("paint_encode_failed","The texture could not be encoded; nothing changed.") }
        var material=source.material
        if material.nodeGraph?.outputs["baseColor"] != nil { material.nodeGraph=nil }
        material.baseColorTexture=png;material.baseColor.x=1;material.baseColor.y=1;material.baseColor.z=1
        material.materialID=nil // an edited body snapshot does not rewrite its library source
        let texture=CADMaterialTexture(slot:.baseColor,name:"Painted base color",mimeType:"image/png",colorSpace:.srgb,orientation:.topLeft,bytes:png)
        var metadata=material.textureMetadata ?? [];metadata.removeAll{$0.slot == .baseColor};metadata.append(texture.metadata);material.textureMetadata=metadata
        var changed=0
        for i in 0..<image.pixelCount where (0..<4).contains(where:{ image.rgba[i*4+$0] != before[i*4+$0] }) { changed += 1 }
        return .init(png:png,material:material,sourceSHA256:CADUVRecord.sha(MeshBlob.encode(source.mesh)),width:image.width,height:image.height,
                     changedPixels:changed,coveredPixels:atlas.owners.filter{$0>=0}.count,rays:rays,occludedRays:occluded)
    }
    static func blend(_ bytes:inout [UInt8],index:Int,color:SIMD4<Double>,alpha:Double) {
        guard alpha>0 else { return }
        let i=index*4,destinationAlpha=Double(bytes[i+3])/255,out=alpha+destinationAlpha*(1-alpha)
        for c in 0..<3 {
            let src=CADExportImage.srgbToLinear(color[c]),dst=CADExportImage.srgbToLinear(Double(bytes[i+c])/255)
            let linear=out>0 ? (src*alpha+dst*destinationAlpha*(1-alpha))/out : 0
            bytes[i+c]=UInt8((CADExportImage.linearToSRGB(linear)*255).rounded())
        }
        bytes[i+3]=UInt8((out*255).rounded())
    }
}
