// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreImage

/// Pixel-space affine matrix in Core Image's bottom-leading coordinate system.
/// Stored as values so layout changes remain journaled, portable and lossless.
public struct MediaCanvasTransform: Sendable,Codable,Hashable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double
    public init(a:Double=1,b:Double=0,c:Double=0,d:Double=1,tx:Double=0,ty:Double=0) { self.a=a;self.b=b;self.c=c;self.d=d;self.tx=tx;self.ty=ty }
    public static let identity = Self()
    public var cgAffineTransform: CGAffineTransform { .init(a:a,b:b,c:c,d:d,tx:tx,ty:ty) }
    /// self * previous: apply previous first, then this matrix.
    public func composed(after previous: Self) -> Self {
        .init(a:a*previous.a+c*previous.b,b:b*previous.a+d*previous.b,
              c:a*previous.c+c*previous.d,d:b*previous.c+d*previous.d,
              tx:a*previous.tx+c*previous.ty+tx,ty:b*previous.tx+d*previous.ty+ty)
    }
    public func validate() throws {
        guard [a,b,c,d,tx,ty].allSatisfy({$0.isFinite && abs($0)<=1_000_000}),abs(a*d-b*c)>1e-12 else {
            throw MediaPreparedCoreError.invalidOperation("canvas mapping must be finite and invertible")
        }
    }
}
/// A layer keeps its natural parent-space geometry when its document canvas
/// changes. Children of a group continue using that group's reference canvas.
public struct MediaLayerCanvasSpace: Sendable,Codable,Hashable {
    public var referenceCanvas: MediaCanvas
    public var transform: MediaCanvasTransform
    public init(referenceCanvas:MediaCanvas,transform:MediaCanvasTransform = .identity) { self.referenceCanvas=referenceCanvas;self.transform=transform }
    public func validate() throws { try MediaCanvasLayout.validate(referenceCanvas);try transform.validate() }
}
public enum MediaCanvasLayoutMode: Sendable,Codable,Hashable {
    case scaleImage
    case extendCanvas(anchor:ImageFreehandStroke.Point)
}
public enum MediaCanvasLayout {
    public static func validate(_ canvas: MediaCanvas) throws {
        guard canvas.width>0,canvas.height>0,canvas.width<=16_384,canvas.height<=16_384,
              canvas.width*canvas.height<=64_000_000,canvas.frameRate.map({$0.isFinite && $0>0}) ?? true else {
            throw MediaPreparedCoreError.invalidOperation("image dimensions must fit the existing 16384-edge / 64MP export bounds")
        }
    }
    /// One canonical transaction owns all root-subtree layout changes. It
    /// retains source data, hierarchy, masks, locks and actual edit generations.
    public static func actions(_ document:MediaPreparedDocument,width:Int,height:Int,mode:MediaCanvasLayoutMode) throws -> [MediaPreparedAction] {
        guard let old=document.canvas,document.kind == .image else { throw MediaPreparedCoreError.invalidOperation("image canvas required") }
        let next=MediaCanvas(width:width,height:height,frameRate:old.frameRate);try validate(next);try validate(old)
        guard next != old else { return [] }
        _ = try mapping(from:old,to:next,mode:mode)
        return [.layoutCanvas(expectedRevision:document.canvasRevision ?? 0,canvas:next,mode:mode)]
    }
    public static func mapping(from old:MediaCanvas,to next:MediaCanvas,mode:MediaCanvasLayoutMode) throws -> MediaCanvasTransform {
        try validate(old);try validate(next)
        switch mode {
        case .scaleImage: return .init(a:Double(next.width)/Double(old.width),d:Double(next.height)/Double(old.height))
        case .extendCanvas(let anchor):
            guard anchor.x.isFinite,anchor.y.isFinite,(0...1).contains(anchor.x),(0...1).contains(anchor.y) else { throw MediaPreparedCoreError.invalidOperation("normalized canvas anchor required") }
            return .init(tx:Double(next.width-old.width)*anchor.x,ty:Double(next.height-old.height)*(1-anchor.y))
        }
    }
    /// A direct manipulation is measured in the displayed document canvas.
    /// Convert its vector through ancestor group transforms, then append the
    /// translation in this layer's parent space without baking any content.
    public static func movedSpace(_ layer:MediaPreparedLayer,in document:MediaPreparedDocument,delta:ImageFreehandStroke.Point) throws -> MediaLayerCanvasSpace {
        guard let canvas=document.canvas,delta.x.isFinite,delta.y.isFinite else { throw MediaPreparedCoreError.invalidOperation("finite canvas movement required") }
        var reference=canvas,ancestor=layer.parentID,parents:[MediaPreparedLayer]=[]
        while let id=ancestor {
            guard let parent=document.layer(id),parents.count<64 else { throw MediaPreparedCoreError.invalidDocument("invalid layer hierarchy") }
            parents.append(parent);ancestor=parent.parentID
        }
        if let nearest=parents.first(where:{$0.canvasSpace != nil})?.canvasSpace { reference=nearest.referenceCanvas }
        var basis=MediaCanvasTransform.identity
        for parent in parents {
            let radians = -parent.transform.rotationDegrees * .pi/180
            let sx=parent.transform.scale*(parent.transform.flipX == true ? -1:1),sy=parent.transform.scale*(parent.transform.flipY == true ? -1:1)
            let rotation=MediaCanvasTransform(a:cos(radians)*sx,b:sin(radians)*sx,c:-sin(radians)*sy,d:cos(radians)*sy)
            basis=(parent.canvasSpace?.transform ?? .identity).composed(after:rotation.composed(after:basis))
        }
        try basis.validate();let determinant=basis.a*basis.d-basis.b*basis.c
        let dx=delta.x*Double(canvas.width),dy = -delta.y*Double(canvas.height)
        let x=(basis.d*dx-basis.c*dy)/determinant,y=(basis.a*dy-basis.b*dx)/determinant
        var space=layer.canvasSpace ?? .init(referenceCanvas:reference)
        space.transform=MediaCanvasTransform(tx:x,ty:y).composed(after:space.transform);try space.validate()
        return space
    }
    public static func remapSelection(_ selection:ImageSelection,from old:MediaCanvas,to next:MediaCanvas,mode:MediaCanvasLayoutMode) throws -> ImageSelection? {
        let mapping=try mapping(from:old,to:next,mode:mode),bitmap=try MediaNativeSelection.flattened(selection,width:old.width,height:old.height)
        guard let image=bitmap.cgImage else { throw MediaPreparedCoreError.invalidOperation("invalid selection coverage") }
        let scale=min(1,2048/Double(max(next.width,next.height))),width=max(1,Int(Double(next.width)*scale)),height=max(1,Int(Double(next.height)*scale))
        let source=CIImage(cgImage:image).transformed(by:.init(scaleX:Double(old.width)/Double(bitmap.width),y:Double(old.height)/Double(bitmap.height)))
            .transformed(by:mapping.cgAffineTransform).transformed(by:.init(scaleX:scale,y:scale))
        try Task.checkCancellation()
        guard let result=CIContext(options:[.cacheIntermediates:false]).createCGImage(source,from:.init(x:0,y:0,width:width,height:height)) else { throw MediaPreparedCoreError.invalidOperation("could not rebase selection") }
        let coverage=try MediaNativeSelection.coverage(result)
        return coverage.alpha.contains(where:{$0>0}) ? .init(bitmap:coverage):nil
    }

