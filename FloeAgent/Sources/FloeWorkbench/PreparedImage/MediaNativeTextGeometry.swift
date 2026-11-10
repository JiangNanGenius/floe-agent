// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import CoreGraphics
import CoreText
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A value snapshot keeps path text editable without a dangling dependency on
/// another layer. The source path may subsequently be moved or deleted safely.
public struct MediaTextPathLayout: Sendable,Codable,Hashable {
    public var path:MediaVectorPath
    public var referenceCanvas:MediaCanvas
    public var pathToCanvas:MediaCanvasTransform
    public var startOffset:Double
    public var normalOffset:Double
    public var isReversed:Bool
    public var sourceLayerID:UUID?
    public init(path:MediaVectorPath,referenceCanvas:MediaCanvas,pathToCanvas:MediaCanvasTransform,startOffset:Double=0,normalOffset:Double=0,isReversed:Bool=false,sourceLayerID:UUID?=nil) {
        self.path=path;self.referenceCanvas=referenceCanvas;self.pathToCanvas=pathToCanvas;self.startOffset=startOffset;self.normalOffset=normalOffset;self.isReversed=isReversed;self.sourceLayerID=sourceLayerID
    }
    public func validate() throws {
        try MediaCanvasLayout.validate(referenceCanvas);try pathToCanvas.validate()
        guard path.subpaths.count==1,(2...8192).contains(path.subpaths[0].points.count),startOffset.isFinite,(0...1_000_000).contains(startOffset),normalOffset.isFinite,abs(normalOffset)<=16_384 else { throw MediaPreparedCoreError.invalidOperation("Choose one continuous text path and bounded offsets") }
    }
}
public struct MediaNativeTextOutline {
    public let path:CGPath
    public let naturalSize:CGSize
    public let fontSize:Double
}
/// Core Text performs Unicode shaping and fallback-font selection before any
/// glyph path is read. Layout objects never leave this synchronous operation.
public enum MediaNativeTextGeometry {
    private static func localized(_ zh:String,_ en:String) -> String { FloeL10n.isChinese ? zh:en }
    private struct Glyph { let path:CGPath?;let position:CGPoint;let advance:Double }
    private static func attributed(_ text:ImageTextContent,canvas:MediaCanvas) throws -> (NSAttributedString,Double) {
        guard !text.text.isEmpty,text.text.utf8.count<=4096,text.fontSize.isFinite,(1...1000).contains(text.fontSize) else { throw MediaPreparedCoreError.invalidOperation("Choose bounded nonempty text and a supported font size") }
        let size=max(8,min(text.fontSize,Double(canvas.height)*0.5)),font=CTFontCreateWithName((text.fontName ?? "Helvetica") as CFString,size,nil)
        var values:[NSAttributedString.Key:Any]=[.font:font]
        if let tracking=text.tracking,tracking.isFinite { values[.kern]=max(-size,min(tracking,size*2)) }
        let paragraph=NSMutableParagraphStyle()
        if let leading=text.leading,leading.isFinite { paragraph.lineSpacing=max(0,min(leading,size*2)) }
        switch text.alignment ?? .left { case .left:paragraph.alignment = .left;case .center:paragraph.alignment = .center;case .right:paragraph.alignment = .right }
        values[.paragraphStyle]=paragraph
        return (NSAttributedString(string:text.text,attributes:values),size)
    }
    private static func glyphs(_ line:CTLine,text:String) throws -> [Glyph] {
        guard CTLineGetGlyphCount(line)<=4096 else { throw MediaPreparedCoreError.limitsExceeded("text outline exceeds4096 glyphs") }
        let string=text as NSString
        var output:[Glyph]=[]
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            try Task.checkCancellation()
            let count=CTRunGetGlyphCount(run)
            if count==0 { continue }
            let attributes=CTRunGetAttributes(run) as NSDictionary
            guard let value=attributes[kCTFontAttributeName] else { throw MediaPreparedCoreError.invalidOperation("Core Text did not resolve the glyph font") }
            let font=value as! CTFont
            guard !CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) else { throw MediaPreparedCoreError.invalidOperation(localized("彩色字形不能转成单色路径，请换用其他字体。", "Color glyphs cannot become monochrome outlines. Choose another font.")) }
            var ids=[CGGlyph](repeating:0,count:count),positions=[CGPoint](repeating:.zero,count:count),advances=[CGSize](repeating:.zero,count:count),indices=[CFIndex](repeating:0,count:count)
            CTRunGetGlyphs(run,CFRange(),&ids);CTRunGetPositions(run,CFRange(),&positions);CTRunGetAdvances(run,CFRange(),&advances);CTRunGetStringIndices(run,CFRange(),&indices)
            for index in 0..<count {
                var matrix=CTRunGetTextMatrix(run)
                let path=CTFontCreatePathForGlyph(font,ids[index],&matrix)
                if path==nil {
                    let offset=indices[index]
                    let unit=(0..<string.length).contains(offset) ? UnicodeScalar(string.character(at:offset)):nil
                    guard let unit,CharacterSet.whitespacesAndNewlines.contains(unit) else {
                        throw MediaPreparedCoreError.invalidOperation(localized("部分字符无法转成路径，请换用其他字体。", "Some characters cannot become outlines. Choose another font."))
                    }
                }
                output.append(.init(path:path,position:positions[index],advance:Double(advances[index].width)))
            }
        }
        return output
    }
    public static func outline(_ text:ImageTextContent,canvas:MediaCanvas) throws -> MediaNativeTextOutline {
        try MediaCanvasLayout.validate(canvas)
        if let layout=text.pathLayout { return try alongPath(text,layout:layout,canvas:canvas) }
        let (attributed,size)=try attributed(text,canvas:canvas),framesetter=CTFramesetterCreateWithAttributedString(attributed)
        let textSize=CTFramesetterSuggestFrameSizeWithConstraints(framesetter,CFRange(),nil,.init(width:Double(canvas.width)*0.9,height:Double(canvas.height)*0.9),nil)
        let frame=CTFramesetterCreateFrame(framesetter,CFRange(),CGPath(rect:.init(origin:.zero,size:textSize),transform:nil),nil)
        let visible=CTFrameGetVisibleStringRange(frame)
        guard visible.location==0,visible.length==(text.text as NSString).length else { throw MediaPreparedCoreError.invalidOperation(localized("文字超出画面，请缩小字号或扩大画布后再转换。", "Text overflows its frame. Reduce the font size or enlarge the canvas before outlining.")) }
        let lines=CTFrameGetLines(frame) as! [CTLine]
        var origins=[CGPoint](repeating:.zero,count:lines.count)
        CTFrameGetLineOrigins(frame,CFRange(),&origins)
        let path=CGMutablePath()
        for (index,line) in lines.enumerated() {
            for glyph in try glyphs(line,text:text.text) {
                guard let shape=glyph.path else { continue }
                var matrix=CGAffineTransform(translationX:origins[index].x+glyph.position.x,y:origins[index].y+glyph.position.y)
                if let placed=shape.copy(using:&matrix) { path.addPath(placed) }
            }
        }
        return .init(path:path,naturalSize:.init(width:max(1,textSize.width.rounded(.up)),height:max(1,textSize.height.rounded(.up))),fontSize:size)
    }
    public static func pathLength(_ layout:MediaTextPathLayout) throws -> Double { try polyline(layout).lengths.last! }
    private static func polyline(_ layout:MediaTextPathLayout) throws -> (points:[CGPoint],lengths:[Double]) {
        try layout.validate()
        var mapping=layout.pathToCanvas.cgAffineTransform
        guard let path=try MediaNativeVectorGeometry.cgPath(layout.path,canvas:layout.referenceCanvas).copy(using:&mapping) else { throw MediaPreparedCoreError.invalidOperation("Could not resolve the text path") }
        var points:[CGPoint]=[],start=CGPoint.zero,unsupported=false
        path.flattened(threshold:0.25).applyWithBlock { element in
            let value=element.pointee
            switch value.type {
            case .moveToPoint:start=value.points[0];points.append(start)
            case .addLineToPoint:points.append(value.points[0])
            case .closeSubpath:points.append(start)
            default:unsupported=true
            }
        }
        guard !unsupported,points.count<=32_768 else { throw MediaPreparedCoreError.limitsExceeded("text path exceeds supported geometry") }
        points=points.enumerated().filter{$0.offset==0 || $0.element != points[$0.offset-1]}.map(\.element)
        if layout.isReversed { points.reverse() }
        guard points.count>=2 else { throw MediaPreparedCoreError.invalidOperation("Choose a path with a nonzero length") }
        var lengths=[0.0]
        for index in 1..<points.count { lengths.append(lengths.last!+hypot(Double(points[index].x-points[index-1].x),Double(points[index].y-points[index-1].y))) }
        guard let total=lengths.last,total.isFinite,total>1e-6 else { throw MediaPreparedCoreError.invalidOperation("Choose a path with a nonzero length") }
        return (points,lengths)
    }
    private static func alongPath(_ text:ImageTextContent,layout:MediaTextPathLayout,canvas:MediaCanvas) throws -> MediaNativeTextOutline {
        guard canvas.width==layout.referenceCanvas.width,canvas.height==layout.referenceCanvas.height,!text.text.contains(where:{$0=="\n" || $0=="\r"}) else { throw MediaPreparedCoreError.invalidOperation("Path text uses a single line on its saved logical canvas") }
        let (attributes,size)=try attributed(text,canvas:canvas),line=CTLineCreateWithAttributedString(attributes)
        let data=try polyline(layout),total=data.lengths.last!,width=CTLineGetTypographicBounds(line,nil,nil,nil),available=total-layout.startOffset
        guard available>=width else { throw MediaPreparedCoreError.invalidOperation(localized("文字放不下，请缩小字号或延长路径。", "The text does not fit. Reduce its font size or extend the path.")) }
        let alignment:Double=switch text.alignment ?? .left { case .left:0;case .center:(available-width)/2;case .right:available-width }
        func pose(_ distance:Double) throws -> (CGPoint,Double) {
            guard distance.isFinite,distance>=(-1e-6),distance<=total+1e-6 else { throw MediaPreparedCoreError.invalidOperation("glyph falls outside the text path") }
            let distance=min(total,max(0,distance));var low=1,high=data.lengths.count-1
            while low<high { let mid=(low+high)/2;if data.lengths[mid]<distance { low=mid+1 } else { high=mid } }
            let a=data.points[low-1],b=data.points[low],span=data.lengths[low]-data.lengths[low-1],fraction=(distance-data.lengths[low-1])/span
            return (.init(x:Double(a.x)+Double(b.x-a.x)*fraction,y:Double(a.y)+Double(b.y-a.y)*fraction),atan2(Double(b.y-a.y),Double(b.x-a.x)))
        }
        let result=CGMutablePath()
        for glyph in try glyphs(line,text:text.text) {
            guard let shape=glyph.path else { continue }
            let (point,angle)=try pose(layout.startOffset+alignment+Double(glyph.position.x)+glyph.advance/2)
            var matrix=CGAffineTransform(translationX:point.x,y:point.y).rotated(by:angle).translatedBy(x:-glyph.advance/2,y:Double(glyph.position.y)+layout.normalOffset)
            if let path=shape.copy(using:&matrix) { result.addPath(path) }
        }
        return .init(path:result,naturalSize:.init(width:canvas.width,height:canvas.height),fontSize:size)
    }
    public static func outlineLayer(_ layer:MediaPreparedLayer,in document:MediaPreparedDocument) throws -> MediaPackedVector {
        guard !layer.isLocked,layer.parentID==nil,case .text(let text)=layer.content,layer.mask==nil,layer.clip==nil,layer.adjustment.isIdentity,text.shadow==nil,let canvas=document.canvas else {
            throw MediaPreparedCoreError.invalidOperation("Select an independent text layer without a mask, shadow or color adjustment")
        }
        let reference=layer.canvasSpace?.referenceCanvas ?? canvas,outline=try outline(text,canvas:reference)
        var mapping=MediaNativeVectorGeometry.placement(layer:layer,naturalSize:outline.naturalSize,canvas:reference)
        if let space=layer.canvasSpace { mapping=mapping.concatenating(space.transform.cgAffineTransform) }
        guard let path=outline.path.copy(using:&mapping),let packed=try MediaNativeVectorGeometry.packed(path,canvas:canvas,fill:text.colorHex,stroke:text.strokeColorHex,strokeWidth:(text.strokeWidth ?? 0)*outline.fontSize/100) else { throw MediaPreparedCoreError.invalidOperation("Text has no visible outlines") }
        return packed
    }
}
