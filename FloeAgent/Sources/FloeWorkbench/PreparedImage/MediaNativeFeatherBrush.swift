// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreImage

/// The brush footprint and selection are frozen in the canvas where the user drew.
public struct MediaLocalFeatherStroke: Codable, Hashable, Sendable {
    public var points: [ImageFreehandStroke.Point]
    public var diameter: Double
    public var strength: Double
    public var canvas: MediaCanvas
    public var anchorToArtboard: MediaCanvasTransform
    public var selection: ImageSelection?
    public var editsMask: Bool
}

public enum MediaNativeFeatherBrush {
    public static func appending(to layer: MediaPreparedLayer, document: MediaPreparedDocument,
                                 points: [ImageFreehandStroke.Point], diameter: Double, strength: Double,
                                 selection: ImageSelection?) throws -> MediaPreparedLayerMask {
        guard let canvas = document.canvas, document.kind == .image, !layer.isLocked, layer.isVisible,
              layer.contentKind != .adjustment, let current = document.layer(layer.id), current.revision == layer.revision,
              (1...10_000).contains(points.count), points.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
                  (0...1).contains($0.x) && (0...1).contains($0.y) }),
              diameter.isFinite, (1...200).contains(diameter), strength.isFinite, (0.01...1).contains(strength) else {
            throw MediaPreparedCoreError.invalidOperation("Invalid feather stroke or unavailable layer")
        }
        var hierarchy = [layer]
        while let parentID = hierarchy.last?.parentID {
            guard hierarchy.count < 128, let parent = document.layer(parentID), parent.isVisible, !parent.isLocked else {
                throw MediaPreparedCoreError.invalidOperation("Unavailable parent layer")
            }
            hierarchy.append(parent)
        }
        var artboard = CGAffineTransform.identity
        var parentSize = canvas
        for item in hierarchy.reversed() {
            let localSize = item.canvasSpace?.referenceCanvas ?? parentSize
            let transform = item.transform
            var placement = CGAffineTransform(translationX:transform.centerX * Double(localSize.width),
                                              y:(1 - transform.centerY) * Double(localSize.height))
            placement = placement.rotated(by:-transform.rotationDegrees * .pi / 180)
                .scaledBy(x:transform.scale * (transform.flipX == true ? -1 : 1),
                          y:transform.scale * (transform.flipY == true ? -1 : 1))
            if item.id != layer.id {
                placement = placement.translatedBy(x:-Double(localSize.width) / 2, y:-Double(localSize.height) / 2)
            }
            if let space = item.canvasSpace { placement = placement.concatenating(space.transform.cgAffineTransform) }
            artboard = placement.concatenating(artboard)
            parentSize = localSize
        }
        let anchor = MediaCanvasTransform(a:artboard.a,b:artboard.b,c:artboard.c,d:artboard.d,tx:artboard.tx,ty:artboard.ty)
        try anchor.validate()
        var mask = layer.mask ?? .init()
        guard (mask.featherStrokes?.count ?? 0) < 512 else { throw MediaPreparedCoreError.limitsExceeded("Feather strokes") }
        let stroke = MediaLocalFeatherStroke(points:points,diameter:diameter,strength:strength,canvas:canvas,
            anchorToArtboard:anchor,selection:selection,editsMask:mask.isEnabled && (mask.vector != nil || !mask.strokes.isEmpty || mask.isInverted))
        mask.featherStrokes = (mask.featherStrokes ?? []) + [stroke]
        return mask
    }

    /// Smooth only alpha at covered edges. Existing chroma survives on both
    /// sides of an internal colour boundary. Newly exposed pixels inherit
    /// nearby edge colour. A constant mask/alpha is a fixed point.
    static func apply(_ stroke: MediaLocalFeatherStroke, to input: CIImage, center: CGPoint,
                      clippedTo extent: CGRect) throws -> CIImage {
        try Task.checkCancellation()
        let points = stroke.points.map { CGPoint(x:$0.x * Double(stroke.canvas.width), y:(1-$0.y) * Double(stroke.canvas.height)) }
        guard let first = points.first else { return input }
        let radius = stroke.diameter / 2
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX,p.x); maxX = max(maxX,p.x); minY = min(minY,p.y); maxY = max(maxY,p.y)
        }
        let artboard = CGRect(x:0,y:0,width:stroke.canvas.width,height:stroke.canvas.height)
        let clip = CGRect(x:minX-radius-1,y:minY-radius-1,width:maxX-minX+2*radius+2,height:maxY-minY+2*radius+2)
            .integral.intersection(artboard)
        guard !clip.isEmpty else { return input }
        guard let ctx = CGContext(data:nil,width:Int(clip.width),height:Int(clip.height),bitsPerComponent:8,
                                  bytesPerRow:0,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else {
            throw MediaPreparedCoreError.limitsExceeded("Feather brush coverage")
        }
        ctx.translateBy(x:-clip.minX,y:-clip.minY)
        ctx.setFillColor(gray:stroke.strength,alpha:1); ctx.setStrokeColor(gray:stroke.strength,alpha:1)
        ctx.setLineWidth(stroke.diameter); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.fillEllipse(in:CGRect(x:first.x-radius,y:first.y-radius,width:stroke.diameter,height:stroke.diameter))
        if points.count > 1 { ctx.addLines(between:points); ctx.strokePath() }
        guard let cg = ctx.makeImage() else { throw MediaPreparedCoreError.invalidOperation("Feather brush coverage") }
        var trail = CIImage(cgImage:cg).transformed(by:.init(translationX:clip.minX,y:clip.minY))
        if let selection = stroke.selection {
            guard let fence = ImageSelectionRasterizer.maskImage(for:selection,canvas:artboard.size) else { return input }
            trail = trail.applyingFilter("CIBlendWithAlphaMask",parameters:[
                kCIInputBackgroundImageKey:CIImage(color:.black).cropped(to:clip),kCIInputMaskImageKey:fence]).cropped(to:clip)
        }
        let sourceToArtboard = CGAffineTransform(translationX:-center.x,y:-center.y).concatenating(stroke.anchorToArtboard.cgAffineTransform)
        let mask = trail.transformed(by:sourceToArtboard.inverted())
        let target = mask.extent.integral.intersection(extent)
        guard !target.isEmpty else { return input }
        let scale = sqrt(abs(sourceToArtboard.a * sourceToArtboard.d - sourceToArtboard.b * sourceToArtboard.c))
        let sigma = max(0.35,stroke.diameter * 0.15) / max(scale,0.0001)
        let sampleArea = target.insetBy(dx:-ceil(4*sigma+1),dy:-ceil(4*sigma+1)).intersection(extent)
        let softened = input.cropped(to:extent).clampedToExtent().cropped(to:sampleArea)
            .applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:sigma]).cropped(to:target)
        func opaque(_ color: CIImage) -> CIImage {
            color.applyingFilter("CIColorMatrix",parameters:["inputAVector":CIVector(x:0,y:0,z:0,w:0),
                                                            "inputBiasVector":CIVector(x:0,y:0,z:0,w:1)])
        }
        let clear = CIImage(color:.clear).cropped(to:target)
        let result: CIImage
        if stroke.editsMask { result = softened }
        else {
            let present = input.applyingFilter("CIColorMatrix",parameters:["inputAVector":CIVector(x:0,y:0,z:0,w:65535)])
                .applyingFilter("CIColorClamp")
            let chroma = opaque(input).applyingFilter("CIBlendWithAlphaMask",parameters:[
                kCIInputBackgroundImageKey:opaque(softened),kCIInputMaskImageKey:present])
            result = chroma.applyingFilter("CIBlendWithAlphaMask",parameters:[
                kCIInputBackgroundImageKey:clear,kCIInputMaskImageKey:softened])
        }
        return result.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:input,kCIInputMaskImageKey:mask]).cropped(to:extent)
    }
}