    public static func remapPoint(_ point:ImageFreehandStroke.Point,from old:MediaCanvas,to next:MediaCanvas,mode:MediaCanvasLayoutMode) throws -> ImageFreehandStroke.Point? {
        guard point.x.isFinite,point.y.isFinite else { throw MediaPreparedCoreError.invalidOperation("finite canvas point required") }
        let matrix=try mapping(from:old,to:next,mode:mode)
        let mapped=CGPoint(x:point.x*Double(old.width),y:(1-point.y)*Double(old.height)).applying(matrix.cgAffineTransform)
        let result=ImageFreehandStroke.Point(x:Double(mapped.x)/Double(next.width),y:1-Double(mapped.y)/Double(next.height))
        return (0...1).contains(result.x) && (0...1).contains(result.y) ? result:nil
    }

    public static func placementCenter(_ layer:MediaPreparedLayer,in document:MediaPreparedDocument) throws -> ImageFreehandStroke.Point {
        guard let canvas=document.canvas else { throw MediaPreparedCoreError.invalidOperation("image canvas required") }
        var parents:[MediaPreparedLayer]=[],ancestor=layer.parentID
        while let id=ancestor {
            guard let parent=document.layer(id),parents.count<64 else { throw MediaPreparedCoreError.invalidDocument("invalid layer hierarchy") }
            parents.append(parent);ancestor=parent.parentID
        }
        let reference=layer.canvasSpace?.referenceCanvas ?? parents.first(where:{$0.canvasSpace != nil})?.canvasSpace?.referenceCanvas ?? canvas
        var point=CGPoint(x:layer.transform.centerX*Double(reference.width),y:(1-layer.transform.centerY)*Double(reference.height))
        if let space=layer.canvasSpace { point=point.applying(space.transform.cgAffineTransform) }
        for (index,parent) in parents.enumerated() {
            let reference=parent.canvasSpace?.referenceCanvas ?? parents.dropFirst(index+1).first(where:{$0.canvasSpace != nil})?.canvasSpace?.referenceCanvas ?? canvas
            let radians = -parent.transform.rotationDegrees * .pi/180
            let sx=parent.transform.scale*(parent.transform.flipX == true ? -1:1),sy=parent.transform.scale*(parent.transform.flipY == true ? -1:1)
            let a=cos(radians)*sx,b=sin(radians)*sx,c = -sin(radians)*sy,d=cos(radians)*sy
            let cx=Double(reference.width)/2,cy=Double(reference.height)/2
            let matrix=MediaCanvasTransform(a:a,b:b,c:c,d:d,tx:parent.transform.centerX*Double(reference.width)-a*cx-c*cy,
                ty:(1-parent.transform.centerY)*Double(reference.height)-b*cx-d*cy)
            point=point.applying(matrix.cgAffineTransform)
            if let space=parent.canvasSpace { point=point.applying(space.transform.cgAffineTransform) }
        }
        return .init(x:Double(point.x)/Double(canvas.width),y:1-Double(point.y)/Double(canvas.height))
    }
    public static func alignedSpace(_ layer:MediaPreparedLayer,in document:MediaPreparedDocument,axis:String) throws -> MediaLayerCanvasSpace {
        guard ["centerX","centerY","center"].contains(axis) else { throw MediaPreparedCoreError.invalidOperation("invalid alignment axis") }
        let center=try placementCenter(layer,in:document)
        return try movedSpace(layer,in:document,delta:.init(x:axis == "centerY" ? 0:0.5-center.x,y:axis == "centerX" ? 0:0.5-center.y))
    }

}
