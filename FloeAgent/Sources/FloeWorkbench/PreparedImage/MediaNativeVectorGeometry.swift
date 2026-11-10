// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics

public struct MediaPackedVector: Sendable,Hashable {
    public let path:MediaVectorPath
    public let canvasSpace:MediaLayerCanvasSpace
}
public enum MediaVectorBooleanOperation:String,Sendable,Codable,CaseIterable {
    case union,subtract,intersect,xor
}
/// Real filled-path geometry. Curves stay cubic paths; there is no raster mask,
/// bounding-box approximation, or replacement with a different operation.
public enum MediaNativeVectorGeometry {
    public static func cgPath(_ vector:MediaVectorPath,canvas:MediaCanvas,maximumAnchors:Int=32_768) throws -> CGPath {
        try MediaCanvasLayout.validate(canvas)
        let count=vector.subpaths.reduce(0){$0+$1.points.count}
        guard maximumAnchors>0,maximumAnchors<=8_388_608,count<=maximumAnchors else { throw MediaPreparedCoreError.limitsExceeded("vector operation exceeds its anchor budget") }
        let path=CGMutablePath()
        func point(_ p:ImageFreehandStroke.Point) throws -> CGPoint {
            guard p.x.isFinite,p.y.isFinite,(0...1).contains(p.x),(0...1).contains(p.y) else { throw MediaPreparedCoreError.invalidOperation("normalized vector point required") }
            return .init(x:p.x*Double(canvas.width),y:(1-p.y)*Double(canvas.height))
        }
        for sub in vector.subpaths {
            try Task.checkCancellation()
            guard let first=sub.points.first else { continue }
            path.move(to:try point(first.point))
            for index in sub.points.indices.dropFirst() {
                let a=sub.points[index-1],b=sub.points[index]
                if a.controlOut != nil || b.controlIn != nil {
                    path.addCurve(to:try point(b.point),control1:try point(a.controlOut ?? a.point),control2:try point(b.controlIn ?? b.point))
                } else { path.addLine(to:try point(b.point)) }
            }
            if sub.isClosed {
                if let last=sub.points.last,last.controlOut != nil || first.controlIn != nil {
                    path.addCurve(to:try point(first.point),control1:try point(last.controlOut ?? last.point),control2:try point(first.controlIn ?? first.point))
                }
                path.closeSubpath()
            }
        }
        return path
    }
    /// Full-canvas vector content uses the renderer's same logical pivot and
    /// optional post-layout mapping. This API intentionally rejects groups and
    /// per-layer masks/grades rather than silently dropping their appearance.
    public static func placedPath(_ layer:MediaPreparedLayer,in document:MediaPreparedDocument,requireFill:Bool=false) throws -> CGPath {
        guard layer.parentID==nil,case .vectorPaths(let vector)=layer.content,
              layer.mask==nil,layer.clip==nil,layer.adjustment.isIdentity,
              let canvas=document.canvas,!requireFill || (vector.fillColorHex != nil && vector.subpaths.allSatisfy(\.isClosed)) else {
            throw MediaPreparedCoreError.invalidOperation("Select independent vector paths; filled closed shapes are required for Boolean operations")
        }
        let reference=layer.canvasSpace?.referenceCanvas ?? canvas
        var transform=placement(layer:layer,naturalSize:.init(width:reference.width,height:reference.height),canvas:reference)
        if let space=layer.canvasSpace { transform=transform.concatenating(space.transform.cgAffineTransform) }
        guard let path=try cgPath(vector,canvas:reference).copy(using:&transform) else { throw MediaPreparedCoreError.invalidOperation("Could not transform the selected path") }
        return path
    }
    public static func placement(layer:MediaPreparedLayer,naturalSize:CGSize,canvas:MediaCanvas) -> CGAffineTransform {
        var matrix=CGAffineTransform(translationX:layer.transform.centerX*Double(canvas.width),y:(1-layer.transform.centerY)*Double(canvas.height))
        matrix=matrix.rotated(by:-layer.transform.rotationDegrees * .pi/180)
        matrix=matrix.scaledBy(x:layer.transform.scale*(layer.transform.flipX==true ? -1:1),y:layer.transform.scale*(layer.transform.flipY==true ? -1:1))
        return matrix.translatedBy(x:-naturalSize.width/2,y:-naturalSize.height/2)
    }
    public static func boolean(_ ids:[UUID],in document:MediaPreparedDocument,operation:MediaVectorBooleanOperation) throws -> MediaPackedVector? {
        guard document.kind == .image,let canvas=document.canvas,(2...16).contains(ids.count),Set(ids).count==ids.count else { throw MediaPreparedCoreError.invalidOperation("Select two to sixteen distinct vector shapes") }
        var layers:[MediaPreparedLayer]=[],total=0
        for id in ids {
            guard let layer=document.layer(id),!layer.isLocked,case .vectorPaths(let vector)=layer.content else { throw MediaPreparedCoreError.invalidOperation("Select unlocked vector shapes") }
            total += vector.subpaths.reduce(0){$0+$1.points.count}
            guard total<=32_768 else { throw MediaPreparedCoreError.limitsExceeded("Boolean path input exceeds32768 anchors") }
            layers.append(layer)
        }
        guard !document.layers.contains(where:{!ids.contains($0.id) && $0.clip.map{ids.contains($0.baseLayerID)}==true}) else { throw MediaPreparedCoreError.invalidOperation("A clipping layer still depends on one of these shapes") }
        var result:CGPath?
        for layer in layers {
            try Task.checkCancellation()
            guard case .vectorPaths(let source)=layer.content else { throw MediaPreparedCoreError.invalidOperation("vector source changed") }
            let path=try placedPath(layer,in:document,requireFill:true).normalized(using:source.fillRule == .evenOdd ? .evenOdd:.winding)
            if let previous=result {
                switch operation {
                case .union:result=previous.union(path)
                case .subtract:result=previous.subtracting(path)
                case .intersect:result=previous.intersection(path)
                case .xor:result=previous.symmetricDifference(path)
                }
            } else { result=path }
        }
        guard let result,!result.isEmpty else { return nil }
        guard case .vectorPaths(let style)=layers[0].content else { throw MediaPreparedCoreError.invalidOperation("missing primary shape") }
        return try packed(result,canvas:canvas,fill:style.fillColorHex,stroke:style.strokeColorHex,strokeWidth:style.strokeWidth,opacity:style.opacity)
    }
    /// Packs every anchor AND control point into a logical canvas using a
    /// uniform mapping. Off-canvas geometry is retained rather than clipped or
    /// clamped, and stroke widths remain in document pixels.
    public static func packed(_ path:CGPath,canvas:MediaCanvas,fill:String?,stroke:String?=nil,strokeWidth:Double=0,opacity:Double=1) throws -> MediaPackedVector? {
        try MediaCanvasLayout.validate(canvas)
        guard !path.isEmpty else { return nil }
        let bounds=path.boundingBox
        guard !bounds.isNull,[bounds.minX,bounds.minY,bounds.width,bounds.height].allSatisfy({$0.isFinite && abs($0)<=1_000_000}) else { throw MediaPreparedCoreError.invalidOperation("vector bounds are not finite") }
        let scale=max(max(Double(bounds.width)/Double(canvas.width),Double(bounds.height)/Double(canvas.height)),1e-6)
        let space=MediaLayerCanvasSpace(referenceCanvas:canvas,transform:.init(a:scale,d:scale,tx:Double(bounds.minX),ty:Double(bounds.minY)));try space.validate()
        func normalized(_ p:CGPoint) -> ImageFreehandStroke.Point {
            // Only numerical endpoint round-off is clamped; the uniform space
            // above has already retained the full original path and controls.
            .init(x:min(1,max(0,(Double(p.x)-Double(bounds.minX))/(Double(canvas.width)*scale))),y:min(1,max(0,1-(Double(p.y)-Double(bounds.minY))/(Double(canvas.height)*scale))))
        }
        var paths:[MediaVectorSubpath]=[],current:[MediaVectorPoint]=[],last=CGPoint.zero,first=CGPoint.zero,count=0,unsupported=false
        func finish(_ closed:Bool) { if !current.isEmpty { paths.append(.init(points:current,isClosed:closed));current=[] } }
        path.applyWithBlock { element in
            let value=element.pointee,p=value.points
            switch value.type {
            case .moveToPoint:finish(false);current=[.init(point:normalized(p[0]))];last=p[0];first=p[0];count+=1
            case .addLineToPoint:current.append(.init(point:normalized(p[0])));last=p[0];count+=1
            case .addQuadCurveToPoint:
                let c1=CGPoint(x:last.x+(p[0].x-last.x)*2/3,y:last.y+(p[0].y-last.y)*2/3)
                let c2=CGPoint(x:p[1].x+(p[0].x-p[1].x)*2/3,y:p[1].y+(p[0].y-p[1].y)*2/3)
                if !current.isEmpty { current[current.count-1].controlOut=normalized(c1) }
                current.append(.init(point:normalized(p[1]),controlIn:normalized(c2)));last=p[1];count+=1
            case .addCurveToPoint:
                if !current.isEmpty { current[current.count-1].controlOut=normalized(p[0]) }
                current.append(.init(point:normalized(p[2]),controlIn:normalized(p[1])));last=p[2];count+=1
            case .closeSubpath:finish(true);last=first
            @unknown default:unsupported=true
            }
        }
        finish(false)
        guard !unsupported,count<=32_768,paths.count<=1024,paths.allSatisfy({!$0.points.isEmpty && $0.points.count<=8192}) else { throw MediaPreparedCoreError.limitsExceeded("result exceeds editable vector path limits") }
        let vector=MediaVectorPath(subpaths:paths,fillColorHex:fill,strokeColorHex:stroke,strokeWidth:strokeWidth/scale,fillRule:.nonZero,opacity:opacity)
        guard vector.strokeWidth<=2048 else { throw MediaPreparedCoreError.limitsExceeded("result stroke exceeds editable path limits") }
        return .init(path:vector,canvasSpace:space)
    }
}
